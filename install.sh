#!/bin/sh
set -eu

REPO_URL=${GROVE_REX_REPO:-https://github.com/nicksenap/grove-rex.git}
INSTALL_DIR=${GROVE_REX_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/grove-rex}
STATE_DIR=${GROVE_REX_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/grove-rex}
REX_CONFIG_FILE=${REX_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/rex/init.lua}
GROVE_DIR=${GROVE_DIR:-$HOME/.grove}
GROVE_CONFIG=${GROVE_CONFIG:-$GROVE_DIR/config.toml}
KEY=${GROVE_REX_KEY:-cmd+g}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "install.sh needs $1 on PATH"
}

abs_dir() {
  CDPATH='' cd -- "$1" && pwd
}

ensure_checkout() {
  need git
  if [ -d "$INSTALL_DIR/.git" ]; then
    git -C "$INSTALL_DIR" fetch --quiet origin 2>/dev/null || \
      printf 'warning: could not fetch grove-rex; using existing checkout\n' >&2
    git -C "$INSTALL_DIR" merge --ff-only --quiet origin/main 2>/dev/null || true
  else
    mkdir -p "$(dirname -- "$INSTALL_DIR")"
    git clone --quiet "$REPO_URL" "$INSTALL_DIR"
  fi
  [ -f "$INSTALL_DIR/rex/grove.lua" ] || die "clone at $INSTALL_DIR is missing rex/grove.lua"
  [ -x "$INSTALL_DIR/install.sh" ] || chmod +x "$INSTALL_DIR/install.sh"
}

script_path=$0
case "$script_path" in
  /*) ;;
  *) script_path=$(pwd)/$script_path ;;
esac

here=""
if [ -f "$script_path" ]; then
  here=$(abs_dir "$(dirname -- "$script_path")")
fi

if [ -n "$here" ] && [ -f "$here/rex/grove.lua" ]; then
  plugin_root=$here
else
  ensure_checkout
  exec "$INSTALL_DIR/install.sh"
fi

need rex
need gw
need python3
need jq
need fzf

chmod +x "$plugin_root/check.sh" "$plugin_root/uninstall.sh" \
  "$plugin_root/hooks/create.sh" "$plugin_root/hooks/pre-delete.sh" \
  "$plugin_root/scripts/configure.py"

configure="$plugin_root/scripts/configure.py"

printf '==> wiring Rex config\n'
python3 "$configure" rex --config "$REX_CONFIG_FILE" \
  --lua-file "$plugin_root/rex/grove.lua" --key "$KEY" | sed 's/^/    /'

printf '==> wiring Grove pre_delete hook\n'
python3 "$configure" grove --config "$GROVE_CONFIG" \
  --plugin-root "$plugin_root" --prev "$STATE_DIR/pre_delete.prev" | sed 's/^/    /'

if rex config check >/dev/null 2>&1; then
  rex config reload >/dev/null 2>&1 || \
    printf '    could not reload Rex; run: rex config reload\n'
else
  printf '    rex config check reports errors; run: rex config check\n'
fi

printf '\ngrove-rex is installed. Re-run this script any time; it is safe.\n'
printf '  plugin: %s\n' "$plugin_root"
printf '  rex:    %s\n' "$REX_CONFIG_FILE"
printf '  grove:  %s\n' "$GROVE_CONFIG"
printf '\n==> verifying\n'
"$plugin_root/check.sh"
