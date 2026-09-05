#!/usr/bin/env bash
# fm-carverauto-lib.sh - shared helpers for this fork's Carverauto overlay.
#
# Sourced by bin/fm-carverauto-notify.sh, bin/fm-carverauto-inbox.sh,
# bin/fm-carverauto-portal.sh, and bin/fm-send.sh. No side effects on source.
# Discord tokens, NATS credentials, and GITHUB_TOKEN never belong in git or in
# this library's output; they stay in the operator's environment or gitignored
# files owned by firstmate-notify / the NATS CLI.
#
# Opt-in is gitignored config/carverauto-overlay containing "on", or
# FM_CARVERAUTO_OVERLAY set to 1/on/true. Absent means the overlay is inert:
# fm-send keeps the on-disk steering inbox and does not dual-write.
# docs/configuration.md "Carverauto overlay" owns operator setup.
# This file is sourced, never executed.

_FM_CARVERAUTO_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_FM_CARVERAUTO_ROOT="$(cd "$_FM_CARVERAUTO_LIB_DIR/.." && pwd)"

FM_CARVERAUTO_PORTAL_DEFAULT='https://firstmate.carverauto.dev'
FM_CARVERAUTO_NOTIFY_PY_DEFAULT="$HOME/src/firstmate-notify/notify.py"
# The portal assignment is its own message family, never the steer contract:
# subject firstmate.assign.<task>, schema below. bin/fm-carverauto-portal.sh
# is its only publisher; bin/fm-carverauto-inbox.sh publishes steers only.
# shellcheck disable=SC2034 # Read by the sourcing publisher.
FM_CARVERAUTO_PORTAL_SCHEMA='fm-carverauto-portal-assign.v1'

fm_carverauto_home() {
  printf '%s' "${FM_HOME:-$_FM_CARVERAUTO_ROOT}"
}

fm_carverauto_config_dir() {
  printf '%s' "${FM_CONFIG_OVERRIDE:-$(fm_carverauto_home)/config}"
}

# Read one gitignored config leaf. Env wins when the matching override is set
# by the caller; this helper only reads the file. Prints nothing when absent.
fm_carverauto_config_read() {  # <leaf>
  local file val
  file="$(fm_carverauto_config_dir)/$1"
  [ -f "$file" ] || return 0
  val=$(tr -d '\r' <"$file")
  val=${val#"${val%%[![:space:]]*}"}
  val=${val%"${val##*[![:space:]]}"}
  printf '%s' "$val"
}

fm_carverauto_truthy() {  # <value>
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    1|on|true|yes) return 0 ;;
    *) return 1 ;;
  esac
}

fm_carverauto_overlay_enabled() {
  if [ -n "${FM_CARVERAUTO_OVERLAY+x}" ]; then
    fm_carverauto_truthy "${FM_CARVERAUTO_OVERLAY:-}"
    return $?
  fi
  fm_carverauto_truthy "$(fm_carverauto_config_read carverauto-overlay)"
}

fm_carverauto_notify_py() {
  if [ -n "${FM_CARVERAUTO_NOTIFY_PY:-}" ]; then
    printf '%s' "$FM_CARVERAUTO_NOTIFY_PY"
    return 0
  fi
  local configured
  configured=$(fm_carverauto_config_read carverauto-notify-py)
  if [ -n "$configured" ]; then
    printf '%s' "$configured"
    return 0
  fi
  printf '%s' "$FM_CARVERAUTO_NOTIFY_PY_DEFAULT"
}

fm_carverauto_portal_url() {
  if [ -n "${FM_CARVERAUTO_PORTAL_URL:-}" ]; then
    printf '%s' "$FM_CARVERAUTO_PORTAL_URL"
    return 0
  fi
  local configured
  configured=$(fm_carverauto_config_read carverauto-portal-url)
  if [ -n "$configured" ]; then
    printf '%s' "$configured"
    return 0
  fi
  printf '%s' "$FM_CARVERAUTO_PORTAL_DEFAULT"
}

fm_carverauto_nats_url() {
  if [ -n "${FM_CARVERAUTO_NATS_URL:-}" ]; then
    printf '%s' "$FM_CARVERAUTO_NATS_URL"
    return 0
  fi
  if [ -n "${NATS_URL:-}" ]; then
    printf '%s' "$NATS_URL"
    return 0
  fi
  fm_carverauto_config_read carverauto-nats-url
}

fm_carverauto_inbox_stream() {
  if [ -n "${FM_CARVERAUTO_INBOX_STREAM:-}" ]; then
    printf '%s' "$FM_CARVERAUTO_INBOX_STREAM"
    return 0
  fi
  fm_carverauto_config_read carverauto-inbox-stream
}

# ONE owner of the nats CLI invocation. Only the configured server URL rides
# argv; credentials stay in the CLI's own environment (NATS_USER,
# NATS_PASSWORD, NATS_CREDS) so they never reach a process listing or a log.
fm_carverauto_nats_run() {  # <nats-args...>
  local url
  if ! command -v nats >/dev/null 2>&1; then
    echo "error: nats CLI not found on PATH; install nats or turn the Carverauto overlay off" >&2
    return 127
  fi
  url=$(fm_carverauto_nats_url)
  if [ -n "$url" ]; then
    nats --server "$url" "$@"
  else
    nats "$@"
  fi
}

fm_carverauto_now() {
  date -u +'%Y-%m-%dT%H:%M:%SZ'
}

# Stream, consumer, and task ids all become NATS subject or API tokens. Refuse
# anything that is not a plain token so a caller cannot widen a subject or
# reach outside the stream it named.
fm_carverauto_valid_token() {  # <name>
  case "$1" in
    ''|*[!A-Za-z0-9._-]*|.*|*.|-*|*-) return 1 ;;
    *) return 0 ;;
  esac
}

fm_carverauto_require_https() {  # <url> <flag>
  case "$1" in
    https://*[![:space:]]*)
      case "$1" in
        *[[:space:]]*) return 1 ;;
        *) return 0 ;;
      esac
      ;;
    *) return 1 ;;
  esac
}

# Additive dual-write used by fm-send after a successful on-disk enqueue.
# Reads the body from the disk record so the JetStream copy cannot diverge.
# Never unlinks, moves, or truncates the on-disk inbox record.
# Returns 0 on a landed put, 1 when overlay is off or a put fails; the caller
# must not treat a failure as an undelivered steer.
fm_carverauto_inbox_dual_write() {  # <task-id> <disk-record>
  local task_id=$1 record=$2 stream body rc=0
  fm_carverauto_overlay_enabled || return 1
  stream=$(fm_carverauto_inbox_stream)
  if [ -z "$stream" ]; then
    echo "notice: Carverauto overlay is on but no inbox stream is configured (set --stream later via FM_CARVERAUTO_INBOX_STREAM or config/carverauto-inbox-stream); on-disk inbox remains at $record" >&2
    return 1
  fi
  if [ ! -f "$record" ]; then
    echo "notice: Carverauto dual-write skipped; on-disk inbox record is missing at $record" >&2
    return 1
  fi
  if ! command -v fm_task_inbox_body >/dev/null 2>&1; then
    echo "notice: Carverauto dual-write skipped; on-disk inbox body helper is unavailable; on-disk inbox remains at $record" >&2
    return 1
  fi
  body=$(fm_task_inbox_body "$record") || return 1
  seq=$(basename "$record" .msg)
  seq=$((10#$seq))
  extra=()
  if grep -q '^delivery=fire-and-forget$' "$record" 2>/dev/null; then
    extra+=(--delivery fire-and-forget)
  fi
  printf '%s' "$body" | "$_FM_CARVERAUTO_LIB_DIR/fm-steer.sh" put \
    --stream "$stream" \
    --task "$task_id" \
    --seq "$seq" \
    "${extra[@]+"${extra[@]}"}" \
    >&2 \
    || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "notice: Carverauto JetStream dual-write did not land; on-disk inbox remains at $record" >&2
    return 1
  fi
  return 0
}
