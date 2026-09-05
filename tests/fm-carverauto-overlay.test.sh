#!/usr/bin/env bash
# tests/fm-carverauto-overlay.test.sh - Carverauto fork overlay CLIs.
#
# Drives the public notify, inbox, and portal executables plus fm-send's
# additive dual-write. The file-backed inbox is the executable contract;
# a stub nats binary pins the nats backend argv. Discord tokens never appear
# on argv or in wrapper output.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NOTIFY="$ROOT/bin/fm-carverauto-notify.sh"
INBOX="$ROOT/bin/fm-steer.sh"
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

test_stream_required() {
  local home err rc
  home="$TMP_ROOT/stream-required"
  mkdir -p "$home/state"
  err="$home/err"
  set +e
  FM_HOME="$home" FM_CARVERAUTO_INBOX_BACKEND=file \
    "$INBOX" put >/dev/null 2>"$err"
  rc=$?
  set -e
  expect_code 2 "$rc" "put without --stream must refuse"
  assert_contains "$(cat "$err")" "--stream is required" "put should name the missing stream"
  pass "inbox CLI: --stream is required"
}

test_put_next_ack_list_file_backend() {
  local home store out err ack body listed
  home="$TMP_ROOT/inbox-file"
  store="$home/state/carverauto-inbox"
  mkdir -p "$home/state"
  out=$(printf 'steer body\nline 2' | FM_HOME="$home" FM_CARVERAUTO_INBOX_BACKEND=file \
    "$INBOX" put --stream firstmate --task t1)
  assert_contains "$out" "stream=firstmate" "put should name the stream"
  assert_contains "$out" "seq=1" "first put should be seq 1"
  listed=$(FM_HOME="$home" FM_CARVERAUTO_INBOX_BACKEND=file \
    "$INBOX" list --stream firstmate)
  assert_contains "$listed" "state=pending" "list should show pending (unacked) messages"
  assert_contains "$listed" "firstmate.steer.t1" "put should use firstmate.steer.<task>"
  stored=$(cat "$store/firstmate/available/"*)
  assert_contains "$stored" "schema=fm-task-inbox.v1" "payload schema is fm-task-inbox.v1"
  assert_contains "$stored" "task=t1" "payload includes task"
  assert_contains "$stored" $'seq=1\n' "payload includes seq"
  out=$(FM_HOME="$home" FM_CARVERAUTO_INBOX_BACKEND=file \
    "$INBOX" next --stream firstmate)
  ack=$(printf '%s\n' "$out" | awk -F= '/^ack=/ { print $2; exit }')
  [ -n "$ack" ] || fail "next should print an ack id"
  body=$(printf '%s\n' "$out" | awk 'seen { print } $0 == "--" { seen=1 }')
  [ "$body" = $'steer body\nline 2' ] || fail "next body did not round-trip: $body"
  FM_HOME="$home" FM_CARVERAUTO_INBOX_BACKEND=file \
    "$INBOX" ack --stream firstmate --ack "$ack" >/dev/null
  listed=$(FM_HOME="$home" FM_CARVERAUTO_INBOX_BACKEND=file \
    "$INBOX" list --stream firstmate)
  [ -z "$listed" ] || fail "list should be empty after ack, got: $listed"
  [ -d "$store/firstmate" ] || fail "file store should exist under state/carverauto-inbox"
  pass "inbox CLI: file backend put/next/ack/list round-trips the body"
}

test_inbox_does_not_touch_task_disk_inbox() {
  local home rec checksum after
  home="$TMP_ROOT/disk-guard"
  mkdir -p "$home/state/t1.inbox"
  rec="$home/state/t1.inbox/001.msg"
  printf 'schema=fm-task-inbox.v1\nat=now\n--\nkeep me\n' >"$rec"
  checksum=$(cksum "$rec")
  printf 'overlay' | FM_HOME="$home" FM_CARVERAUTO_INBOX_BACKEND=file \
    "$INBOX" put --stream firstmate >/dev/null
  FM_HOME="$home" FM_CARVERAUTO_INBOX_BACKEND=file \
    "$INBOX" next --stream firstmate >/dev/null
  [ -f "$rec" ] || fail "the on-disk task inbox was removed"
  after=$(cksum "$rec")
  [ "$checksum" = "$after" ] || fail "the on-disk task inbox was modified"
  pass "inbox CLI: never deletes or mutates a task on-disk inbox"
}

test_notify_captain_needed_includes_portal_and_hides_token() {
  local home stub log out err
  home="$TMP_ROOT/notify"
  stub="$home/notify.py"
  log="$home/notify.log"
  mkdir -p "$home"
  make_notify_stub "$home"
  out=$(DISCORD_WEBHOOK_URL='https://discord.com/api/webhooks/SECRETTOKEN/please-never-print' \
    FM_CARVERAUTO_NOTIFY_PY="$stub" NOTIFY_LOG="$log" \
    "$NOTIFY" captain-needed --title "Need a token" --body "Publish is blocked." )
  err=""
  assert_contains "$out" "sent captain-needed" "wrapper should report the notify.py result"
  assert_not_contains "$out" "SECRETTOKEN" "wrapper stdout must never contain the webhook"
  assert_not_contains "$(cat "$log")" "SECRETTOKEN" "notify.py argv must never contain the webhook"
  assert_contains "$(cat "$log")" "Need a token" "title should reach notify.py"
  assert_contains "$(cat "$log")" "https://firstmate.carverauto.dev" "portal URL should be in the body"
  pass "notify: captain-needed pages Discord with the portal URL and no webhook on argv"
}

test_notify_pr_landed_rejects_bare_number() {
  local home stub log rc err
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

test_portal_assign_publishes_json() {
  local home out body
  home="$TMP_ROOT/portal"
  mkdir -p "$home/state"
  out=$(FM_HOME="$home" FM_CARVERAUTO_INBOX_BACKEND=file \
    "$PORTAL" assign --stream firstmate --task-id t1 --worker grok \
    --pr-url https://github.com/mfreeman451/firstmate/pull/1 \
    --buildbuddy-url https://app.buildbuddy.io/invocation/abc)
  assert_contains "$out" "stream=firstmate" "portal assign should put onto the stream"
  body=$(FM_HOME="$home" FM_CARVERAUTO_INBOX_BACKEND=file \
    "$INBOX" next --stream firstmate | awk 'seen { print } $0 == "--" { seen=1 }')
  assert_contains "$body" '"schema":"fm-carverauto-portal-assign.v1"' "payload should use the assignment schema"
  assert_contains "$body" '"task_id":"t1"' "payload should include the task id"
  assert_contains "$body" '"worker":"grok"' "payload should include the worker"
  assert_contains "$body" 'https://github.com/mfreeman451/firstmate/pull/1' "payload should include the PR URL"
  assert_contains "$body" 'https://app.buildbuddy.io/invocation/abc' "payload should include the BuildBuddy URL"
  assert_contains "$body" 'https://firstmate.carverauto.dev' "payload should include the portal URL"
  pass "portal: assign publishes task, worker, and https URLs onto the stream"
}

test_portal_rejects_non_https() {
  local home err rc
  home="$TMP_ROOT/portal-bad"
  mkdir -p "$home/state"
  err="$home/err"
  set +e
  FM_HOME="$home" FM_CARVERAUTO_INBOX_BACKEND=file \
    "$PORTAL" assign --stream firstmate --task-id t1 --worker grok \
    --issue-url http://example.invalid/issues/1 >/dev/null 2>"$err"
  rc=$?
  set -e
  expect_code 2 "$rc" "http issue URLs must be refused"
  pass "portal: issue URLs must be https"
}

test_send_dual_write_keeps_disk_inbox() {
  local dir rec listed body
  dir="$TMP_ROOT/send-dual"
  mkdir -p "$dir/home/state" "$dir/home/config"
  make_tmux_stubs "$dir"
  fm_write_meta "$dir/home/state/t1.meta" "window=sess:fm-t1" "kind=ship" "harness=claude"
  printf 'on\n' >"$dir/home/config/carverauto-overlay"
  printf 'firstmate\n' >"$dir/home/config/carverauto-inbox-stream"
  : >"$dir/send.log"
  env PATH="$dir/fakebin:$PATH" \
    FM_ROOT_OVERRIDE="$dir/home" FM_HOME="$dir/home" FM_SEND_LOG="$dir/send.log" \
    FM_SEND_SETTLE=0 FM_CARVERAUTO_INBOX_BACKEND=file \
    "$SEND" t1 "please rebase onto main" >/dev/null
  rec="$dir/home/state/t1.inbox/001.msg"
  [ -f "$rec" ] || fail "dual-write must not skip the on-disk inbox"
  body=$(bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$rec")
  [ "$body" = "please rebase onto main" ] || fail "disk inbox body changed: $body"
  listed=$(FM_HOME="$dir/home" FM_CARVERAUTO_INBOX_BACKEND=file \
    "$INBOX" list --stream firstmate)
  assert_contains "$listed" "state=pending" "fm-send should dual-write onto the overlay stream"
  assert_contains "$listed" "firstmate.steer.t1" "dual-write subject is firstmate.steer.<task>"
  stored=$(cat "$dir/home/state/carverauto-inbox/firstmate/available/"*)
  assert_contains "$stored" "schema=fm-task-inbox.v1" "dual-write payload uses the on-disk inbox schema"
  pass "fm-send: overlay dual-write is additive and keeps the on-disk inbox"
}

test_send_without_overlay_skips_dual_write() {
  local dir listed
  dir="$TMP_ROOT/send-plain"
  mkdir -p "$dir/home/state"
  make_tmux_stubs "$dir"
  fm_write_meta "$dir/home/state/t1.meta" "window=sess:fm-t1" "kind=ship" "harness=claude"
  : >"$dir/send.log"
  env PATH="$dir/fakebin:$PATH" \
    FM_ROOT_OVERRIDE="$dir/home" FM_HOME="$dir/home" FM_SEND_LOG="$dir/send.log" \
    FM_SEND_SETTLE=0 \
    "$SEND" t1 "ordinary steer" >/dev/null
  [ -f "$dir/home/state/t1.inbox/001.msg" ] || fail "plain send must still write the disk inbox"
  [ ! -d "$dir/home/state/carverauto-inbox" ] || fail "overlay store should stay absent when overlay is off"
  pass "fm-send: overlay off leaves the disk inbox as the only store"
}

test_put_body_flag_matches_openspec() {
  local home listed body
  home="$TMP_ROOT/put-body"
  mkdir -p "$home/state"
  FM_HOME="$home" FM_CARVERAUTO_INBOX_BACKEND=file \
    "$INBOX" put --stream firstmate-steer --task fm-hub --body "please rebase" >/dev/null
  listed=$(FM_HOME="$home" FM_CARVERAUTO_INBOX_BACKEND=file \
    "$INBOX" list --stream firstmate-steer)
  assert_contains "$listed" "firstmate.steer.fm-hub" "OpenSpec put uses firstmate.steer.<task>"
  body=$(FM_HOME="$home" FM_CARVERAUTO_INBOX_BACKEND=file \
    "$INBOX" next --stream firstmate-steer | awk 'seen { print } $0 == "--" { seen=1 }')
  [ "$body" = "please rebase" ] || fail "--body did not round-trip: $body"
  pass "inbox CLI: put --stream --task --body matches the OpenSpec agent publish"
}

test_nats_backend_put_uses_nats_cli() {
  local home fb log out
  home="$TMP_ROOT/nats-put"
  fb="$home/fakebin"
  log="$home/nats.log"
  mkdir -p "$fb" "$home/state"
  cat >"$fb/nats" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$NATS_LOG"
exit 0
SH
  chmod +x "$fb/nats"
  out=$(printf 'hello' | PATH="$fb:$PATH" FM_HOME="$home" \
    FM_CARVERAUTO_INBOX_BACKEND=nats FM_CARVERAUTO_NATS_URL=nats://127.0.0.1:4222 \
    NATS_LOG="$log" "$INBOX" put --stream firstmate --task t1)
  assert_contains "$out" "backend=nats" "nats put should name the backend"
  assert_contains "$(cat "$log")" "publish" "nats CLI should be invoked to publish"
  assert_contains "$(cat "$log")" "firstmate.steer.t1" "publish subject should be firstmate.steer.<task>"
  assert_contains "$(cat "$log")" "--server" "NATS URL should be passed to nats"
  pass "inbox CLI: nats backend put calls the nats CLI"
}

test_stream_required
test_put_next_ack_list_file_backend
test_inbox_does_not_touch_task_disk_inbox
test_notify_captain_needed_includes_portal_and_hides_token
test_notify_pr_landed_rejects_bare_number
test_portal_assign_publishes_json
test_portal_rejects_non_https
test_send_dual_write_keeps_disk_inbox
test_send_without_overlay_skips_dual_write
test_put_body_flag_matches_openspec
test_nats_backend_put_uses_nats_cli
