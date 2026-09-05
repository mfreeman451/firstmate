#!/usr/bin/env bash
# This fork's fm-steer CLI: JetStream steering inbox for Carverauto.
#
# Usage:
#   fm-carverauto-inbox.sh put  --stream <name> [--subject <subject>] [--task <id>] [--seq <n>] [--delivery fire-and-forget]
#   fm-carverauto-inbox.sh next --stream <name> [--consumer <name>]
#   fm-carverauto-inbox.sh ack  --stream <name> --ack <ack-id>
#   fm-carverauto-inbox.sh list --stream <name>
#
# --stream is required on every command. Body for put is stdin.
# bin/fm-steer.sh is the same CLI under the OpenSpec command name.
#
# Contract (OpenSpec add-firstmate-portal in firstmate-notify):
#   put/next/ack/list, required --stream, subject firstmate.steer.<task>,
#   ack = handled, list = pending, payload schema=fm-task-inbox.v1 with
#   at, task, seq, body, and optional fire-and-forget.
#
# This is the contract fm-send dual-writes to. It never deletes, moves, or
# truncates a task's on-disk steering inbox (state/<id>.inbox/). Keep that
# disk inbox until dual-write is the only path; this CLI has no path that
# removes it.
#
# Backends:
#   file  default when no NATS URL is configured. Store under
#         state/carverauto-inbox/<stream>/ (override with FM_CARVERAUTO_INBOX_DIR).
#   nats  when FM_CARVERAUTO_INBOX_BACKEND=nats or a NATS URL is configured.
#         Uses the nats CLI. Credentials stay in NATS_URL / NATS_USER /
#         NATS_PASSWORD / NATS_CREDS, never in git.
#
# bin/fm-carverauto-lib.sh owns overlay opt-in. The carverauto-overlay skill
# owns when firstmate should dual-write. Do not silently skip the on-disk
# inbox from fm-send: dual-write is additive only.
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

CMD=
STREAM=
SUBJECT=
CONSUMER=
ACK_ID=
MSG_ID=
SCHEMA=
TASK_ID=
SEQ_ARG=
DELIVERY=

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
    --subject)
      [ -n "${2-}" ] || die "--subject needs a value"
      SUBJECT=$2
      shift 2
      ;;
    --consumer)
      [ -n "${2-}" ] || die "--consumer needs a name"
      CONSUMER=$2
      shift 2
      ;;
    --ack)
      [ -n "${2-}" ] || die "--ack needs an id"
      ACK_ID=$2
      shift 2
      ;;
    --id)
      [ -n "${2-}" ] || die "--id needs a value"
      MSG_ID=$2
      shift 2
      ;;
    --schema)
      [ -n "${2-}" ] || die "--schema needs a value"
      SCHEMA=$2
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
    --) shift; break ;;
    -*) die "unknown option: $1" ;;
    *) die "unexpected argument: $1" ;;
  esac
done

[ -n "$CMD" ] || die "command required: put, next, ack, or list"
[ -n "$STREAM" ] || die "--stream is required"
fm_carverauto_valid_stream "$STREAM" || die "invalid --stream (use a NATS-safe token, no path separators)"

BACKEND=$(fm_carverauto_inbox_backend)
case "$BACKEND" in
  file|nats) ;;
  *) die "unknown inbox backend: $BACKEND (file or nats)" ;;
esac

STORE=$(fm_carverauto_inbox_dir)
if [ -z "$SUBJECT" ]; then
  if [ -n "$TASK_ID" ]; then
    SUBJECT="firstmate.steer.${TASK_ID}"
  else
    SUBJECT=firstmate.steer
  fi
fi
CONSUMER=${CONSUMER:-$STREAM}
SCHEMA=${SCHEMA:-fm-task-inbox.v1}

pad_seq() {
  printf '%04d' "$1"
}

file_stream_dir() {
  printf '%s/%s' "$STORE" "$STREAM"
}

file_lock_acquire() {
  local dir=$1 lock
  mkdir -p "$dir"
  lock="$dir/.lock"
  local i=0
  while ! mkdir "$lock" 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -lt 50 ] || fail "could not lock stream $STREAM"
    sleep 0.05
  done
}

file_lock_release() {
  rmdir "$1/.lock" 2>/dev/null || true
}

file_read_body() {  # <path>
  awk '
    BEGIN { seen=0 }
    seen { print }
    $0 == "--" { seen=1 }
  ' "$1"
}

nats_bin() {
  command -v nats >/dev/null 2>&1 || fail "nats CLI not found on PATH (install nats or use FM_CARVERAUTO_INBOX_BACKEND=file)"
  printf '%s' nats
}

nats_args() {
  local url
  url=$(fm_carverauto_nats_url)
  if [ -n "$url" ]; then
    printf '%s\n' --server "$url"
  fi
}

cmd_put_file() {
  local dir seq_file seq dest body tmp
  body=$(cat)
  dir=$(file_stream_dir)
  file_lock_acquire "$dir"
  seq_file="$dir/seq"
  mkdir -p "$dir/available" "$dir/pending" "$dir/handled"
  seq=0
  if [ -f "$seq_file" ]; then
    seq=$(tr -d '[:space:]' <"$seq_file")
  fi
  case "$seq" in
    ''|*[!0-9]*) seq=0 ;;
  esac
  seq=$((seq + 1))
  printf '%s\n' "$seq" >"$seq_file"
  dest="$dir/available/$(pad_seq "$seq")"
  tmp=$(mktemp "$dir/.put.XXXXXX")
  payload_seq=$seq
  if [ -n "$SEQ_ARG" ]; then
    payload_seq=$SEQ_ARG
  fi
  {
    printf 'schema=%s\n' "$SCHEMA"
    printf 'at=%s\n' "$(fm_carverauto_now)"
    [ -n "$TASK_ID" ] && printf 'task=%s\n' "$TASK_ID"
    printf 'seq=%s\n' "$payload_seq"
    [ "$DELIVERY" = fire-and-forget ] && printf 'delivery=fire-and-forget\n'
    [ -n "$MSG_ID" ] && printf 'id=%s\n' "$MSG_ID"
    printf 'subject=%s\n' "$SUBJECT"
    printf -- '--\n'
    printf '%s' "$body"
  } >"$tmp"
  mv "$tmp" "$dest"
  file_lock_release "$dir"
  printf 'put: stream=%s seq=%s subject=%s\n' "$STREAM" "$seq" "$SUBJECT"
}

cmd_next_file() {
  local dir avail seq ack dest body
  dir=$(file_stream_dir)
  [ -d "$dir/available" ] || fail "no messages on stream $STREAM"
  file_lock_acquire "$dir"
  avail=
  for avail in "$dir/available/"[0-9]*; do
    [ -f "$avail" ] || { avail=; continue; }
    break
  done
  if [ -z "$avail" ]; then
    file_lock_release "$dir"
    fail "no messages on stream $STREAM"
  fi
  seq=$(basename "$avail")
  seq=$((10#$seq))
  ack="a$(pad_seq "$seq")"
  dest="$dir/pending/$ack"
  mv "$avail" "$dest"
  body=$(file_read_body "$dest")
  SUBJECT=$(awk -F= '/^subject=/ { print substr($0,9); exit }' "$dest")
  file_lock_release "$dir"
  printf 'ack=%s\n' "$ack"
  printf 'seq=%s\n' "$seq"
  printf 'subject=%s\n' "$SUBJECT"
  printf -- '--\n'
  printf '%s' "$body"
  printf '\n'
}

cmd_ack_file() {
  local dir src dest
  [ -n "$ACK_ID" ] || die "ack requires --ack"
  dir=$(file_stream_dir)
  file_lock_acquire "$dir"
  src="$dir/pending/$ACK_ID"
  if [ ! -f "$src" ]; then
    file_lock_release "$dir"
    fail "unknown ack id $ACK_ID on stream $STREAM"
  fi
  mkdir -p "$dir/handled"
  dest="$dir/handled/$ACK_ID"
  mv "$src" "$dest"
  file_lock_release "$dir"
  printf 'ack: %s\n' "$ACK_ID"
}

cmd_list_file() {
  local dir f seq subject
  dir=$(file_stream_dir)
  if [ ! -d "$dir" ]; then
    return 0
  fi
  file_lock_acquire "$dir"
  for f in "$dir/available/"[0-9]*; do
    [ -f "$f" ] || continue
    seq=$(basename "$f")
    seq=$((10#$seq))
    subject=$(awk -F= '/^subject=/ { print substr($0,9); exit }' "$f")
    printf 'seq=%s state=pending subject=%s\n' "$seq" "$subject"
  done
  for f in "$dir/pending/"*; do
    [ -f "$f" ] || continue
    seq=$(awk -F= '/^seq=/ { print $2; exit }' "$f")
    subject=$(awk -F= '/^subject=/ { print substr($0,9); exit }' "$f")
    printf 'seq=%s state=pending subject=%s ack=%s\n' "$seq" "$subject" "$(basename "$f")"
  done
  file_lock_release "$dir"
}

cmd_put_nats() {
  local nats bodyfile extra=()
  nats=$(nats_bin)
  bodyfile=$(mktemp "${TMPDIR:-/tmp}/fm-carverauto-put.XXXXXX")
  cat >"$bodyfile"
  extra=()
  while IFS= read -r arg; do
    [ -n "$arg" ] && extra+=("$arg")
  done < <(nats_args)
  "$nats" "${extra[@]}" publish "$SUBJECT" -- "$(cat "$bodyfile")"
  rm -f "$bodyfile"
  printf 'put: stream=%s subject=%s backend=nats\n' "$STREAM" "$SUBJECT"
}

cmd_next_nats() {
  local nats extra=() out ack_subject ack seq
  nats=$(nats_bin)
  extra=()
  while IFS= read -r arg; do
    [ -n "$arg" ] && extra+=("$arg")
  done < <(nats_args)
  out=$("$nats" "${extra[@]}" consumer next "$STREAM" "$CONSUMER" --no-ack --count 1) || fail "nats consumer next failed"
  ack_subject=$(printf '%s\n' "$out" | awk '/\$JS\.ACK\./ { print $NF; exit }')
  if [ -z "$ack_subject" ]; then
    ack_subject=$(printf '%s\n' "$out" | awk 'BEGIN { IGNORECASE=1 } /ack-subject|Nats-Ack-Subject/ { print $NF; exit }')
  fi
  [ -n "$ack_subject" ] || fail "nats consumer next did not expose an ack subject"
  seq=$(printf '%s\n' "$out" | awk 'BEGIN { IGNORECASE=1 } /Nats-Sequence:|sequence:/ { print $NF; exit }')
  seq=${seq:-0}
  ack="n-${seq}-$(printf '%s' "$ack_subject" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-80)"
  mkdir -p "$(file_stream_dir)/pending"
  printf '%s\n' "$ack_subject" >"$(file_stream_dir)/pending/$ack"
  printf 'ack=%s\n' "$ack"
  printf 'seq=%s\n' "$seq"
  printf 'subject=%s\n' "$SUBJECT"
  printf -- '--\n'
  printf '%s\n' "$out"
}

cmd_ack_nats() {
  local nats extra=() subject
  [ -n "$ACK_ID" ] || die "ack requires --ack"
  subject=$(cat "$(file_stream_dir)/pending/$ACK_ID" 2>/dev/null || true)
  [ -n "$subject" ] || fail "unknown ack id $ACK_ID on stream $STREAM"
  nats=$(nats_bin)
  extra=()
  while IFS= read -r arg; do
    [ -n "$arg" ] && extra+=("$arg")
  done < <(nats_args)
  "$nats" "${extra[@]}" publish "$subject" -- ''
  mkdir -p "$(file_stream_dir)/handled"
  mv "$(file_stream_dir)/pending/$ACK_ID" "$(file_stream_dir)/handled/$ACK_ID"
  printf 'ack: %s\n' "$ACK_ID"
}

cmd_list_nats() {
  local nats extra=()
  nats=$(nats_bin)
  extra=()
  while IFS= read -r arg; do
    [ -n "$arg" ] && extra+=("$arg")
  done < <(nats_args)
  "$nats" "${extra[@]}" stream view "$STREAM" --raw
}

case "$BACKEND:$CMD" in
  file:put) cmd_put_file ;;
  file:next) cmd_next_file ;;
  file:ack) cmd_ack_file ;;
  file:list) cmd_list_file ;;
  nats:put) cmd_put_nats ;;
  nats:next) cmd_next_nats ;;
  nats:ack) cmd_ack_nats ;;
  nats:list) cmd_list_nats ;;
  *) die "unsupported $BACKEND $CMD" ;;
esac
