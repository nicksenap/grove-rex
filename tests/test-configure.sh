#!/bin/sh
# Tests scripts/configure.py and the pre_delete chain against temp configs.
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
configure="$root/scripts/configure.py"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/grove-rex-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
contains() { grep -Fq -- "$2" "$1" || fail "$3 (missing: $2)"; }
lacks() { ! grep -Fq -- "$2" "$1" || fail "$3 (unexpected: $2)"; }

plugin="$tmp/grove-rex"
mkdir -p "$plugin/hooks" "$plugin/rex"
plugin=$(CDPATH='' cd -- "$plugin" && pwd -P)
lua="$plugin/rex/grove.lua"
init="$tmp/init.lua"
grove="$tmp/config.toml"
prev="$tmp/state/pre_delete.prev"
hook="$plugin/hooks/pre-delete.sh {path} {name}"

# --- init.lua ---------------------------------------------------------------
printf 'rex.bind("cmd+e", "pane.zoom")\n' > "$init"
python3 "$configure" rex --config "$init" --lua-file "$lua" --key "ctrl+cmd+g" >/dev/null
contains "$init" 'rex.bind("cmd+e", "pane.zoom")' "keeps existing config"
contains "$init" "dofile(\"$lua\")" "adds dofile"
contains "$init" 'rex.bind("ctrl+cmd+g", "grove_create")' "binds key"
cp "$init" "$tmp/once"
python3 "$configure" rex --config "$init" --lua-file "$lua" --key "cmd+g" >/dev/null
cmp -s "$init" "$tmp/once" || fail "re-running rex install changes init.lua (or rebinds the user's key)"
python3 "$configure" rex-check --config "$init" --lua-file "$lua" >/dev/null || fail "rex-check after install"

python3 "$configure" rex --config "$init" --lua-file "/moved/rex/grove.lua" >/dev/null
contains "$init" 'dofile("/moved/rex/grove.lua")' "updates dofile path"
[ "$(grep -c 'grove-rex >>>' "$init")" = 1 ] || fail "duplicate block"

python3 "$configure" rex-uninstall --config "$init" >/dev/null
lacks "$init" "grove-rex" "uninstall removes block"
contains "$init" 'rex.bind("cmd+e", "pane.zoom")' "uninstall keeps the rest"

# --- grove: no hooks yet ----------------------------------------------------
printf 'workspace_dir = "/w"\n' > "$grove"
python3 "$configure" grove --config "$grove" --plugin-root "$plugin" --prev "$prev" >/dev/null
contains "$grove" "pre_delete = {command = \"$hook\"" "sets hook"
[ ! -e "$prev" ] || fail "no previous hook to save"
python3 "$configure" grove-uninstall --config "$grove" --prev "$prev" >/dev/null
lacks "$grove" "pre_delete" "uninstall removes hook"
lacks "$grove" "[hooks]" "uninstall removes empty [hooks]"

# --- grove: chains an existing hook (grove-herdr style) ---------------------
cat > "$grove" <<'EOF'
workspace_dir = "/w"

[hooks]
  post_create = {command = "/h/post-create.sh {path} {name}", timeout = "15s", on_failure = "warn"}
  pre_delete = {command = "/h/pre-delete.sh {path} {name}", timeout = "10s", on_failure = "warn"}
EOF
cp "$grove" "$tmp/orig.toml"
python3 "$configure" grove --config "$grove" --plugin-root "$plugin" --prev "$prev" >/dev/null
contains "$grove" "  pre_delete = {command = \"$hook\"" "replaces hook, keeps indent"
contains "$grove" "post_create = {command = \"/h/post-create.sh" "leaves post_create"
[ "$(cat "$prev")" = "/h/pre-delete.sh {path} {name}" ] || fail "saves previous hook"
python3 "$configure" grove --config "$grove" --plugin-root "$plugin" --prev "$prev" >/dev/null
[ "$(cat "$prev")" = "/h/pre-delete.sh {path} {name}" ] || fail "re-install must not overwrite saved hook with ours"
python3 "$configure" grove-check --config "$grove" --plugin-root "$plugin" --prev "$prev" >/dev/null || fail "grove-check"
python3 "$configure" grove-uninstall --config "$grove" --prev "$prev" >/dev/null
contains "$grove" 'pre_delete = {command = "/h/pre-delete.sh {path} {name}"' "uninstall restores previous hook"
[ ! -e "$prev" ] || fail "uninstall clears saved hook"

# --- pre-delete.sh runs the saved hook with path and name -------------------
mkdir -p "$tmp/state" "$tmp/bin"
printf '%s\n' "$tmp/bin/prev-hook.sh {path} {name}" > "$prev"
cat > "$tmp/bin/prev-hook.sh" <<EOF
#!/bin/sh
printf '%s|%s\n' "\$1" "\$2" > "$tmp/prev-ran"
EOF
chmod +x "$tmp/bin/prev-hook.sh"
PATH="/usr/bin:/bin" GROVE_REX_STATE="$tmp/state" sh "$root/hooks/pre-delete.sh" "/w/my ws" "my ws"
[ "$(cat "$tmp/prev-ran")" = "/w/my ws|my ws" ] || fail "chain passes path and name"

# --- shell syntax -----------------------------------------------------------
bash -n "$root/hooks/create.sh" || fail "create.sh syntax"
for f in install.sh uninstall.sh check.sh hooks/pre-delete.sh; do
  sh -n "$root/$f" || fail "$f syntax"
done

printf 'ok\n'
