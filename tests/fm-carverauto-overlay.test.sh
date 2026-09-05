#!/usr/bin/env bash
# tests/fm-carverauto-overlay.test.sh - Carverauto fork overlay CLIs.
#
# Drives the public notify, steer, and portal executables plus fm-send's
# additive dual-write. JetStream is the steer inbox's only store, so a fake
# nats broker stands in for the server: it stores published messages, models
# the one durable consumer (delivery, negative acknowledgement, ack floor) and
# models natscli's Go-template expansion of a publish body, which is what the
# CLI must switch off. Discord tokens never appear on argv or in wrapper output.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NOTIFY="$ROOT/bin/fm-carverauto-notify.sh"
STEER="$ROOT/bin/fm-steer.sh"
PORTAL="$ROOT/bin/fm-carverauto-portal.sh"
SEND="$ROOT/bin/fm-send.sh"

TMP_ROOT=$(fm_test_tmproot fm-carverauto-overlay)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

make_notify_stub() {  # <dir>
  local dir=$1
  mkdir -p "$dir"
  cat >"$dir/notify.py" <<'PY'
#!/usr/bin/env python3
import os, sys
log = os.environ["NOTIFY_LOG"]
with open(log, "a", encoding="utf-8") as f:
    f.write("argv:" + " | ".join(sys.argv[1:]) + "\n")
    hook = os.environ.get("DISCORD_WEBHOOK_URL", "")
    if hook:
        f.write("env-has-webhook\n")
print("sent", sys.argv[1] if len(sys.argv) > 1 else "unknown")
PY
  chmod +x "$dir/notify.py"
}

# A fake NATS server for the subset of the CLI the overlay uses.
#   publish        stores subject+body under $NATS_STORE/msgs, and - like
#                  natscli - expands {{Count}} in the body unless the publisher
#                  passed --templates=false
#   consumer next  serves the head of the one durable consumer: --nak leaves it
#                  pending and first in line, --ack advances the ack floor
#   consumer info  reports that consumer's delivered/ack_floor sequences and
#                  its undelivered and delivered-unacked counts
make_nats_stub() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat >"$fb/nats" <<'SH'
#!/usr/bin/env bash
set -u
store=${NATS_STORE:?NATS_STORE is required}
mkdir -p "$store/msgs"
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    -s|--server)
      printf 'server=%s\n' "${2:-}" >>"$store/argv.log"
      shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
printf 'argv=%s\n' "$(printf '%s ' "${args[@]+"${args[@]}"}")" >>"$store/argv.log"
stored() { ls -1 "$store/msgs"/*.body 2>/dev/null | wc -l | tr -d ' '; }
state_get() { cat "$store/$1" 2>/dev/null || printf '0'; }
case "${args[0]:-}" in
  publish)
    templates=1
    rest=()
    for a in "${args[@]:1}"; do
      case "$a" in
        --templates=false) templates=0 ;;
        --) ;;
        *) rest+=("$a") ;;
      esac
    done
    body=${rest[1]:-}
    if [ "$templates" = 1 ]; then
      body=${body//\{\{Count\}\}/1}
    fi
    n=$(( $(stored) + 1 ))
    printf '%s' "${rest[0]}" >"$store/msgs/$(printf '%04d' "$n").subject"
    printf '%s' "$body" >"$store/msgs/$(printf '%04d' "$n").body"
    exit 0 ;;
  consumer)
    case "${args[1]:-}" in
      next)
        ack=0
        nak=0
        for a in "${args[@]}"; do
          case "$a" in
            --ack) ack=1 ;;
            --nak) nak=1 ;;
          esac
        done
        head=$(state_get nak)
        if [ "$head" = 0 ]; then
          head=$(( $(state_get delivered) + 1 ))
        fi
        [ -f "$store/msgs/$(printf '%04d' "$head").body" ] \
          || { printf 'nats: no message\n' >&2; exit 1; }
        cat "$store/msgs/$(printf '%04d' "$head").body"
        printf '\n'
        printf '%s' "$head" >"$store/delivered"
        if [ "$ack" = 1 ]; then
          printf '%s' "$head" >"$store/floor"
          printf '0' >"$store/nak"
        elif [ "$nak" = 1 ]; then
          printf '%s' "$head" >"$store/nak"
        else
          printf '0' >"$store/nak"
        fi
        exit 0 ;;
      info)
        ackpending=0
        [ "$(state_get nak)" = 0 ] || ackpending=1
        printf '{"stream_name":"%s","name":"%s","delivered":{"consumer_seq":%s,"stream_seq":%s},' \
          "${args[2]:-}" "${args[3]:-}" "$(state_get delivered)" "$(state_get delivered)"
        printf '"ack_floor":{"consumer_seq":%s,"stream_seq":%s},' \
          "$(state_get floor)" "$(state_get floor)"
        printf '"num_ack_pending":%s,"num_redelivered":0,"num_waiting":0,"num_pending":%s}\n' \
          "$ackpending" "$(( $(stored) - $(state_get delivered) ))"
        exit 0 ;;
    esac
    ;;
esac
printf 'nats: unsupported command: %s\n' "${args[*]:-}" >&2
exit 2
SH
  chmod +x "$fb/nats"
}

make_tmux_stubs() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat >"$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s\n' "${1:-}" >> "$FM_SEND_LOG"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat >"$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
}

# steer <dir> <fm-steer args...>: run the CLI against that dir's fake broker.
steer() {
  local dir=$1; shift
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" \
    NATS_STORE="$dir/nats" FM_CARVERAUTO_NATS_URL=nats://127.0.0.1:4222 \
    "$STEER" "$@"
}

portal() {  # <dir> <fm-carverauto-portal args...>
  local dir=$1; shift
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" \
    NATS_STORE="$dir/nats" FM_CARVERAUTO_NATS_URL=nats://127.0.0.1:4222 \
    "$PORTAL" "$@"
}

# The nth published message, "<subject>\n<payload>".
published() {  # <dir> <n>
  local f
  f="$1/nats/msgs/$(printf '%04d' "$2")"
  [ -f "$f.body" ] || return 1
  printf '%s\n' "$(cat "$f.subject")"
  cat "$f.body"
}

published_count() {  # <dir>
  ls -1 "$1/nats/msgs"/*.body 2>/dev/null | wc -l | tr -d ' '
}

# Everything after the first "--" line: the envelope out of a next report, or
# the steer body out of an envelope.
after_separator() {
  awk 'seen { print } $0 == "--" { seen=1 }'
}

# The JetStream sequence a next report names as the steer it delivered.
reported_stream_seq() {
  awk -F'stream-seq=' 'NF > 1 { print $2; exit }'
}

pending_count() {  # <dir> <stream>
  steer "$1" list --stream "$2" | awk -F'pending=' 'NF > 1 { print $2; exit }'
}

setup_overlay_dir() {  # <name> -> echoes a dir with fakebin, home, and store
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state" "$dir/home/config" "$dir/nats/msgs"
  make_nats_stub "$dir"
  printf '%s\n' "$dir"
}

test_stream_required() {
  local dir err rc
  dir=$(setup_overlay_dir stream-required)
  err="$dir/err"
  set +e
  steer "$dir" put >/dev/null 2>"$err"
  rc=$?
  set -e
  expect_code 2 "$rc" "put without --stream must refuse"
  assert_contains "$(cat "$err")" "--stream is required" "put should name the missing stream"
  pass "fm-steer: --stream is required"
}

test_put_publishes_the_full_envelope() {
  local dir out msg
  dir=$(setup_overlay_dir put-envelope)
  out=$(printf 'steer body\nline 2' | steer "$dir" put --stream firstmate --task t1 --seq 3)
  assert_contains "$out" "stream=firstmate" "put should name the stream"
  assert_contains "$out" "subject=firstmate.steer.t1" "put should use firstmate.steer.<task>"
  msg=$(published "$dir" 1) || fail "put published nothing"
  assert_contains "$msg" "firstmate.steer.t1" "the published subject is firstmate.steer.<task>"
  assert_contains "$msg" "schema=fm-task-inbox.v1" "the payload carries the pinned schema"
  assert_contains "$msg" $'\ntask=t1\n' "the payload carries the task"
  assert_contains "$msg" $'\nseq=3\n' "the payload carries the record sequence"
  assert_contains "$msg" 'at=' "the payload carries the enqueue time"
  [ "$(printf '%s\n' "$msg" | after_separator)" = $'steer body\nline 2' ] \
    || fail "the payload body did not survive the publish: $msg"
  assert_contains "$(cat "$dir/nats/argv.log")" "server=nats://127.0.0.1:4222" \
    "the configured NATS URL should reach the nats CLI"
  pass "fm-steer: put publishes the whole fm-task-inbox.v1 envelope"
}

test_put_sends_the_body_bytes_unchanged() {
  local dir body msg
  dir=$(setup_overlay_dir put-bytes)
  body='the log line prints {{Count}} instead of the request time'
  steer "$dir" put --stream firstmate --task t1 --seq 1 --body "$body" >/dev/null
  msg=$(published "$dir" 1) || fail "put published nothing"
  [ "$(printf '%s\n' "$msg" | after_separator)" = "$body" ] \
    || fail "the steer body was rewritten in flight: $msg"
  pass "fm-steer: put publishes the steer body byte for byte"
}

test_put_marks_fire_and_forget() {
  local dir msg
  dir=$(setup_overlay_dir put-fire)
  steer "$dir" put --stream firstmate --task t1 --seq 1 \
    --delivery fire-and-forget --body "one shot" >/dev/null
  msg=$(published "$dir" 1) || fail "put published nothing"
  assert_contains "$msg" $'\ndelivery=fire-and-forget\n' \
    "a fire-and-forget steer is marked on the JetStream copy"
  pass "fm-steer: put carries the optional fire-and-forget marker"
}

test_put_requires_the_contract_fields() {
  local dir err rc
  dir=$(setup_overlay_dir put-required)
  err="$dir/err"
  set +e
  steer "$dir" put --stream firstmate --body x >/dev/null 2>"$err"
  rc=$?
  set -e
  expect_code 2 "$rc" "a put with no task must refuse"
  assert_contains "$(cat "$err")" "--task" "the refusal should name --task"
  set +e
  steer "$dir" put --stream firstmate --task t1 --body x >/dev/null 2>"$err"
  rc=$?
  set -e
  expect_code 2 "$rc" "a put with no seq must refuse"
  assert_contains "$(cat "$err")" "--seq" "the refusal should name --seq"
  [ "$(published_count "$dir")" = 0 ] || fail "a refused put must publish nothing"
  pass "fm-steer: put refuses an envelope it cannot complete"
}

test_steer_has_no_contract_escape_hatches() {
  local dir err rc flag
  dir=$(setup_overlay_dir pinned)
  err="$dir/err"
  for flag in --subject --schema --id --consumer; do
    set +e
    steer "$dir" put --stream firstmate --task t1 --seq 1 "$flag" x --body y \
      >/dev/null 2>"$err"
    rc=$?
    set -e
    expect_code 2 "$rc" "fm-steer must refuse $flag"
    assert_contains "$(cat "$err")" "unknown option: $flag" \
      "the refusal should name the rejected flag"
  done
  [ "$(published_count "$dir")" = 0 ] || fail "a refused put must publish nothing"
  pass "fm-steer: the steer subject, schema, and durable consumer cannot be overridden"
}

test_next_peeks_and_ack_handles_that_steer() {
  local dir out seq
  dir=$(setup_overlay_dir next-ack)
  steer "$dir" put --stream firstmate --task t1 --seq 1 --body "please rebase" >/dev/null
  steer "$dir" put --stream firstmate --task t2 --seq 1 --body "second steer" >/dev/null
  [ "$(pending_count "$dir" firstmate)" = 2 ] \
    || fail "list should report both unacknowledged steers"
  out=$(steer "$dir" next --stream firstmate)
  seq=$(printf '%s\n' "$out" | reported_stream_seq)
  [ -n "$seq" ] || fail "next should report the steer's JetStream sequence: $out"
  [ "$(printf '%s\n' "$out" | after_separator | after_separator)" = "please rebase" ] \
    || fail "next did not round-trip the body: $out"
  [ "$(pending_count "$dir" firstmate)" = 2 ] \
    || fail "next alone must not mark a steer handled"
  [ "$(printf '%s\n' "$(steer "$dir" next --stream firstmate)" | reported_stream_seq)" = "$seq" ] \
    || fail "a second peek should return the same unhandled steer"
  steer "$dir" ack --stream firstmate --stream-seq "$seq" >/dev/null
  [ "$(pending_count "$dir" firstmate)" = 1 ] \
    || fail "ack is what marks a steer handled"
  pass "fm-steer: next peeks the head and ack handles that same steer"
}

test_repeated_ack_never_handles_an_unread_steer() {
  local dir out seq second
  dir=$(setup_overlay_dir ack-repeat)
  steer "$dir" put --stream firstmate --task t1 --seq 1 --body "first steer" >/dev/null
  steer "$dir" put --stream firstmate --task t2 --seq 1 --body "second steer" >/dev/null
  seq=$(steer "$dir" next --stream firstmate | reported_stream_seq)
  steer "$dir" ack --stream firstmate --stream-seq "$seq" >/dev/null
  out=$(steer "$dir" ack --stream firstmate --stream-seq "$seq") \
    || fail "re-acknowledging a handled steer should succeed"
  assert_contains "$out" "already handled" "the repeat should report the steer was already handled"
  [ "$(pending_count "$dir" firstmate)" = 1 ] \
    || fail "the repeated ack handled a steer nobody read"
  second=$(steer "$dir" next --stream firstmate | after_separator | after_separator)
  [ "$second" = "second steer" ] \
    || fail "the unread steer should still be deliverable, got: $second"
  pass "fm-steer: a repeated ack never handles a steer nobody read"
}

test_ack_refuses_another_sequence() {
  local dir err rc
  dir=$(setup_overlay_dir ack-guard)
  err="$dir/err"
  steer "$dir" put --stream firstmate --task t1 --seq 1 --body "only steer" >/dev/null
  set +e
  steer "$dir" ack --stream firstmate >/dev/null 2>"$err"
  rc=$?
  set -e
  expect_code 2 "$rc" "ack without a sequence must refuse"
  assert_contains "$(cat "$err")" "--stream-seq" "the refusal should name --stream-seq"
  set +e
  steer "$dir" ack --stream firstmate --stream-seq 99 >/dev/null 2>"$err"
  rc=$?
  set -e
  expect_code 1 "$rc" "ack of a sequence the consumer never delivered must refuse"
  assert_contains "$(cat "$err")" "run next first" "the refusal should say how to get a sequence"
  [ "$(pending_count "$dir" firstmate)" = 1 ] \
    || fail "a refused ack must leave the steer pending"
  pass "fm-steer: ack refuses a sequence next did not report"
}

test_inbox_does_not_touch_task_disk_inbox() {
  local dir rec checksum after seq
  dir=$(setup_overlay_dir disk-guard)
  mkdir -p "$dir/home/state/t1.inbox"
  rec="$dir/home/state/t1.inbox/001.msg"
  printf 'schema=fm-task-inbox.v1\nat=now\n--\nkeep me\n' >"$rec"
  checksum=$(cksum "$rec")
  steer "$dir" put --stream firstmate --task t1 --seq 1 --body "overlay" >/dev/null
  seq=$(steer "$dir" next --stream firstmate | reported_stream_seq)
  steer "$dir" ack --stream firstmate --stream-seq "$seq" >/dev/null
  [ -f "$rec" ] || fail "the on-disk task inbox was removed"
  after=$(cksum "$rec")
  [ "$checksum" = "$after" ] || fail "the on-disk task inbox was modified"
  [ ! -d "$dir/home/state/carverauto-inbox" ] \
    || fail "the overlay must not keep a message store of its own"
  pass "fm-steer: never deletes or mutates a task on-disk inbox"
}

test_notify_captain_needed_includes_portal_and_hides_token() {
  local home stub log out
  home="$TMP_ROOT/notify"
  stub="$home/notify.py"
  log="$home/notify.log"
  mkdir -p "$home"
  make_notify_stub "$home"
  out=$(DISCORD_WEBHOOK_URL='https://discord.com/api/webhooks/SECRETTOKEN/please-never-print' \
    FM_CARVERAUTO_NOTIFY_PY="$stub" NOTIFY_LOG="$log" \
    "$NOTIFY" captain-needed --title "Need a token" --body "Publish is blocked." )
  assert_contains "$out" "sent captain-needed" "wrapper should report the notify.py result"
  assert_not_contains "$out" "SECRETTOKEN" "wrapper stdout must never contain the webhook"
  assert_not_contains "$(cat "$log")" "SECRETTOKEN" "notify.py argv must never contain the webhook"
  assert_contains "$(cat "$log")" "Need a token" "title should reach notify.py"
  assert_contains "$(cat "$log")" "https://firstmate.carverauto.dev" "portal URL should be in the body"
  pass "notify: captain-needed pages Discord with the portal URL and no webhook on argv"
}

test_notify_portal_url_cannot_be_suppressed() {
  local home log err rc
  home="$TMP_ROOT/notify-portal"
  mkdir -p "$home"
  make_notify_stub "$home"
  log="$home/notify.log"
  err="$home/err"
  set +e
  FM_CARVERAUTO_NOTIFY_PY="$home/notify.py" NOTIFY_LOG="$log" \
    "$NOTIFY" captain-needed --title "Quiet page" --no-portal >/dev/null 2>"$err"
  rc=$?
  set -e
  expect_code 2 "$rc" "a page must not be able to drop the portal URL"
  assert_contains "$(cat "$err")" "unknown option: --no-portal" "the refusal should name the flag"
  [ ! -s "$log" ] || fail "a refused page must not reach Discord: $(cat "$log")"
  pass "notify: every captain-attention page carries the portal URL"
}

test_notify_pr_landed_rejects_bare_number() {
  local home log rc err
  home="$TMP_ROOT/notify-pr"
  mkdir -p "$home"
  make_notify_stub "$home"
  log="$home/notify.log"
  err="$home/err"
  set +e
  FM_CARVERAUTO_NOTIFY_PY="$home/notify.py" NOTIFY_LOG="$log" \
    "$NOTIFY" pr-landed --url 108 --outcome "landed" >/dev/null 2>"$err"
  rc=$?
  set -e
  expect_code 2 "$rc" "bare PR numbers must be refused"
  assert_contains "$(cat "$err")" "https" "the error should demand an https URL"
  pass "notify: pr-landed requires a full https URL"
}

test_notify_archify_requires_a_diagram() {
  local home log err rc out
  home="$TMP_ROOT/notify-archify"
  mkdir -p "$home"
  make_notify_stub "$home"
  log="$home/notify.log"
  err="$home/err"
  set +e
  FM_CARVERAUTO_NOTIFY_PY="$home/notify.py" NOTIFY_LOG="$log" \
    "$NOTIFY" archify --title "Fleet map" --notes "no attachment" >/dev/null 2>"$err"
  rc=$?
  set -e
  expect_code 2 "$rc" "archify without a diagram must refuse"
  assert_contains "$(cat "$err")" "--png" "the refusal should name the missing attachment"
  [ ! -s "$log" ] || fail "a refused archify must not page Discord: $(cat "$log")"
  : >"$home/map.png"
  out=$(FM_CARVERAUTO_NOTIFY_PY="$home/notify.py" NOTIFY_LOG="$log" \
    "$NOTIFY" archify --title "Fleet map" --png "$home/map.png")
  assert_contains "$out" "sent archify" "archify with a diagram runs notify.py archify"
  assert_contains "$(cat "$log")" "--png" "the diagram should reach notify.py"
  pass "notify: archify pages as archify or refuses, never as captain-needed"
}

test_portal_assign_publishes_its_own_family() {
  local dir out msg err rc
  dir=$(setup_overlay_dir portal)
  out=$(portal "$dir" assign --task-id t1 --worker grok \
    --pr-url https://github.com/mfreeman451/firstmate/pull/1 \
    --buildbuddy-url https://app.buildbuddy.io/invocation/abc)
  assert_contains "$out" "subject=firstmate.assign.t1" "an assignment is its own subject family"
  assert_not_contains "$out" "stream=" "the assignment publish names no stream it never contacted"
  msg=$(published "$dir" 1) || fail "portal assign published nothing"
  assert_not_contains "$msg" "firstmate.steer" "an assignment must not ride the steer subject"
  assert_contains "$msg" '"schema":"fm-carverauto-portal-assign.v1"' "payload should use the assignment schema"
  assert_contains "$msg" '"task_id":"t1"' "payload should include the task id"
  assert_contains "$msg" '"worker":"grok"' "payload should include the worker"
  assert_contains "$msg" 'https://github.com/mfreeman451/firstmate/pull/1' "payload should include the PR URL"
  assert_contains "$msg" 'https://app.buildbuddy.io/invocation/abc' "payload should include the BuildBuddy URL"
  assert_contains "$msg" 'https://firstmate.carverauto.dev' "payload should include the portal URL"
  err="$dir/err"
  set +e
  portal "$dir" assign --stream firstmate --task-id t1 --worker grok >/dev/null 2>"$err"
  rc=$?
  set -e
  expect_code 2 "$rc" "the assignment publisher takes no --stream"
  assert_contains "$(cat "$err")" "unknown option: --stream" "the refusal should name the flag"
  pass "portal: assign publishes task, worker, and https URLs on firstmate.assign.<task>"
}

test_portal_rejects_non_https() {
  local dir err rc
  dir=$(setup_overlay_dir portal-bad)
  err="$dir/err"
  set +e
  portal "$dir" assign --task-id t1 --worker grok \
    --issue-url http://example.invalid/issues/1 >/dev/null 2>"$err"
  rc=$?
  set -e
  expect_code 2 "$rc" "http issue URLs must be refused"
  [ "$(published_count "$dir")" = 0 ] || fail "a refused assignment must publish nothing"
  pass "portal: issue URLs must be https"
}

# run_send <dir> <fm-send args...>: fm-send against that dir's home, with the
# tmux and nats stubs on PATH and the overlay's store pinned to the dir.
run_send() {
  local dir=$1; shift
  env PATH="$dir/fakebin:$PATH" \
    FM_ROOT_OVERRIDE="$dir/home" FM_HOME="$dir/home" FM_SEND_LOG="$dir/send.log" \
    FM_SEND_SETTLE=0 NATS_STORE="$dir/nats" \
    FM_CARVERAUTO_NATS_URL=nats://127.0.0.1:4222 \
    "$SEND" "$@"
}

test_send_dual_write_keeps_disk_inbox() {
  local dir rec body msg
  dir=$(setup_overlay_dir send-dual)
  make_tmux_stubs "$dir"
  fm_write_meta "$dir/home/state/t1.meta" "window=sess:fm-t1" "kind=ship" "harness=claude"
  printf 'on\n' >"$dir/home/config/carverauto-overlay"
  printf 'firstmate\n' >"$dir/home/config/carverauto-inbox-stream"
  : >"$dir/send.log"
  run_send "$dir" t1 "please rebase onto main {{Count}}" >/dev/null
  rec="$dir/home/state/t1.inbox/001.msg"
  [ -f "$rec" ] || fail "dual-write must not skip the on-disk inbox"
  body=$(bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$rec")
  [ "$body" = "please rebase onto main {{Count}}" ] || fail "disk inbox body changed: $body"
  msg=$(published "$dir" 1) || fail "fm-send did not dual-write onto JetStream"
  assert_contains "$msg" "firstmate.steer.t1" "dual-write subject is firstmate.steer.<task>"
  assert_contains "$msg" "schema=fm-task-inbox.v1" "dual-write payload uses the inbox schema"
  assert_contains "$msg" $'\nseq=1\n' "dual-write carries the disk record's sequence"
  [ "$(printf '%s\n' "$msg" | after_separator)" = "$body" ] \
    || fail "dual-write body diverged from the disk record: $msg"
  pass "fm-send: overlay dual-write is additive and keeps the on-disk inbox"
}

test_send_idempotent_resend_publishes_once() {
  local dir delivery
  dir=$(setup_overlay_dir send-idempotent)
  make_tmux_stubs "$dir"
  fm_write_secondmate_meta "$dir/home/state/s1.meta" "$dir/home" "sess:fm-s1" alpha claude
  printf 'on\n' >"$dir/home/config/carverauto-overlay"
  printf 'firstmate\n' >"$dir/home/config/carverauto-inbox-stream"
  : >"$dir/send.log"
  delivery=0123456789abcdef
  run_send "$dir" s1 --fire-and-forget "$delivery" "reconcile your own books" >/dev/null \
    || fail "the first fire-and-forget send failed"
  run_send "$dir" s1 --fire-and-forget "$delivery" "reconcile your own books" >/dev/null \
    || fail "the fire-and-forget retry failed"
  [ "$(ls -1 "$dir/home/state/s1.inbox"/*.msg | wc -l | tr -d ' ')" = 1 ] \
    || fail "the retry duplicated the on-disk record"
  [ "$(published_count "$dir")" = 1 ] \
    || fail "the retry duplicated the JetStream copy of a deduplicated steer"
  pass "fm-send: a deduplicated resend does not publish a second steer"
}

test_send_without_overlay_skips_dual_write() {
  local dir
  dir=$(setup_overlay_dir send-plain)
  make_tmux_stubs "$dir"
  fm_write_meta "$dir/home/state/t1.meta" "window=sess:fm-t1" "kind=ship" "harness=claude"
  : >"$dir/send.log"
  run_send "$dir" t1 "ordinary steer" >/dev/null
  [ -f "$dir/home/state/t1.inbox/001.msg" ] || fail "plain send must still write the disk inbox"
  [ "$(published_count "$dir")" = 0 ] || fail "overlay off must publish nothing"
  pass "fm-send: overlay off leaves the disk inbox as the only store"
}

test_stream_required
test_put_publishes_the_full_envelope
test_put_sends_the_body_bytes_unchanged
test_put_marks_fire_and_forget
test_put_requires_the_contract_fields
test_steer_has_no_contract_escape_hatches
test_next_peeks_and_ack_handles_that_steer
test_repeated_ack_never_handles_an_unread_steer
test_ack_refuses_another_sequence
test_inbox_does_not_touch_task_disk_inbox
test_notify_captain_needed_includes_portal_and_hides_token
test_notify_portal_url_cannot_be_suppressed
test_notify_pr_landed_rejects_bare_number
test_notify_archify_requires_a_diagram
test_portal_assign_publishes_its_own_family
test_portal_rejects_non_https
test_send_dual_write_keeps_disk_inbox
test_send_idempotent_resend_publishes_once
test_send_without_overlay_skips_dual_write
