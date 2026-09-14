#!/usr/bin/env bash
set -euo pipefail

mode="output"
case "${1:-}" in
    -i|--input|input) mode="input" ;;
esac

if [ "$mode" = "input" ]; then
    header="Sources:"
    prompt="Input device"
else
    header="Sinks:"
    prompt="Output device"
fi

choices=$(
    wpctl status \
        | sed -n "/${header}/,/endpoints:/p" \
        | grep -E '\*?[[:space:]]*[0-9]+\.' \
        | sed 's/[[:space:]]*\[.*//' \
        | while IFS= read -r raw; do
              case "$raw" in
                  *\**) mark="* " ;;
                  *) mark="  " ;;
              esac
              line=$(printf '%s' "$raw" | sed 's/^[^0-9]*//')
              id="${line%%.*}"
              name=$(printf '%s' "$line" | sed 's/^[0-9]*\.[[:space:]]*//')
              printf '%s%s\t%s\n' "$mark" "$name" "$id"
          done
)

[ -n "$choices" ] || exit 1

selected=$(printf '%s\n' "$choices" | cut -f1 | fuzzel --dmenu --prompt "$prompt ")
[ -n "$selected" ] || exit 0

target=$(printf '%s\n' "$choices" | grep -Fm1 "$(printf '%s\t' "$selected")" | cut -f2)
[ -n "$target" ] || exit 0

wpctl set-default "$target"
