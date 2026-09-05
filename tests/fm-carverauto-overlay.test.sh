#!/usr/bin/env bash
# tests/fm-carverauto-overlay.test.sh - Carverauto fork overlay CLIs.
#
# Drives the public notify, steer, and portal executables plus fm-send's
# additive dual-write. JetStream is the steer inbox's only store, so a fake
# nats broker (publish into a directory, one durable consumer served from it)
# stands in for the server and lets put/next/ack/list be asserted end to end.
# Discord tokens never appear on argv or in wrapper output.
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

# A fake NATS server for the subset of the CLI the overlay uses: publish stores
# subject+body under $NATS_STORE/msgs, `consumer next` serves the head of the
# one durable consumer (acknowledging only when --ack advances its floor), and
# `consumer info --json` reports what that consumer has not acknowledged.
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
floor() { cat "$store/floor" 2>/dev/null || printf '0'; }
case "${args[0]:-}" in
  publish)
    n=$(( $(stored) + 1 ))
    printf '%s' "${args[1]}" >"$store/msgs/$(printf '%04d' "$n").subject"
    printf '%s' "${args[$(( ${#args[@]} - 1 ))]}" >"$store/msgs/$(printf '%04d' "$n").body"
    exit 0 ;;
  consumer)
    case "${args[1]:-}" in
      next)
        ack=0
        for a in "${args[@]}"; do
          case "$a" in --ack) ack=1 ;; esac
        done
        n=$(( $(floor) + 1 ))
        [ -f "$store/msgs/$(printf '%04d' "$n").body" ] \
          || { printf 'nats: no message\n' >&2; exit 1; }
        cat "$store/msgs/$(printf '%04d' "$n").body"
        printf '\n'
        if [ "$ack" = 1 ]; then
          printf '%s' "$n" >"$store/floor"
        fi
        exit 0 ;;
      info)
        printf '{"stream_name":"%s","name":"%s","num_ack_pending":0,"num_pending":%s}\n' \
          "${args[2]:-}" "${args[3]:-}" "$(( $(stored) - $(floor) ))"
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

# steer <dir> -- <fm-steer args...>: run the CLI against that dir's fake broker.
steer() {
  local dir=$1; shift
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" \
    NATS_STORE="$dir/nats" FM_CARVERAUTO_NATS_URL=nats://127.0.0.1:4222 \
    "$STEER" "$@"
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

# The body of an envelope or of a next/ack payload: everything after the "--".
envelope_body() {
  awk 'seen { print } $0 == "--" { seen=1 }'
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
  [ "$(printf '%s\n' "$msg" | envelope_body)" = $'steer body\nline 2' ] \
    || fail "the payload body did not survive the publish: $msg"
  assert_contains "$(cat "$dir/nats/argv.log")" "server=nats://127.0.0.1:4222" \
    "the configured NATS URL should reach the nats CLI"
  pass "fm-steer: put publishes the whole fm-task-inbox.v1 envelope"
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

test_steer_subject_and_schema_are_pinned() {
  local dir err rc flag
  dir=$(setup_overlay_dir pinned)
  err="$dir/err"
  for flag in --subject --schema --id; do
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
  pass "fm-steer: the steer subject and schema cannot be overridden"
}

test_next_peeks_and_ack_handles() {
  local dir out
  dir=$(setup_overlay_dir next-ack)
  steer "$dir" put --stream firstmate --task t1 --seq 1 --body "please rebase" >/dev/null
  steer "$dir" put --stream firstmate --task t2 --seq 1 --body "second steer" >/dev/null
  assert_contains "$(steer "$dir" list --stream firstmate)" "pending=2" \
    "list should report both unacknowledged steers"
  out=$(steer "$dir" next --stream firstmate)
  assert_contains "$out" "schema=fm-task-inbox.v1" "next should return the published envelope"
  [ "$(printf '%s\n' "$out" | envelope_body)" = "please rebase" ] \
    || fail "next did not round-trip the body: $out"
  assert_contains "$(steer "$dir" list --stream firstmate)" "pending=2" \
    "next alone must not mark a steer handled"
  steer "$dir" ack --stream firstmate >/dev/null
  assert_contains "$(steer "$dir" list --stream firstmate)" "pending=1" \
    "ack is what marks a steer handled"
  steer "$dir" ack --stream firstmate >/dev/null
  assert_contains "$(steer "$dir" list --stream firstmate)" "pending=0" \
    "list is the consumer's unacked count, not the stream's history"
  pass "fm-steer: next peeks, ack handles, list is pending"
}

test_inbox_does_not_touch_task_disk_inbox() {
  local dir rec checksum after
  dir=$(setup_overlay_dir disk-guard)
  mkdir -p "$dir/home/state/t1.inbox"
  rec="$dir/home/state/t1.inbox/001.msg"
  printf 'schema=fm-task-inbox.v1\nat=now\n--\nkeep me\n' >"$rec"
  checksum=$(cksum "$rec")
  steer "$dir" put --stream firstmate --task t1 --seq 1 --body "overlay" >/dev/null
  steer "$dir" next --stream firstmate >/dev/null
  steer "$dir" ack --stream firstmate >/dev/null
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
  local dir out msg
  dir=$(setup_overlay_dir portal)
  out=$(env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" \
    NATS_STORE="$dir/nats" FM_CARVERAUTO_NATS_URL=nats://127.0.0.1:4222 \
    "$PORTAL" assign --stream firstmate --task-id t1 --worker grok \
    --pr-url https://github.com/mfreeman451/firstmate/pull/1 \
    --buildbuddy-url https://app.buildbuddy.io/invocation/abc)
  assert_contains "$out" "stream=firstmate" "portal assign should name the stream"
  assert_contains "$out" "subject=firstmate.assign.t1" "an assignment is its own subject family"
  msg=$(published "$dir" 1) || fail "portal assign published nothing"
  assert_not_contains "$msg" "firstmate.steer" "an assignment must not ride the steer subject"
  assert_contains "$msg" '"schema":"fm-carverauto-portal-assign.v1"' "payload should use the assignment schema"
  assert_contains "$msg" '"task_id":"t1"' "payload should include the task id"
  assert_contains "$msg" '"worker":"grok"' "payload should include the worker"
  assert_contains "$msg" 'https://github.com/mfreeman451/firstmate/pull/1' "payload should include the PR URL"
  assert_contains "$msg" 'https://app.buildbuddy.io/invocation/abc' "payload should include the BuildBuddy URL"
  assert_contains "$msg" 'https://firstmate.carverauto.dev' "payload should include the portal URL"
  pass "portal: assign publishes task, worker, and https URLs on firstmate.assign.<task>"
}

test_portal_rejects_non_https() {
  local dir err rc
  dir=$(setup_overlay_dir portal-bad)
  err="$dir/err"
  set +e
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" NATS_STORE="$dir/nats" \
    "$PORTAL" assign --stream firstmate --task-id t1 --worker grok \
    --issue-url http://example.invalid/issues/1 >/dev/null 2>"$err"
  rc=$?
  set -e
  expect_code 2 "$rc" "http issue URLs must be refused"
  [ "$(published_count "$dir")" = 0 ] || fail "a refused assignment must publish nothing"
  pass "portal: issue URLs must be https"
}

# run_send <dir> -- <fm-send args...>: fm-send against that dir's home, with the
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
  run_send "$dir" t1 "please rebase onto main" >/dev/null
  rec="$dir/home/state/t1.inbox/001.msg"
  [ -f "$rec" ] || fail "dual-write must not skip the on-disk inbox"
  body=$(bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$rec")
  [ "$body" = "please rebase onto main" ] || fail "disk inbox body changed: $body"
  msg=$(published "$dir" 1) || fail "fm-send did not dual-write onto JetStream"
  assert_contains "$msg" "firstmate.steer.t1" "dual-write subject is firstmate.steer.<task>"
  assert_contains "$msg" "schema=fm-task-inbox.v1" "dual-write payload uses the inbox schema"
  assert_contains "$msg" $'\nseq=1\n' "dual-write carries the disk record's sequence"
  [ "$(printf '%s\n' "$msg" | envelope_body)" = "please rebase onto main" ] \
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
test_put_marks_fire_and_forget
test_put_requires_the_contract_fields
test_steer_subject_and_schema_are_pinned
test_next_peeks_and_ack_handles
test_inbox_does_not_touch_task_disk_inbox
test_notify_captain_needed_includes_portal_and_hides_token
test_notify_pr_landed_rejects_bare_number
test_notify_archify_requires_a_diagram
test_portal_assign_publishes_its_own_family
test_portal_rejects_non_https
test_send_dual_write_keeps_disk_inbox
test_send_idempotent_resend_publishes_once
test_send_without_overlay_skips_dual_write
