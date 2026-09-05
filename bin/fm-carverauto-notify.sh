#!/usr/bin/env bash
# Page Discord for captain-attention messages on this Carverauto fork.
#
# Usage:
#   fm-carverauto-notify.sh captain-needed --title <text> [--body <text>] [--file <path>]...
#   fm-carverauto-notify.sh pr-landed --url <https-url> --outcome <text>
#   fm-carverauto-notify.sh archify --title <text> (--png <path> | --html <path>) [--notes <text>]
#
# Wraps python3 notify.py from firstmate-notify. The Discord webhook token is
# never read, printed, or stored by this script: notify.py loads
# DISCORD_WEBHOOK_URL from the environment or its own gitignored .env.
# Every captain-needed page includes the fleet portal URL
# (https://firstmate.carverauto.dev by default) so Discord gets a live link
# rather than an HTML attachment.
#
# Resolve notify.py from FM_CARVERAUTO_NOTIFY_PY, then
# config/carverauto-notify-py, then ~/src/firstmate-notify/notify.py.
# bin/fm-carverauto-lib.sh owns overlay opt-in and portal URL resolution.
# The carverauto-overlay skill owns when firstmate must call this.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-carverauto-lib.sh
. "$SCRIPT_DIR/fm-carverauto-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 2; }

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
  exit 2
}

NOTIFY_PY=$(fm_carverauto_notify_py)
PORTAL=$(fm_carverauto_portal_url)
CMD=
TITLE=
BODY=
URL=
OUTCOME=
HTML=
PNG=
NOTES=
FILES=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help|help) usage ;;
    captain-needed|pr-landed|archify)
      [ -z "$CMD" ] || die "multiple commands"
      CMD=$1
      shift
      ;;
    --title)
      [ -n "${2-}" ] || die "--title needs a value"
      TITLE=$2
      shift 2
      ;;
    --body)
      [ -n "${2-}" ] || die "--body needs a value"
      BODY=$2
      shift 2
      ;;
    --file)
      [ -n "${2-}" ] || die "--file needs a path"
      FILES+=("$2")
      shift 2
      ;;
    --url)
      [ -n "${2-}" ] || die "--url needs a value"
      URL=$2
      shift 2
      ;;
    --outcome)
      [ -n "${2-}" ] || die "--outcome needs a value"
      OUTCOME=$2
      shift 2
      ;;
    --html)
      [ -n "${2-}" ] || die "--html needs a path"
      HTML=$2
      shift 2
      ;;
    --png)
      [ -n "${2-}" ] || die "--png needs a path"
      PNG=$2
      shift 2
      ;;
    --notes)
      [ -n "${2-}" ] || die "--notes needs a value"
      NOTES=$2
      shift 2
      ;;
    --) shift; break ;;
    -*) die "unknown option: $1" ;;
    *) die "unexpected argument: $1" ;;
  esac
done

[ -n "$CMD" ] || die "command required: captain-needed, pr-landed, or archify"
[ -f "$NOTIFY_PY" ] || die "notify.py not found at $NOTIFY_PY (set FM_CARVERAUTO_NOTIFY_PY or config/carverauto-notify-py)"
command -v python3 >/dev/null 2>&1 || die "python3 is required to run notify.py"

append_portal() {
  local text=$1
  case "$text" in
    *"$PORTAL"*) printf '%s' "$text" ;;
    '') printf 'Portal: %s' "$PORTAL" ;;
    *) printf '%s\nPortal: %s' "$text" "$PORTAL" ;;
  esac
}

run_notify() {
  # Never pass a webhook on argv. Leave DISCORD_WEBHOOK_URL to notify.py.
  python3 "$NOTIFY_PY" "$@"
}

case "$CMD" in
  captain-needed)
    [ -n "$TITLE" ] || die "captain-needed requires --title"
    BODY=$(append_portal "$BODY")
    args=(captain-needed --title "$TITLE" --body "$BODY")
    for f in "${FILES[@]+"${FILES[@]}"}"; do
      args+=(--file "$f")
    done
    run_notify "${args[@]}"
    ;;
  pr-landed)
    [ -n "$URL" ] || die "pr-landed requires --url"
    [ -n "$OUTCOME" ] || die "pr-landed requires --outcome"
    fm_carverauto_require_https "$URL" || die "--url must be a full https URL"
    OUTCOME=$(append_portal "$OUTCOME")
    run_notify pr-landed --url "$URL" --outcome "$OUTCOME"
    ;;
  archify)
    [ -n "$TITLE" ] || die "archify requires --title"
    # A diagram page carries the diagram. A text-only page is captain-needed,
    # under that name, so the caller always knows which page Discord gets.
    [ -n "$HTML" ] || [ -n "$PNG" ] \
      || die "archify requires --png or --html (use captain-needed for a text page)"
    NOTES=$(append_portal "$NOTES")
    args=(archify --title "$TITLE" --notes "$NOTES")
    # Discord does not render HTML; the portal URL is the live diagram.
    # Pass --html only when the caller explicitly asked for the file.
    if [ -n "$HTML" ]; then
      args+=(--html "$HTML")
    fi
    if [ -n "$PNG" ]; then
      args+=(--png "$PNG")
    fi
    run_notify "${args[@]}"
    ;;
esac
