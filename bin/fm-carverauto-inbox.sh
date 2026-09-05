#!/usr/bin/env bash
# This fork's fm-steer CLI: JetStream steering inbox for Carverauto.
#
# Usage:
#   fm-carverauto-inbox.sh put  --stream <name> --task <id> --seq <n> [--body <text>] [--delivery fire-and-forget]
#   fm-carverauto-inbox.sh next --stream <name> [--consumer <name>]
#   fm-carverauto-inbox.sh ack  --stream <name> [--consumer <name>]
#   fm-carverauto-inbox.sh list --stream <name> [--consumer <name>]
#
# --stream is required on every command; the durable consumer defaults to the
# stream name. Body for put is --body or stdin.
# bin/fm-steer.sh is the same CLI under the OpenSpec command name.
#
# Contract (OpenSpec add-firstmate-portal in firstmate-notify):
#   put/next/ack/list, required --stream, subject firstmate.steer.<task>,
#   ack = handled, list = pending, payload schema=fm-task-inbox.v1 with
#   at, task, seq, body, and optional fire-and-forget.
# The subject and the schema are pinned: this CLI publishes that family and
# nothing else. A portal assignment is a different family with its own
# publisher (bin/fm-carverauto-portal.sh), not an override here.
#
# JetStream is the only store. put publishes the envelope; next peeks the head
# of the durable consumer and negative-acknowledges it, so the message stays
# pending until ack acknowledges it; list reports the consumer's unacked
# count. The overlay keeps no message store of its own.
#
# This is the contract fm-send dual-writes to. It never deletes, moves, or
# truncates a task's on-disk steering inbox (state/<id>.inbox/), which remains
# the delivery record; this CLI has no path that removes it.
#
# bin/fm-carverauto-lib.sh owns overlay opt-in and the nats invocation, so
# credentials stay in the nats CLI environment and never reach argv. The
# carverauto-overlay skill owns when firstmate should dual-write. Do not
# silently skip the on-disk inbox from fm-send: dual-write is additive only.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-carverauto-lib.sh
. "$SCRIPT_DIR/fm-carverauto-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 2; }
fail() { printf 'error: %s\n' "$1" >&2; exit 1; }

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
  exit 2
}

SCHEMA=fm-task-inbox.v1
CMD=
STREAM=
CONSUMER=
TASK_ID=
SEQ_ARG=
DELIVERY=
BODY_ARG=

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help|help) usage ;;
    put|next|ack|list)
      [ -z "$CMD" ] || die "multiple commands"
      CMD=$1
      shift
      ;;
    --stream)
      [ -n "${2-}" ] || die "--stream needs a name"
      STREAM=$2
      shift 2
      ;;
    --consumer)
      [ -n "${2-}" ] || die "--consumer needs a name"
      CONSUMER=$2
      shift 2
      ;;
    --task)
      [ -n "${2-}" ] || die "--task needs an id"
      TASK_ID=$2
      shift 2
      ;;
    --seq)
      [ -n "${2-}" ] || die "--seq needs a number"
      SEQ_ARG=$2
      shift 2
      ;;
    --delivery)
      [ -n "${2-}" ] || die "--delivery needs a value"
      [ "$2" = fire-and-forget ] || die "--delivery must be fire-and-forget"
      DELIVERY=$2
      shift 2
      ;;
    --body)
      [ -n "${2-}" ] || die "--body needs a value"
      BODY_ARG=$2
      shift 2
      ;;
    --) shift; break ;;
    -*) die "unknown option: $1" ;;
    *) die "unexpected argument: $1" ;;
  esac
done

[ -n "$CMD" ] || die "command required: put, next, ack, or list"
[ -n "$STREAM" ] || die "--stream is required"
fm_carverauto_valid_token "$STREAM" || die "invalid --stream (use a NATS-safe token, no path separators)"
CONSUMER=${CONSUMER:-$STREAM}
fm_carverauto_valid_token "$CONSUMER" || die "invalid --consumer (use a NATS-safe token, no path separators)"

put_body() {
  if [ -n "$BODY_ARG" ]; then
    printf '%s' "$BODY_ARG"
    return 0
  fi
  [ ! -t 0 ] || die "put requires --body or stdin"
  cat
}

cmd_put() {
  local body payload
  [ -n "$TASK_ID" ] || die "put requires --task (the subject is firstmate.steer.<task>)"
  fm_carverauto_valid_token "$TASK_ID" || die "invalid --task (use a NATS-safe token, no path separators)"
  [ -n "$SEQ_ARG" ] || die "put requires --seq (the fm-task-inbox.v1 record sequence)"
  case "$SEQ_ARG" in
    *[!0-9]*) die "--seq must be a number" ;;
  esac
  body=$(put_body)
  payload="schema=$SCHEMA"$'\n'"at=$(fm_carverauto_now)"$'\n'"task=$TASK_ID"$'\n'"seq=$SEQ_ARG"$'\n'
  if [ "$DELIVERY" = fire-and-forget ]; then
    payload="${payload}delivery=fire-and-forget"$'\n'
  fi
  payload="${payload}--"$'\n'"$body"
  fm_carverauto_nats_run publish "firstmate.steer.${TASK_ID}" -- "$payload" >&2 \
    || fail "nats publish to firstmate.steer.${TASK_ID} failed"
  printf 'put: stream=%s subject=firstmate.steer.%s seq=%s\n' "$STREAM" "$TASK_ID" "$SEQ_ARG"
}

# A peek: the message is negative-acknowledged so it stays pending for ack.
cmd_next() {
  fm_carverauto_nats_run consumer next "$STREAM" "$CONSUMER" --count 1 --no-ack --nak --raw \
    || fail "no pending message on stream $STREAM (consumer $CONSUMER)"
}

# The acknowledgement IS handled: the durable consumer stops offering it.
cmd_ack() {
  fm_carverauto_nats_run consumer next "$STREAM" "$CONSUMER" --count 1 --ack --raw \
    || fail "no pending message to acknowledge on stream $STREAM (consumer $CONSUMER)"
}

# Pending is the durable consumer's unacked count, never the stream's retained
# history: an acknowledged steer is handled even while the stream still holds it.
cmd_list() {
  local info pending
  info=$(fm_carverauto_nats_run consumer info "$STREAM" "$CONSUMER" --json) \
    || fail "nats consumer info failed for consumer $CONSUMER on stream $STREAM"
  pending=$(printf '%s\n' "$info" | awk '
    !found && match($0, /"num_pending"[ \t]*:[ \t]*[0-9]+/) {
      n = substr($0, RSTART, RLENGTH)
      sub(/^[^0-9]*/, "", n)
      print n
      found = 1
    }
  ')
  [ -n "$pending" ] || fail "nats consumer info did not report num_pending for consumer $CONSUMER on stream $STREAM"
  printf 'stream=%s consumer=%s pending=%s\n' "$STREAM" "$CONSUMER" "$pending"
}

case "$CMD" in
  put) cmd_put ;;
  next) cmd_next ;;
  ack) cmd_ack ;;
  list) cmd_list ;;
esac
