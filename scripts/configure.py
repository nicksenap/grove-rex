#!/usr/bin/env python3
"""Idempotent Rex + Grove config wiring for grove-rex.

rex:   a marked block in init.lua that dofile()s rex/grove.lua and binds a key.
grove: hooks.pre_delete -> hooks/pre-delete.sh. A pre_delete hook that was
       already there (e.g. grove-herdr's) is saved and run first by ours, and
       put back on uninstall.
"""

from __future__ import annotations

import argparse
import re
import shutil
import sys
from pathlib import Path

BEGIN = "-- >>> grove-rex >>>"
END = "-- <<< grove-rex <<<"
BLOCK_RE = re.compile(re.escape(BEGIN) + r".*?" + re.escape(END) + r"\n?", re.S)
DOFILE_RE = re.compile(r'(?m)^dofile\(.*grove-rex.*\)\s*$')
BIND_RE = re.compile(r'(?m)^rex\.bind\(\s*"(?P<key>[^"]+)"\s*,\s*"grove_create"')

HOOK = "pre_delete"
SCRIPT = "pre-delete.sh"
TIMEOUT = "10s"
HEADER_RE = re.compile(r"^\[+[^\]]+\]+\s*$", re.M)
COMMAND_LINE_RE = re.compile(r'(?m)^[ \t]*command\s*=\s*(?P<q>["\'])(?P<value>.*)(?P=q)\s*$')


# ---- files ------------------------------------------------------------------

def read(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.exists() else ""


def write_if_changed(path: Path, old: str, new: str) -> bool:
    if old == new:
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and old:
        shutil.copy2(path, path.with_name(path.name + ".grove-rex.bak"))
    path.write_text(new, encoding="utf-8")
    return True


def lua_string(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def quote_toml(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


# ---- init.lua ---------------------------------------------------------------

def render_block(lua_file: str, key: str) -> str:
    return (
        f"{BEGIN}\n"
        f"dofile({lua_string(lua_file)})\n"
        f'rex.bind({lua_string(key)}, "grove_create")\n'
        f"{END}\n"
    )


def upsert_rex(text: str, lua_file: str, key: str) -> tuple[str, list[str]]:
    match = BLOCK_RE.search(text)
    if not match:
        block = render_block(lua_file, key)
        if text.strip():
            text = text.rstrip("\n") + "\n\n" + block
        else:
            text = block
        return text, [f"added grove-rex block (key {key})"]

    block = match.group(0)
    changes: list[str] = []
    wanted_dofile = f"dofile({lua_string(lua_file)})"
    if DOFILE_RE.search(block):
        new_block = DOFILE_RE.sub(lambda _m: wanted_dofile, block, count=1)
    else:
        new_block = block.replace(BEGIN + "\n", BEGIN + "\n" + wanted_dofile + "\n", 1)
    if new_block != block:
        changes.append("updated grove-rex dofile path")
    if not BIND_RE.search(new_block):
        new_block = new_block.replace(END, f'rex.bind({lua_string(key)}, "grove_create")\n{END}', 1)
        changes.append(f"bound {key}")
    # An existing bind line is the user's choice of key; leave it.
    text = text[: match.start()] + new_block + text[match.end():]
    return text, changes


def uninstall_rex(text: str) -> tuple[str, list[str]]:
    if not BLOCK_RE.search(text):
        return text, []
    text = BLOCK_RE.sub("", text)
    text = re.sub(r"\n{3,}", "\n\n", text).rstrip("\n")
    return (text + "\n" if text else ""), ["removed grove-rex block"]


def rex_check(text: str, lua_file: str) -> tuple[bool, str]:
    match = BLOCK_RE.search(text)
    if not match:
        return False, "init.lua has no grove-rex block"
    block = match.group(0)
    if f"dofile({lua_string(lua_file)})" not in block:
        return False, f"grove-rex block does not load {lua_file}"
    bind = BIND_RE.search(block)
    if not bind:
        return True, "grove-rex is loaded; no key bound (command palette only)"
    return True, f"{bind.group('key')} opens the Grove popup"


# ---- grove config.toml ------------------------------------------------------

def sections(text: str) -> list[tuple[str, int, int]]:
    matches = list(HEADER_RE.finditer(text))
    return [
        (m.group(0).strip(), m.start(), matches[i + 1].start() if i + 1 < len(matches) else len(text))
        for i, m in enumerate(matches)
    ]


def body_start(text: str, start: int) -> int:
    nl = text.find("\n", start)
    return len(text) if nl == -1 else nl + 1


def extract_inline_command(value: str) -> str | None:
    match = re.search(r'command\s*=\s*(["\'])(.*?)\1', value)
    if match:
        return match.group(2)
    match = re.search(r'^\s*(["\'])(.*?)\1\s*$', value)
    if match:
        return match.group(2)
    return value.strip() or None


def assignment(text: str) -> tuple[int, int, str] | None:
    """Span and form ('inline' or 'string') of `pre_delete = ...` under [hooks]."""
    for header, start, end in sections(text):
        if header != "[hooks]":
            continue
        b = body_start(text, start)
        m = re.search(rf"(?m)^[ \t]*{HOOK}\s*=\s*(?P<value>.+?)\s*$", text[b:end])
        if m:
            return b + m.start(), b + m.end(), m.group("value").strip()
    return None


def current_hook(text: str) -> str | None:
    for header, start, end in sections(text):
        if header == f"[hooks.{HOOK}]":
            m = COMMAND_LINE_RE.search(text[body_start(text, start):end])
            return m.group("value") if m else None
    found = assignment(text)
    return extract_inline_command(found[2]) if found else None


def hook_command(root: str) -> str:
    return f"{Path(root).resolve() / 'hooks' / SCRIPT} {{path}} {{name}}"


def is_ours(command: str | None) -> bool:
    return bool(command) and "grove-rex" in command and SCRIPT in command


def inline_hook(command: str) -> str:
    return f'{HOOK} = {{command = {quote_toml(command)}, timeout = "{TIMEOUT}", on_failure = "warn"}}'


def set_hook(text: str, command: str) -> str:
    for header, start, end in sections(text):
        if header == f"[hooks.{HOOK}]":
            b = body_start(text, start)
            m = COMMAND_LINE_RE.search(text[b:end])
            if m:
                return text[: b + m.start()] + f"command = {quote_toml(command)}" + text[b + m.end():]
            return text[:end] + f"command = {quote_toml(command)}\n" + text[end:]
    found = assignment(text)
    if found:
        s, e, _ = found
        indent = re.match(r"[ \t]*", text[s:e]).group(0)
        return text[:s] + indent + inline_hook(command) + text[e:]
    hooks = [x for x in sections(text) if x[0] == "[hooks]"]
    if not hooks:
        block = f"[hooks]\n{inline_hook(command)}\n"
        return (text.rstrip("\n") + "\n\n" + block) if text.strip() else block
    _h, start, end = hooks[0]
    at = end
    while at > start and text[at - 1] in "\r\n":
        at -= 1
    return text[:at] + "\n" + inline_hook(command) + text[at:]


def remove_hook(text: str) -> str:
    for header, start, end in sections(text):
        if header == f"[hooks.{HOOK}]":
            return text[:start] + text[end:]
    found = assignment(text)
    if found:
        s, e, _ = found
        if e < len(text) and text[e] == "\n":
            e += 1
        text = text[:s] + text[e:]
    # Drop a [hooks] header left with nothing under it.
    for header, start, end in sections(text):
        if header == "[hooks]" and not text[body_start(text, start):end].strip():
            text = text[:start] + text[end:]
            break
    return re.sub(r"\n{3,}", "\n\n", text)


def apply_grove(path: Path, root: str, prev: Path) -> list[str]:
    old = read(path)
    wanted = hook_command(root)
    current = current_hook(old)
    changes: list[str] = []
    if current is None:
        new = set_hook(old, wanted)
        changes.append(f"set hooks.{HOOK}")
    elif is_ours(current):
        new = set_hook(old, wanted) if current != wanted else old
        if new != old:
            changes.append(f"updated hooks.{HOOK} path")
    else:
        prev.parent.mkdir(parents=True, exist_ok=True)
        prev.write_text(current + "\n", encoding="utf-8")
        new = set_hook(old, wanted)
        changes.append(f"set hooks.{HOOK}; it runs the previous hook first ({current})")
    if new and not new.endswith("\n"):
        new += "\n"
    write_if_changed(path, old, new)
    return changes


def uninstall_grove(path: Path, prev: Path) -> list[str]:
    old = read(path)
    current = current_hook(old)
    if not is_ours(current):
        return [f"left hooks.{HOOK} unchanged ({current})"] if current else []
    saved = prev.read_text(encoding="utf-8").strip() if prev.exists() else ""
    if saved:
        new = set_hook(old, saved)
        change = f"restored previous hooks.{HOOK} ({saved})"
    else:
        new = remove_hook(old)
        change = f"removed hooks.{HOOK}"
    write_if_changed(path, old, new)
    if prev.exists():
        prev.unlink()
    return [change]


def grove_check(path: Path, root: str, prev: Path) -> tuple[bool, str]:
    current = current_hook(read(path))
    if current is None:
        return False, f"hooks.{HOOK} is not set"
    if not is_ours(current):
        return False, f"hooks.{HOOK} runs something else: {current}"
    if current != hook_command(root):
        return False, f"hooks.{HOOK} points at another grove-rex checkout: {current}"
    saved = prev.read_text(encoding="utf-8").strip() if prev.exists() else ""
    return True, f"hooks.{HOOK} closes the Rex session" + (f" (after: {saved})" if saved else "")


# ---- cli --------------------------------------------------------------------

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    for name in ("rex", "rex-uninstall", "rex-check"):
        p = sub.add_parser(name)
        p.add_argument("--config", required=True)
        if name != "rex-uninstall":
            p.add_argument("--lua-file", required=True)
        if name == "rex":
            p.add_argument("--key", default="cmd+g")
    for name in ("grove", "grove-uninstall", "grove-check"):
        p = sub.add_parser(name)
        p.add_argument("--config", required=True)
        p.add_argument("--prev", required=True)
        if name != "grove-uninstall":
            p.add_argument("--plugin-root", required=True)
    args = parser.parse_args(argv)
    config = Path(args.config)

    if args.cmd == "rex":
        old = read(config)
        new, changes = upsert_rex(old, args.lua_file, args.key)
        write_if_changed(config, old, new)
        print("\n".join(changes) if changes else "Rex config already wired")
        return 0
    if args.cmd == "rex-uninstall":
        old = read(config)
        new, changes = uninstall_rex(old)
        write_if_changed(config, old, new)
        print("\n".join(changes) if changes else "Rex config already unwired")
        return 0
    if args.cmd == "rex-check":
        ok, message = rex_check(read(config), args.lua_file)
        print(f"{'PASS' if ok else 'FAIL'}\trex\t{message}")
        return 0 if ok else 1
    if args.cmd == "grove":
        changes = apply_grove(config, args.plugin_root, Path(args.prev))
        print("\n".join(changes) if changes else "Grove hook already wired")
        return 0
    if args.cmd == "grove-uninstall":
        changes = uninstall_grove(config, Path(args.prev))
        print("\n".join(changes) if changes else "Grove hook already unwired")
        return 0
    ok, message = grove_check(config, args.plugin_root, Path(args.prev))
    print(f"{'PASS' if ok else 'FAIL'}\t{HOOK}\t{message}")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
