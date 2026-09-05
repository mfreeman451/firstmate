#!/usr/bin/env bash
# fm-carverauto-lib.sh - shared helpers for this fork's Carverauto overlay.
#
# Sourced by bin/fm-carverauto-notify.sh, bin/fm-steer.sh,
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
# shellcheck source=bin/fm-timeout-lib.sh
. "$_FM_CARVERAUTO_LIB_DIR/fm-timeout-lib.sh"

# A dual-write must never hold a steer's doorbell open: a NATS host that
# blackholes rather than refuses would otherwise cost natscli's connect and
# response budget on every send.
FM_CARVERAUTO_DUAL_WRITE_BUDGET_SECS=${FM_CARVERAUTO_DUAL_WRITE_BUDGET_SECS:-10}

FM_CARVERAUTO_PORTAL_DEFAULT='https://firstmate.carverauto.dev'
FM_CARVERAUTO_NOTIFY_PY_DEFAULT="$HOME/src/firstmate-notify/notify.py"
# The portal assignment is its own message family, never the steer contract:
# subject firstmate.assign.<task>, schema below. bin/fm-carverauto-portal.sh
# is its only publisher; bin/fm-steer.sh publishes steers only.
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

# The overlay's own server override only. NATS_URL is natscli's own environment
# variable and already outranks its selected context, so this never copies it:
# leaving it in the environment keeps a URL that carries userinfo off argv.
fm_carverauto_nats_url() {
  if [ -n "${FM_CARVERAUTO_NATS_URL:-}" ]; then
    printf '%s' "$FM_CARVERAUTO_NATS_URL"
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
# argv, and a URL carrying userinfo is refused outright, so credentials stay in
# the CLI's own environment (NATS_USER, NATS_PASSWORD, NATS_CREDS) and never
# reach a process listing or a log.
fm_carverauto_nats_run() {  # <nats-args...>
  local url
  if ! command -v nats >/dev/null 2>&1; then
    echo "error: nats CLI not found on PATH; install nats or turn the Carverauto overlay off" >&2
    return 127
  fi
  url=$(fm_carverauto_nats_url)
  case "$url" in
    *@*)
      echo "error: the Carverauto NATS URL must not embed credentials; drop the userinfo from the URL and put the secret in NATS_USER, NATS_PASSWORD, or NATS_CREDS so it never reaches argv" >&2
      return 2
      ;;
  esac
  if [ -n "$url" ]; then
    nats --server "$url" "$@"
  else
    nats "$@"
  fi
}

# ONE owner of publishing a payload, and it always publishes to JetStream (-J):
# a core publish is dropped without error when no subscriber is listening, so
# only the JetStream acknowledgement proves a stream stored the message.
# natscli also expands Go templates ({{Count}}, {{ID}}, {{Time}}, ...) in a
# publish body unless --templates=false is passed, and that flag exists only
# from natscli 0.4.0. A CLI without it cannot carry a body byte for byte, so the
# overlay refuses up front instead of publishing something other than what the
# caller handed it.
fm_carverauto_nats_publish() {  # <subject> <payload>
  local help
  help=$(fm_carverauto_nats_run publish --help) || return 1
  case "$help" in
    *'--[no-]templates'*) ;;
    *)
      echo "error: this nats CLI expands Go templates in a published body and cannot be told not to; the Carverauto overlay needs natscli 0.4.0 or newer, which accepts --templates=false" >&2
      return 1
      ;;
  esac
  fm_carverauto_nats_run publish -J --templates=false "$1" -- "$2"
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

# Additive dual-write used by fm-send after a successful on-disk enqueue and
# after the doorbell has rung. Reads the body from the disk record so the
# JetStream copy cannot diverge, and is bounded so a sick broker cannot hold
# the send open. Never unlinks, moves, or truncates the on-disk inbox record.
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
  fm_run_timed "$FM_CARVERAUTO_DUAL_WRITE_BUDGET_SECS" \
    "$_FM_CARVERAUTO_LIB_DIR/fm-steer.sh" put \
    --stream "$stream" \
    --task "$task_id" \
    --seq "$seq" \
    --body "$body" \
    "${extra[@]+"${extra[@]}"}" \
    >&2 \
    || rc=$?
  if [ "$rc" = 124 ]; then
    echo "notice: Carverauto JetStream dual-write hit its ${FM_CARVERAUTO_DUAL_WRITE_BUDGET_SECS}s bound; on-disk inbox remains at $record" >&2
    return 1
  fi
  if [ "$rc" -ne 0 ]; then
    echo "notice: Carverauto JetStream dual-write did not land; on-disk inbox remains at $record" >&2
    return 1
  fi
  return 0
}
