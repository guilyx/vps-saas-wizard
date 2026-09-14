#!/usr/bin/env bash
# ui.sh - terminal UI: colours, boxes, prompts, menus, spinner, progress.
# Degrades gracefully when stdout is not a TTY or NO_COLOR is set.

UI_TTY=false
[[ -t 1 && -t 0 ]] && UI_TTY=true
UI_COLOR=true
[[ -n "${NO_COLOR:-}" || "$UI_TTY" == false || "${TERM:-dumb}" == dumb ]] && UI_COLOR=false
UI_UTF8=false
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in *UTF-8*|*utf8*|*UTF8*|*utf-8*) UI_UTF8=true ;; esac
[[ "${WIZARD_ASCII:-false}" == true ]] && UI_UTF8=false

ui_cols() { local c; c=$(tput cols 2>/dev/null || echo 80); (( c > 100 )) && c=100; echo "$c"; }

# ui_fill GLYPH COUNT : print GLYPH COUNT times.
# Note: `tr ' ' "$glyph"` cannot be used here - tr is byte-oriented and would
# emit only the first byte of a multibyte box-drawing character, producing
# invalid UTF-8. Bash pattern substitution is character-safe.
ui_fill() {
  local glyph="$1" n="$2" pad
  (( n > 0 )) || return 0
  printf -v pad "%${n}s" ''
  printf '%s' "${pad// /$glyph}"
}

if [[ "$UI_COLOR" == true ]]; then
  C_RESET=$'\033[0m'   C_BOLD=$'\033[1m'    C_DIM=$'\033[2m'    C_ITAL=$'\033[3m'
  C_RED=$'\033[38;5;203m' C_GREEN=$'\033[38;5;114m' C_YELLOW=$'\033[38;5;221m'
  C_BLUE=$'\033[38;5;75m' C_MAGENTA=$'\033[38;5;176m' C_CYAN=$'\033[38;5;80m'
  C_GRAY=$'\033[38;5;245m' C_WHITE=$'\033[38;5;255m'
  C_ACCENT=$'\033[38;5;141m'  # violet accent
  C_ACCENT2=$'\033[38;5;81m'  # sky accent
  C_BG_ACCENT=$'\033[48;5;141m\033[38;5;232m'
else
  C_RESET='' C_BOLD='' C_DIM='' C_ITAL='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE=''
  C_MAGENTA='' C_CYAN='' C_GRAY='' C_WHITE='' C_ACCENT='' C_ACCENT2='' C_BG_ACCENT=''
fi

if [[ "$UI_UTF8" == true ]]; then
  G_OK='✔' G_ERR='✖' G_WARN='▲' G_INFO='●' G_ARROW='➜' G_BULLET='•' G_POINTER='❯'
  G_HL='─' G_VL='│' G_TL='╭' G_TR='╮' G_BL='╰' G_BR='╯' G_PBAR='█' G_PEMPTY='░'
  G_RADIO_ON='◉' G_RADIO_OFF='○' G_CHECK_ON='☑' G_CHECK_OFF='☐'
  SPIN_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
else
  G_OK='+' G_ERR='x' G_WARN='!' G_INFO='*' G_ARROW='->' G_BULLET='-' G_POINTER='>'
  G_HL='-' G_VL='|' G_TL='+' G_TR='+' G_BL='+' G_BR='+' G_PBAR='#' G_PEMPTY='.'
  G_RADIO_ON='(*)' G_RADIO_OFF='( )' G_CHECK_ON='[x]' G_CHECK_OFF='[ ]'
  SPIN_FRAMES=('|' '/' '-' '\')
fi

# ---------------------------------------------------------------------------
# Basic message helpers
# ---------------------------------------------------------------------------
ui_ok()    { printf '  %s%s%s %s\n' "$C_GREEN" "$G_OK" "$C_RESET" "$*"; }
ui_error() { printf '  %s%s %s%s\n' "$C_RED" "$G_ERR" "$*" "$C_RESET" >&2; }
ui_warn()  { printf '  %s%s%s %s\n' "$C_YELLOW" "$G_WARN" "$C_RESET" "$*"; }
ui_info()  { printf '  %s%s%s %s\n' "$C_BLUE" "$G_INFO" "$C_RESET" "$*"; }
ui_dim()   { printf '%s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }
ui_cmd()   { printf '    %s%s %s%s\n' "$C_GRAY" "$G_ARROW" "$*" "$C_RESET"; }
ui_bullet(){ printf '    %s%s%s %s\n' "$C_ACCENT" "$G_BULLET" "$C_RESET" "$*"; }
ui_note()  { printf '    %s%s%s\n' "$C_GRAY" "$*" "$C_RESET"; }
ui_blank() { printf '\n'; }

ui_hr() {
  local cols; cols=$(ui_cols)
  printf '%s' "$C_GRAY"; ui_fill "$G_HL" "$cols"; printf '%s\n' "$C_RESET"
}

# ui_kv "Key" "Value"
ui_kv() { printf '    %s%-24s%s %s\n' "$C_GRAY" "$1" "$C_RESET" "$2"; }

# ui_box "title" lines...  : rounded box
ui_box() {
  local title="$1"; shift
  local cols width line inner
  # Split any argument that contains newlines into separate lines.
  local -a lines=() arg
  for arg in "$@"; do
    while IFS= read -r line || [[ -n "$line" ]]; do lines+=("$line"); done <<<"$arg"
  done
  set -- "${lines[@]}"
  cols=$(ui_cols); width=$((cols - 4))
  inner=$((width - 2))
  printf '  %s%s%s' "$C_ACCENT" "$G_TL" "$G_HL"
  if [[ -n "$title" ]]; then
    printf ' %s%s%s%s ' "$C_BOLD" "$title" "$C_RESET" "$C_ACCENT"
    ui_fill "$G_HL" "$((inner - ${#title} - 3))"
  else
    ui_fill "$G_HL" "$((inner - 1))"
  fi
  printf '%s%s\n' "$G_TR" "$C_RESET"
  for line in "$@"; do
    # strip ANSI for width computation
    local plain; plain=$(printf '%s' "$line" | sed 's/\x1b\[[0-9;]*m//g')
    printf '  %s%s%s %s' "$C_ACCENT" "$G_VL" "$C_RESET" "$line"
    printf "%$((inner - ${#plain} - 1))s" ''
    printf '%s%s%s\n' "$C_ACCENT" "$G_VL" "$C_RESET"
  done
  printf '  %s%s' "$C_ACCENT" "$G_BL"
  ui_fill "$G_HL" "$inner"
  printf '%s%s\n' "$G_BR" "$C_RESET"
}

ui_banner() {
  local v="${1:-}"
  ui_blank
  if [[ "$UI_UTF8" == true ]]; then
    printf '%s' "$C_ACCENT"
    cat <<'EOF'
   __   ______  ____    ____             ____    _      __ _                       __
   \ \ / /  _ \/ ___|  / ___|  __ _  __ _/ ___|  \ \    / /(_)______ _ _ __ ___  __/ /
    \ V /| |_) \___ \  \___ \ / _` |/ _` \___ \   \ \/\/ / | |_  / _` | '__/ _ \/ _  /
     | | |  __/ ___) |  ___) | (_| | (_| |___) |   \    /  | |/ / (_| | | | (_) | (_| |
     |_| |_|   |____/  |____/ \__,_|\__,_|____/     \/\/   |_/___\__,_|_|  \___/ \__,_|
EOF
    printf '%s' "$C_RESET"
  else
    printf '%s%s  VPS SaaS Wizard%s\n' "$C_BOLD" "$C_ACCENT" "$C_RESET"
  fi
  printf '   %sProduction-grade SaaS deployment on a bare VPS%s  %sv%s%s\n' \
    "$C_DIM" "$C_RESET" "$C_GRAY" "$v" "$C_RESET"
  printf '   %sDocker Compose %s Caddy/Traefik %s UFW %s fail2ban %s Tailscale %s backups%s\n' \
    "$C_GRAY" "$G_BULLET" "$G_BULLET" "$G_BULLET" "$G_BULLET" "$G_BULLET" "$C_RESET"
  ui_blank
}

# ui_step_header N TOTAL "Title" "subtitle"
ui_step_header() {
  local n="$1" total="$2" title="$3" sub="${4:-}"
  ui_blank
  printf '  %s Step %s/%s %s %s%s%s' "$C_BG_ACCENT" "$n" "$total" "$C_RESET" "$C_BOLD" "$title" "$C_RESET"
  [[ -n "$sub" ]] && printf '  %s%s%s' "$C_GRAY" "$sub" "$C_RESET"
  printf '\n'
  ui_hr
}

ui_section() { printf '\n  %s%s%s\n' "$C_BOLD$C_ACCENT2" "$*" "$C_RESET"; }

# ui_progress CURRENT TOTAL "label"
ui_progress() {
  local cur="$1" total="$2" label="${3:-}" width=28 filled i
  filled=$(( cur * width / total ))
  printf '  %s' "$C_ACCENT"
  for ((i=0;i<filled;i++)); do printf '%s' "$G_PBAR"; done
  printf '%s' "$C_GRAY"
  for ((i=filled;i<width;i++)); do printf '%s' "$G_PEMPTY"; done
  printf '%s %s%2d/%d%s  %s\n' "$C_RESET" "$C_BOLD" "$cur" "$total" "$C_RESET" "$label"
}

# ---------------------------------------------------------------------------
# Spinner. ui_spin_try returns the command's exit code; ui_spin aborts on
# failure, like run() vs run_try().
# ---------------------------------------------------------------------------
ui_spin() { ui_spin_try "$@" || die "Aborting: a required command failed."; }

ui_spin_try() {
  local label="$1"; shift
  if [[ "$UI_TTY" != true || "$DRY_RUN" == true || "$VERBOSE" == true ]]; then
    printf '  %s%s%s %s\n' "$C_GRAY" "$G_ARROW" "$C_RESET" "$label"
    run_try "$@"
    return
  fi
  local rc=0 start; start=$SECONDS
  run_try "$@" &
  local pid=$! i=0
  tput civis 2>/dev/null || true
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r  %s%s%s %s %s(%ds)%s ' "$C_ACCENT" "${SPIN_FRAMES[i % ${#SPIN_FRAMES[@]}]}" "$C_RESET" "$label" "$C_GRAY" $((SECONDS - start)) "$C_RESET"
    i=$((i + 1)); sleep 0.1
  done
  wait "$pid" || rc=$?
  tput cnorm 2>/dev/null || true
  printf '\r\033[K'
  if (( rc == 0 )); then
    printf '  %s%s%s %s %s(%ds)%s\n' "$C_GREEN" "$G_OK" "$C_RESET" "$label" "$C_GRAY" $((SECONDS - start)) "$C_RESET"
  else
    printf '  %s%s %s%s %s(failed)%s\n' "$C_RED" "$G_ERR" "$label" "$C_RESET" "$C_RED" "$C_RESET"
  fi
  return "$rc"
}

# ---------------------------------------------------------------------------
# Prompts. Every prompt honours NONINTERACTIVE: the default is used as-is.
# Results are returned in the REPLY variable.
# ---------------------------------------------------------------------------
_ui_prompt_label() {
  local label="$1" def="$2"
  printf '  %s?%s %s%s%s' "$C_ACCENT" "$C_RESET" "$C_BOLD" "$label" "$C_RESET"
  [[ -n "$def" ]] && printf ' %s(%s)%s' "$C_GRAY" "$def" "$C_RESET"
  printf ': '
}

# ask "Label" "default" [validator_fn]   -> REPLY
ask() {
  local label="$1" def="${2:-}" validator="${3:-}" input
  if [[ "$NONINTERACTIVE" == true ]]; then
    REPLY="$def"
    if [[ -n "$validator" ]] && ! "$validator" "$REPLY"; then
      die "invalid value for '$label': '$REPLY' (non-interactive mode)"
    fi
    return 0
  fi
  while true; do
    _ui_prompt_label "$label" "$def"
    IFS= read -r input </dev/tty || input=""
    input=${input:-$def}
    if [[ -n "$validator" ]] && ! "$validator" "$input"; then
      ui_error "${VALIDATION_ERROR:-Invalid value}"
      continue
    fi
    REPLY="$input"
    return 0
  done
}

# ask_required "Label" "default" [validator]  : refuses empty
ask_required() {
  local label="$1" def="${2:-}" validator="${3:-}"
  while true; do
    ask "$label" "$def" "$validator"
    [[ -n "$REPLY" ]] && return 0
    [[ "$NONINTERACTIVE" == true ]] && die "'$label' is required (non-interactive mode)"
    ui_error "This value is required."
  done
}

# ask_secret "Label" "default"  : hidden input
ask_secret() {
  local label="$1" def="${2:-}" input
  if [[ "$NONINTERACTIVE" == true ]]; then REPLY="$def"; return 0; fi
  local shown=""; [[ -n "$def" ]] && shown="****"
  _ui_prompt_label "$label" "$shown"
  IFS= read -rs input </dev/tty || input=""
  printf '\n'
  REPLY=${input:-$def}
}

# ask_yn "Label" default(true|false)  -> returns 0 for yes
ask_yn() {
  local label="$1" def="${2:-true}" hint input
  local defbool=false
  case "${def,,}" in 1|true|yes|y|on) defbool=true ;; esac
  if [[ "$NONINTERACTIVE" == true ]]; then
    [[ "$defbool" == true ]]; return
  fi
  if [[ "$defbool" == true ]]; then hint="Y/n"; else hint="y/N"; fi
  while true; do
    printf '  %s?%s %s%s%s %s[%s]%s: ' "$C_ACCENT" "$C_RESET" "$C_BOLD" "$label" "$C_RESET" "$C_GRAY" "$hint" "$C_RESET"
    IFS= read -r input </dev/tty || input=""
    case "${input,,}" in
      "") [[ "$defbool" == true ]]; return ;;
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) ui_error "Please answer y or n." ;;
    esac
  done
}

# ask_choice "Label" "default_value" "value|Label|description" ...
# Arrow-key menu on a TTY, numbered fallback otherwise. Sets REPLY=value.
ask_choice() {
  local label="$1" def="$2"; shift 2
  local -a values labels descs
  local opt sel=0 i v l d
  for opt in "$@"; do
    IFS='|' read -r v l d <<<"$opt"
    values+=("$v"); labels+=("${l:-$v}"); descs+=("${d:-}")
    [[ "$v" == "$def" ]] && sel=$(( ${#values[@]} - 1 ))
  done
  if [[ "$NONINTERACTIVE" == true ]]; then
    for v in "${values[@]}"; do [[ "$v" == "$def" ]] && { REPLY="$def"; return 0; }; done
    die "invalid choice for '$label': '$def' (options: ${values[*]})"
  fi
  local n=${#values[@]}
  if [[ "$UI_TTY" != true ]]; then
    printf '  %s?%s %s%s%s\n' "$C_ACCENT" "$C_RESET" "$C_BOLD" "$label" "$C_RESET"
    for ((i=0;i<n;i++)); do printf '     %d) %s  %s%s%s\n' $((i+1)) "${labels[i]}" "$C_GRAY" "${descs[i]}" "$C_RESET"; done
    while true; do
      printf '  choice [%d]: ' $((sel+1))
      IFS= read -r opt </dev/tty || opt=""
      opt=${opt:-$((sel+1))}
      if [[ "$opt" =~ ^[0-9]+$ ]] && (( opt>=1 && opt<=n )); then REPLY="${values[opt-1]}"; return 0; fi
    done
  fi
  printf '  %s?%s %s%s%s %s(↑/↓ then Enter)%s\n' "$C_ACCENT" "$C_RESET" "$C_BOLD" "$label" "$C_RESET" "$C_GRAY" "$C_RESET"
  tput civis 2>/dev/null || true
  local key drawn=false
  while true; do
    if [[ "$drawn" == true ]]; then printf '\033[%dA' "$n"; fi
    for ((i=0;i<n;i++)); do
      printf '\r\033[K'
      if (( i == sel )); then
        printf '   %s%s %s%s%s  %s%s%s\n' "$C_ACCENT" "$G_POINTER" "$C_BOLD" "${labels[i]}" "$C_RESET" "$C_GRAY" "${descs[i]}" "$C_RESET"
      else
        printf '     %s  %s%s%s\n' "${labels[i]}" "$C_DIM" "${descs[i]}" "$C_RESET"
      fi
    done
    drawn=true
    IFS= read -rsn1 key </dev/tty || key=""
    if [[ "$key" == $'\x1b' ]]; then
      IFS= read -rsn2 -t 0.05 key </dev/tty || key=""
      case "$key" in
        '[A') sel=$(( (sel - 1 + n) % n )) ;;
        '[B') sel=$(( (sel + 1) % n )) ;;
      esac
    else
      case "$key" in
        k) sel=$(( (sel - 1 + n) % n )) ;;
        j) sel=$(( (sel + 1) % n )) ;;
        [1-9]) (( key <= n )) && sel=$((key - 1)) ;;
        ""|$'\n'|$'\r') break ;;
      esac
    fi
  done
  tput cnorm 2>/dev/null || true
  REPLY="${values[sel]}"
  printf '   %s%s %s%s\n' "$C_GREEN" "$G_OK" "${labels[sel]}" "$C_RESET"
}

# ui_pause "message" : wait for Enter (no-op non-interactive)
ui_pause() {
  [[ "$NONINTERACTIVE" == true ]] && return 0
  printf '  %s%s%s ' "$C_GRAY" "${1:-Press Enter to continue}" "$C_RESET"
  IFS= read -r _ </dev/tty || true
}

# ui_confirm_or_exit "question"
ui_confirm_or_exit() {
  if [[ "$ASSUME_YES" == true || "$NONINTERACTIVE" == true ]]; then return 0; fi
  ask_yn "$1" true || { ui_info "Aborted. Nothing was changed."; exit 0; }
}
