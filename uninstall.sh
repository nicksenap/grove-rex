#!/bin/sh
set -eu

INSTALL_DIR=${GROVE_REX_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/grove-rex}
STATE_DIR=${GROVE_REX_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/grove-rex}
REX_CONFIG_FILE=${REX_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/rex/init.lua}
GROVE_DIR=${GROVE_DIR:-$HOME/.grove}
GROVE_CONFIG=${GROVE_CONFIG:-$GROVE_DIR/config.toml}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

script_path=$0
case "$script_path" in
  /*) ;;
  *) script_path=$(pwd)/$script_path ;;
esac

plugin_root=""
if [ -f "$script_path" ]; then
  here=$(CDPATH= cd -- "$(dirname -- "$script_path")" && pwd)
  [ -f "$here/scripts/configure.py" ] && plugin_root=$here
fi
if [ -z "$plugin_root" ] && [ -f "$INSTALL_DIR/scripts/configure.py" ]; then
  plugin_root=$INSTALL_DIR
fi
[ -n "$plugin_root" ] || die "grove-rex is not installed at $INSTALL_DIR"
command -v python3 >/dev/null 2>&1 || die "uninstall.sh needs python3 on PATH"

configure="$plugin_root/scripts/configure.py"

printf '==> removing Rex config block\n'
python3 "$configure" rex-uninstall --config "$REX_CONFIG_FILE" | sed 's/^/    /'

printf '==> restoring Grove pre_delete hook\n'
python3 "$configure" grove-uninstall --config "$GROVE_CONFIG" \
  --prev "$STATE_DIR/pre_delete.prev" | sed 's/^/    /'

if command -v rex >/dev/null 2>&1; then
  rex config reload >/dev/null 2>&1 || true
fi

printf '\ngrove-rex is uninstalled. Re-run this script any time; it is safe.\n'
printf 'The checkout at %s is left in place.\n' "$plugin_root"
printf 'Delete that directory yourself if you want the files gone.\n'
