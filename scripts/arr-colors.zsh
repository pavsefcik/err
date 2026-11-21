#!/usr/bin/env zsh
# arr-colors.zsh — the `arr //` prefix candidates beside the accents err
# already uses. A dev tool, nothing loads it.
#
#   ./scripts/arr-colors.zsh                 # palette + the five candidates
#   ./scripts/arr-colors.zsh 1;38;5;214      # any SGR codes you want to try
#
# Tabs do the aligning: a terminal advances the cursor by zero columns for an
# escape sequence, so columns line up even though the codes are invisible.
R=$'\e[0m'
D=$'\e[2m'

row() {  # code, sample, where it already lives
  printf '  %-11s ' "$1"
  printf '\e[%sm%s\e[0m\t%s\n' "$1" "$2" "$3"
}

cand() {  # code, note
  printf '  %-11s ' "$1"
  printf '\e[%smarr // \e[0mA glob matches filenames. The body is your own colour.\n' "$1"
  [[ -n "$2" ]] && printf '  %-11s %s%s%s\n' '' "$D" "$2" "$R"
  printf '\n'
}

if (( $# )); then
  printf '\n%s\n' "${D}── candidates ─────────────────────────────────────────────────────${R}"
  for c in "$@"; do cand "$c" ""; done
  exit 0
fi

printf '\n%s\n' "${D}── already in use ─────────────────────────────────────────────────${R}"
row '1;35'       'assistant>'        'menu titles, selected row, chat prompt'
row '1;36'       'you>'              'chat prompt, menu cursor glyph'
row '31'         '[error] …'         'failures only'
row '2'          'dim footer'        'secondary text everywhere'
row '38;5;240'   '3t 1.2k'           'RPROMPT turn/token counter'
row '1;38;5;212' '▌▌ Curated models' 'catalog header, TUI sign-off'
row '1;38;5;214' 'arr // …'          'the answer prefix'

printf '\n%s\n' "${D}── candidates, as they would look ─────────────────────────────────${R}"
cand '1;38;5;212' "pink   — err's brand accent; taken by the catalog headers"
cand '1;38;5;214' 'amber  — chosen: unused, warm, and nothing else claims it'
cand '1;38;5;79'  'mint   — unused, calm; near the cyan you> on some themes'
cand '1;38;5;105' 'mauve  — unused, but close to the 1;35 menu chrome'
cand '1;97'       'white  — no hue clash; safest on light and dark, least personality'

printf '%s\n' "${D}switch your terminal theme and re-run to see the other background${R}"
printf '%s\n\n' "${D}a pipe sees none of this: err \"<q>\" | cat gives plain text${R}"
