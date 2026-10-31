#!/usr/bin/env bash
# grove-rex popup. Steps: name → preset or repos (fzf) → branch, then a
# non-interactive `gw create`, then open the workspace as a Rex session and
# switch the Rex app to it.
# usage: create.sh [client-id]
set -euo pipefail

client=${1:-}

original_stty=$(stty -g)
trap 'stty "$original_stty" 2>/dev/null || true' EXIT
trap 'exit 130' HUP INT TERM

art=(
'                          ^                             ^'
'          ^              /^\             ^             /^\             ^'
'         /^\     ^      /^^^\    ^      /^\           /^^^\    ^      /^\'
'  ^     /^^^\   /^\    /^^^^^\  /^\    /^^^\   ^     /^^^^^\  /^\    /^^^\'
' /^\   /^^^^^\ /^^^\  /^^^^^^^\/^^^\  /^^^^^\ /^\   /^^^^^^^\/^^^\  /^^^^^\'
'/^^^\ /^^^^^^^/^^^^^\/^^^^^^^^/^^^^^\/^^^^^^^/^^^\ /^^^^^^^^/^^^^^\/^^^^^^^\'
'__|_______|______|________|______|_______|_____|________|______|_______|____'
)

DIM=$'\033[38;5;240m' SAGE=$'\033[38;5;108m' TREE=$'\033[38;5;65m' BOLD=$'\033[1m' RESET=$'\033[0m'

fail() {
  printf '\n  %s\n  press any key to close' "$1"
  read -r -s -n 1 _ || true
  exit 1
}

term_size() {
  local size
  size=$(stty size 2>/dev/null || echo "18 72")
  rows=${size% *}; cols=${size#* }
}

# ---- text field -----------------------------------------------------------

f_title="" f_label="" f_hint="" value=""
pad=0 top=1 inner=20

draw_input() {
  local shown=$value
  (( ${#shown} > inner - 9 )) && shown=…${shown: -$(( inner - 10 ))}
  printf '\033[%d;%dH%s│%s %s%-6s%s  %-*s%s│%s\033[%d;%dH' \
    "$(( top + 3 ))" "$(( pad + 1 ))" "$DIM" "$RESET" "$SAGE" "$f_label" "$RESET" \
    "$(( inner - 9 ))" "$shown" "$DIM" "$RESET" \
    "$(( top + 3 ))" "$(( pad + 11 + ${#shown} ))"
}

draw() {
  local bw line i art_rows=${#art[@]} block=6 art_col
  term_size
  bw=$(( cols < 52 ? cols - 4 : 48 )); (( bw < 24 )) && bw=24
  inner=$(( bw - 2 ))
  pad=$(( (cols - bw) / 2 )); (( pad < 0 )) && pad=0
  (( rows >= block + art_rows + 2 )) || art_rows=0
  top=$(( (rows - block - art_rows) / 2 )); (( top < 1 )) && top=1
  art_col=$(( cols > 76 ? (cols - 76) / 2 + 1 : 1 ))
  line=$(printf '%*s' "$inner" '' | sed 's/ /─/g')

  printf '\033[?2026h\033[2J'
  for (( i = 0; i < art_rows; i++ )); do
    printf '\033[%d;%dH%s%s%s' "$(( rows - art_rows + 1 + i ))" "$art_col" "$TREE" \
      "$(printf '%s' "${art[i]}" | cut -c1-"$cols")" "$RESET"
  done
  printf '\033[%d;%dH%s%s%s' "$top" "$(( (cols - ${#f_title}) / 2 + 1 ))" "$BOLD" "$f_title" "$RESET"
  printf '\033[%d;%dH%s╭%s╮%s' "$(( top + 2 ))" "$(( pad + 1 ))" "$DIM" "$line" "$RESET"
  printf '\033[%d;%dH%s╰%s╯%s' "$(( top + 4 ))" "$(( pad + 1 ))" "$DIM" "$line" "$RESET"
  printf '\033[%d;%dH%s%s%s' "$(( top + 5 ))" "$(( (cols - ${#f_hint}) / 2 + 1 ))" "$DIM" "$f_hint" "$RESET"
  draw_input
  printf '\033[?2026l'
}

# read_field TITLE LABEL HINT DEFAULT → sets $value; returns 1 on Esc.
read_field() {
  f_title=$1 f_label=$2 f_hint=$3 value=$4
  local saved key rc=0
  saved=$(stty -g)
  stty -echo -icanon min 1 time 0
  trap draw WINCH   # Rex sizes the popup after it starts.
  draw
  while true; do
    if IFS= read -r -n 1 key; then :; else
      local st=$?
      (( st > 128 )) && continue   # interrupted by SIGWINCH
      break
    fi
    case "$key" in
      $'\e') rc=1; break ;;
      "") break ;;
      $'\177'|$'\b') [[ -n "$value" ]] && value=${value%?}; draw_input ;;
      [[:print:]]) value+=$key; draw_input ;;
    esac
  done
  trap - WINCH
  stty "$saved"
  value=$(printf '%s' "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  return "$rc"
}

# ---- list picker ------------------------------------------------------------

# pick TITLE HEADER [fzf args...] < lines → prints the chosen lines; 1 on Esc.
pick() {
  local title=$1 header=$2 margin
  shift 2
  term_size
  margin=$(( cols > 64 ? (cols - 60) / 2 : 1 ))
  local extra=()
  # --gutter is fzf 0.58+; older fzf (e.g. Ubuntu 24.04's 0.44) rejects it.
  fzf --help 2>/dev/null | grep -q -- '--gutter' && extra+=(--gutter=' ')
  FZF_DEFAULT_OPTS="" fzf "${extra[@]}" --height=100% --layout=reverse --ansi \
    --border=rounded --border-label=" $title " --margin="1,$margin" --padding=0,1 \
    --cycle --info=inline-right --prompt='/ ' --pointer='›' --marker='✓' \
    --header="$header" --header-first --no-scrollbar --separator='─' \
    --color='fg:250,fg+:15:bold,bg:-1,bg+:-1,hl:108,hl+:108,border:240,label:15:bold' \
    --color='prompt:108,pointer:108,marker:108,info:240,header:240,separator:238,gutter:-1' \
    "$@"
}

preset_lines() {
  local tsv w
  tsv=$(gw preset list --json 2>/dev/null | jq -r 'to_entries[] | [.key, (.value.repos | join(", "))] | @tsv')
  w=$(printf '%s\n' "$tsv" | cut -f1 | awk '{ if (length > m) m = length } END { print m + 2 }')
  [[ -n "$tsv" ]] && printf '%s\n' "$tsv" | while IFS=$'\t' read -r p repos; do
    printf '%-*s%s%s%s\t%s\n' "$w" "$p" "$DIM" "$repos" "$RESET" "$p"
  done
  printf '%sPick repos manually…%s\t%s\n' "$SAGE" "$RESET" "__manual__"
}

# ---- flow -------------------------------------------------------------------

name="" branch="" preset="" repos="" step=name
while true; do
  case $step in
    name)
      read_field "create grove workspace" "name" "↩ next  ·  esc cancel" "$name" || exit 0
      name=$value
      [[ -n "$name" ]] || exit 0
      step=source ;;
    source)
      choice=$(preset_lines | pick "repos for $name" "↩ pick  ·  esc back" \
        --delimiter=$'\t' --with-nth=1 | cut -f2) || { step=name; continue; }
      if [[ "$choice" == "__manual__" ]]; then
        step=repos
      else
        preset=$choice repos="" step=branch
      fi ;;
    repos)
      picked=$(gw repos -o name | sort -f | pick "repos for $name" "tab select  ·  ↩ done  ·  esc back" \
        --multi) || { step=source; continue; }
      repos=$(printf '%s\n' "$picked" | paste -sd, -)
      preset="" step=branch ;;
    branch)
      read_field "branch for $name" "branch" "↩ create  ·  esc back" "${branch:-$name}" \
        || { [[ -n "$preset" ]] && step=source || step=repos; continue; }
      branch=${value:-$name}
      break ;;
  esac
done

printf '\033[2J\033[H\n  %screating %s%s %s(%s)%s\n\n' "$BOLD" "$name" "$RESET" "$DIM" "${preset:-$repos}" "$RESET"
args=(create "$name" -b "$branch")
if [[ -n "$preset" ]]; then args+=(-p "$preset"); else args+=(-r "$repos"); fi
# GROVE_HERDR_OPEN=0: if grove-herdr is installed, its post_create hook would
# also open a Herdr workspace.
GROVE_HERDR_OPEN=0 gw "${args[@]}" || fail "gw create failed"

path=$(gw ws list --json | jq -r --arg n "$name" '.[] | select(.name == $n) | .path' | head -n 1)
[[ -n "$path" && -d "$path" ]] || fail "could not find workspace path for $name"

# Reuse a session already labelled with this name, else create one.
sid=$(rex ls --json | jq -r --arg n "$name" '.sessions[] | select(.label == $n) | .session_id' | head -n 1)
if [[ -z "$sid" ]]; then
  sid=$(rex new "$name" -c "$path" --json | jq -er '.session_id') || fail "rex new failed"
fi

app_client() {
  rex client ls --json | jq -r '[.clients[] | select(.info.kind == "app")][0].client_id // empty'
}
switch_to() { rex -C "$1" "do" session.select session_id="$sid" >/dev/null 2>&1; }

# From a key press, $client is the app. From `rex do` it is the CLI, so fall back.
if ! { [[ -n "$client" ]] && switch_to "$client"; }; then
  app=$(app_client)
  [[ -n "$app" ]] || fail "session $name created; no Rex app client to switch"
  switch_to "$app" || fail "session $name created; switch failed (turn on Remote Control in Rex Settings > Rex Server)"
fi
