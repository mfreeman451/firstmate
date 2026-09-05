#!/usr/bin/env bash
# fm-steer - this fork's JetStream steering inbox for Carverauto, under the
# command name firstmate-notify's portal change owns.
#
# Usage:
#   fm-steer.sh put  --stream <name> --task <id> --seq <n> [--body <text>] [--delivery fire-and-forget]
#   fm-steer.sh next --stream <name>
#   fm-steer.sh ack  --stream <name> --stream-seq <n>
#   fm-steer.sh list --stream <name>
#
# --stream is required on every command and names the durable consumer too.
# Body for put is --body or stdin.
#
# Contract (OpenSpec add-firstmate-portal in firstmate-notify):
#   put/next/ack/list, required --stream, subject firstmate.steer.<task>,
#   ack = handled, list = pending, payload schema=fm-task-inbox.v1 with
#   at, task, seq, body, and optional fire-and-forget.
# The subject and the schema are pinned: this CLI publishes that family and
# nothing else. A portal assignment is a different family with its own
# publisher (bin/fm-carverauto-portal.sh), not an override here.
#
# JetStream is the only store. put is a JetStream publish, so its acknowledgement
# proves a stream actually stored the steer; a subject no stream captures fails
# the put instead of reporting a delivery that never happened. The body is
# published unchanged, which needs natscli 0.4.0 or newer: older ones expand Go
# templates such as {{Count}} in the body, so bin/fm-carverauto-lib.sh refuses
# to publish through them rather than send a steer that differs from the
# on-disk record.
#
# next, ack, and list address a durable PULL consumer named after the stream,
# with AckPolicy=explicit. The overlay never creates it: `nats consumer add`
# is the operator's step, and docs/configuration.md names it.
#
# next peeks the head of the durable consumer: the steer is delivered and
# negative-acknowledged, so it stays pending and stays first in line, and next
# reports the JetStream sequence that identifies it. ack takes that same
# --stream-seq and refuses unless it is still the steer the consumer last
# delivered, so a repeated or unpaired ack can never handle a steer nobody
# read; acknowledging one that is already below the ack floor is reported as
# already handled. list reports everything the consumer has not acknowledged.
# The overlay keeps no message store of its own.
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
TASK_ID=
SEQ_ARG=
STREAM_SEQ=
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
    --stream-seq)
      [ -n "${2-}" ] || die "--stream-seq needs a number"
      STREAM_SEQ=$2
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

put_body() {
  if [ -n "$BODY_ARG" ]; then
    printf '%s' "$BODY_ARG"
    return 0
  fi
  [ ! -t 0 ] || die "put requires --body or stdin"
  cat
}

# The durable consumer's state as four numbers:
#   <undelivered> <delivered-unacked> <last-delivered-seq> <ack-floor-seq>
consumer_state() {
  local info
  command -v python3 >/dev/null 2>&1 \
    || fail "python3 is required to read the durable consumer state"
  info=$(fm_carverauto_nats_run consumer info "$STREAM" "$STREAM" --json) \
    || fail "nats consumer info failed for consumer $STREAM on stream $STREAM"
  printf '%s' "$info" | python3 -c 'import json, sys
d = json.load(sys.stdin)
print(int(d.get("num_pending", 0)),
      int(d.get("num_ack_pending", 0)),
      int(d.get("delivered", {}).get("stream_seq", 0)),
      int(d.get("ack_floor", {}).get("stream_seq", 0)))' \
    || fail "nats consumer info did not describe consumer $STREAM on stream $STREAM"
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
  fm_carverauto_nats_publish "firstmate.steer.${TASK_ID}" "$payload" >&2 \
    || fail "nats publish to firstmate.steer.${TASK_ID} failed"
  printf 'put: stream=%s subject=firstmate.steer.%s seq=%s\n' "$STREAM" "$TASK_ID" "$SEQ_ARG"
}

cmd_next() {
  local body state delivered
  body=$(fm_carverauto_nats_run consumer next "$STREAM" "$STREAM" --count 1 --no-ack --nak --raw) \
    || fail "no pending steer on stream $STREAM"
  state=$(consumer_state)
  read -r _ _ delivered _ <<<"$state"
  printf 'next: stream=%s stream-seq=%s\n' "$STREAM" "$delivered"
  printf -- '--\n'
  printf '%s\n' "$body"
}

cmd_ack() {
  local state delivered floor
  [ -n "$STREAM_SEQ" ] || die "ack requires --stream-seq (the sequence next reported)"
  case "$STREAM_SEQ" in
    *[!0-9]*) die "--stream-seq must be a number" ;;
  esac
  state=$(consumer_state)
  read -r _ _ delivered floor <<<"$state"
  if [ "$STREAM_SEQ" -le "$floor" ]; then
    printf 'ack: stream=%s stream-seq=%s already handled\n' "$STREAM" "$STREAM_SEQ"
    return 0
  fi
  [ "$STREAM_SEQ" -eq "$delivered" ] \
    || fail "stream-seq $STREAM_SEQ is not the steer consumer $STREAM last delivered ($delivered); run next first"
  fm_carverauto_nats_run consumer next "$STREAM" "$STREAM" --count 1 --ack --raw >&2 \
    || fail "nats could not acknowledge stream-seq $STREAM_SEQ on stream $STREAM"
  printf 'ack: stream=%s stream-seq=%s handled\n' "$STREAM" "$STREAM_SEQ"
}

# Pending is everything the durable consumer has not acknowledged - both what
# it has never delivered and what it has delivered without an ack - never the
# stream's retained history.
cmd_list() {
  local state pending ackpending
  state=$(consumer_state)
  read -r pending ackpending _ _ <<<"$state"
  printf 'stream=%s pending=%s\n' "$STREAM" "$((pending + ackpending))"
}

case "$CMD" in
  put) cmd_put ;;
  next) cmd_next ;;
  ack) cmd_ack ;;
  list) cmd_list ;;
esac
