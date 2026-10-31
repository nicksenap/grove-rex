#!/bin/sh
set -u

INSTALL_DIR=${GROVE_REX_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/grove-rex}
STATE_DIR=${GROVE_REX_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/grove-rex}
REX_CONFIG_FILE=${REX_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/rex/init.lua}
GROVE_DIR=${GROVE_DIR:-$HOME/.grove}
GROVE_CONFIG=${GROVE_CONFIG:-$GROVE_DIR/config.toml}

script_path=$0
case "$script_path" in
  /*) ;;
  *) script_path=$(pwd)/$script_path ;;
esac

plugin_root=$INSTALL_DIR
if [ -f "$script_path" ]; then
  here=$(CDPATH= cd -- "$(dirname -- "$script_path")" && pwd)
  [ -f "$here/rex/grove.lua" ] && plugin_root=$here
fi

failed=0
warned=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; failed=$((failed + 1)); }
warn() { printf 'WARN  %s\n' "$1"; warned=$((warned + 1)); }

printf 'Checking grove-rex install\n\n'

for tool in rex gw python3 jq fzf bash; do
  if command -v "$tool" >/dev/null 2>&1; then
    pass "$tool is on PATH ($(command -v "$tool"))"
  else
    fail "$tool is not on PATH"
  fi
done

if [ -f "$plugin_root/rex/grove.lua" ]; then
  pass "plugin files are at $plugin_root"
else
  fail "plugin files not found (install.sh clones to $INSTALL_DIR)"
fi

for hook in create.sh pre-delete.sh; do
  path="$plugin_root/hooks/$hook"
  if [ -x "$path" ]; then
    pass "hooks/$hook is executable"
  else
    fail "hooks/$hook is missing or not executable"
  fi
done

configure="$plugin_root/scripts/configure.py"
if [ -f "$configure" ] && command -v python3 >/dev/null 2>&1; then
  out=$(python3 "$configure" rex-check --config "$REX_CONFIG_FILE" --lua-file "$plugin_root/rex/grove.lua")
  case "$out" in
    PASS*) pass "$(printf '%s' "$out" | cut -f3)" ;;
    *) fail "$(printf '%s' "$out" | cut -f3) ($REX_CONFIG_FILE)" ;;
  esac
  out=$(python3 "$configure" grove-check --config "$GROVE_CONFIG" \
    --plugin-root "$plugin_root" --prev "$STATE_DIR/pre_delete.prev")
  case "$out" in
    PASS*) pass "$(printf '%s' "$out" | cut -f3)" ;;
    *) fail "$(printf '%s' "$out" | cut -f3) ($GROVE_CONFIG)" ;;
  esac
else
  fail "could not check Rex/Grove config"
fi

if command -v rex >/dev/null 2>&1; then
  if rex actions 2>/dev/null | grep -q '^grove_create '; then
    pass "Rex server has the grove_create action"
  else
    fail "Rex server does not have grove_create (run: rex config reload)"
  fi
fi

printf '\n'
if [ "$failed" -eq 0 ]; then
  if [ "$warned" -eq 0 ]; then
    printf 'All checks passed.\n'
  else
    printf 'Ready, with %s warning(s).\n' "$warned"
  fi
  exit 0
fi
printf '%s check(s) failed. Fix: curl -fsSL https://raw.githubusercontent.com/nicksenap/grove-rex/main/install.sh | sh\n' "$failed"
exit 1
