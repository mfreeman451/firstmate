#!/usr/bin/env bash
# tests/fm-carverauto-overlay.test.sh - Carverauto fork overlay CLIs.
#
# Drives the public notify, steer, and portal executables plus fm-send's
# additive dual-write. JetStream is the steer inbox's only store, so a fake
# nats broker stands in for the server: it stores a message only when it is
# published to JetStream on a subject a stream captures - a core publish is
# dropped exactly as a real server drops one with no subscriber - and it models
# the one durable consumer (delivery, negative acknowledgement, ack floor) and
# natscli's Go-template expansion of a publish body, which is what the CLI must
# switch off. Discord tokens never appear on argv or in wrapper output.
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

# A fake NATS server for the subset of the CLI the overlay uses. It rejects any
# flag the modelled binary does not implement, exactly as fisk does, so a test
# can never pass against a CLI shape the real binary lacks.
#   publish        stores subject+body under $NATS_STORE/msgs only for a -J
#                  publish whose subject matches a prefix in $NATS_STORE/subjects
#                  ("<stream> <prefix>" per line); it reports the acknowledging
#                  stream by name as natscli does. A core publish is accepted and
#                  dropped, and a -J publish no stream captures fails as the
#                  JetStream acknowledgement would. Like natscli it expands
#                  {{Count}} in the body unless the publisher passed
#                  --templates=false; NATS_FAKE_TEMPLATES=0 models a natscli
#                  older than 0.4.0, which rejects that flag at parse time
#   consumer next  serves the head of the one durable consumer: --nak leaves it
#                  pending and first in line, --ack advances the ack floor
#   consumer info  reports that consumer's delivered/ack_floor sequences and
#                  its undelivered and delivered-unacked counts
#                  NATS_FAKE_HANG=1 models a broker that accepts the connection
#                  and never answers
#   stream info    describes only a stream the registry stands up: its subject
#                  set and its stored sequence range
#   stream get     returns one stored message, base64 body included
make_nats_stub() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat >"$fb/nats" <<'SH'
#!/usr/bin/env bash
set -u
store=${NATS_STORE:?NATS_STORE is required}
mkdir -p "$store/msgs"
templates=${NATS_FAKE_TEMPLATES:-1}

reject() {  # <flag>
  printf "error: unknown long flag '%s'\n" "$1" >&2
  exit 1
}

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
    expand=1
    js=0
    rest=()
    i=1
    while [ "$i" -lt "${#args[@]}" ]; do
      a=${args[$i]}
      case "$a" in
        -J|--jetstream) js=1 ;;
        --templates=false)
          [ "$templates" = 1 ] || reject --templates
          expand=0 ;;
        --) : ;;
        -*) reject "${a%%=*}" ;;
        *) rest+=("$a") ;;
      esac
      i=$((i + 1))
    done
    subject=${rest[0]}
    body=${rest[1]:-}
    if [ "$expand" = 1 ]; then
      body=${body//\{\{Count\}\}/1}
    fi
    if [ "$js" = 0 ]; then
      exit 0
    fi
    if [ -n "${FM_SEND_LOG:-}" ] && [ -f "${FM_SEND_LOG}" ]; then
      cp "$FM_SEND_LOG" "$store/send-log-at-publish"
    fi
    if [ "${NATS_FAKE_HANG:-0}" = 1 ]; then
      /bin/sleep 30
    fi
    captured=
    if [ -f "$store/subjects" ]; then
      while read -r sname prefix; do
        [ -n "$prefix" ] || continue
        case "$subject" in "$prefix"*) captured=$sname ;; esac
      done <"$store/subjects"
    fi
    if [ -z "$captured" ]; then
      printf 'nats: error: nats: no responders available for request\n' >&2
      exit 1
    fi
    n=$(( $(stored) + 1 ))
    printf '%s' "$subject" >"$store/msgs/$(printf '%04d' "$n").subject"
    printf '%s' "$body" >"$store/msgs/$(printf '%04d' "$n").body"
    printf 'Stored in Stream: %s Sequence: %s\n' "$captured" "$n" >&2
    exit 0 ;;
  request)
    IFS=. read -r prefix kind stream consumer count seq delivery timestamp pending <<<"${args[1]:-}"
    [ "$prefix.$kind" = '$JS.ACK' ] && [ "${args[2]:-}" = +ACK ] || exit 2
    [ "$seq" -le "$(state_get delivered)" ] || exit 1
    if [ "$seq" -gt "$(state_get floor)" ]; then
      printf '%s' "$seq" >"$store/floor"
    fi
    if [ "$(state_get nak)" = "$seq" ]; then
      printf '0' >"$store/nak"
    fi
    exit 0 ;;
  stream)
    i=4
    while [ "$i" -lt "${#args[@]}" ]; do
      a=${args[$i]}
      case "$a" in
        --json|-j) : ;;
        -*) reject "${a%%=*}" ;;
      esac
      i=$((i + 1))
    done
    case "${args[1]:-}" in
      info)
        subjects=
        if [ -f "$store/subjects" ]; then
          while read -r sname prefix; do
            [ -n "$prefix" ] || continue
            [ "$sname" = "${args[2]:-}" ] || continue
            [ -z "$subjects" ] || subjects="$subjects,"
            subjects="$subjects\"$prefix>\""
          done <"$store/subjects"
        fi
        if [ -z "$subjects" ]; then
          printf 'nats: error: stream not found\n' >&2
          exit 1
        fi
        printf '{"config":{"name":"%s","subjects":[%s]},"state":{"messages":%s,"first_seq":1,"last_seq":%s}}\n' \
          "${args[2]:-}" "$subjects" "$(stored)" "$(stored)"
        exit 0 ;;
      get)
        msg="$store/msgs/$(printf '%04d' "${args[3]:-0}")"
        [ -f "$msg.body" ] \
          || { printf 'nats: error: no message found\n' >&2; exit 1; }
        printf '{"subject":"%s","seq":%s,"data":"%s","time":"2026-01-01T00:00:00Z"}\n' \
          "$(cat "$msg.subject")" "${args[3]:-0}" "$(base64 <"$msg.body" | tr -d '\n')"
        exit 0 ;;
    esac
    ;;
  consumer)
    case "${args[1]:-}" in
      next)
        ack=0
        nak=0
        i=4
        while [ "$i" -lt "${#args[@]}" ]; do
          a=${args[$i]}
          case "$a" in
            --count) i=$((i + 2)); continue ;;
            --ack) ack=1 ;;
            --no-ack) ack=0 ;;
            --nak) nak=1 ;;
            --raw|-r) : ;;
            -*) reject "${a%%=*}" ;;
          esac
          i=$((i + 1))
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
        i=4
        while [ "$i" -lt "${#args[@]}" ]; do
          a=${args[$i]}
          case "$a" in
            --json|-j) : ;;
            -*) reject "${a%%=*}" ;;
          esac
          i=$((i + 1))
        done
        if [ -n "${NATS_FAKE_ACK_SLOT:-}" ]; then
          snapshot=$(NATS_FAKE_ACK_SLOT= "$0" consumer info "${args[2]}" "${args[3]}" --json)
          touch "$store/ready.$NATS_FAKE_ACK_SLOT"
          for ((attempt=0; attempt<500; attempt++)); do
            [ -f "$store/ready.1" ] && [ -f "$store/ready.2" ] && break
            /bin/sleep 0.01
          done
          [ -f "$store/ready.1" ] && [ -f "$store/ready.2" ] || exit 1
          if [ "$NATS_FAKE_ACK_SLOT" = 2 ]; then
            for ((attempt=0; attempt<500; attempt++)); do
              [ "$(state_get floor)" -ge 1 ] && break
              /bin/sleep 0.01
            done
            [ "$(state_get floor)" -ge 1 ] || exit 1
          fi
          printf '%s\n' "$snapshot"
          exit 0
        fi
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
    NATS_STORE="$dir/nats" \
    FM_CARVERAUTO_NATS_URL="${FM_CARVERAUTO_NATS_URL:-nats://127.0.0.1:4222}" \
    NATS_FAKE_TEMPLATES="${NATS_FAKE_TEMPLATES:-1}" \
    "$STEER" "$@"
}

portal() {  # <dir> <fm-carverauto-portal args...>
  local dir=$1; shift
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" \
    NATS_STORE="$dir/nats" \
    FM_CARVERAUTO_NATS_URL="${FM_CARVERAUTO_NATS_URL:-nats://127.0.0.1:4222}" \
    NATS_FAKE_TEMPLATES="${NATS_FAKE_TEMPLATES:-1}" \
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
  find "$1/nats/msgs" -maxdepth 1 -type f -name '*.body' 2>/dev/null | wc -l | tr -d ' '
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

# The streams the fake broker stands up, as "<stream> <subject prefix>": a
# JetStream publish outside them is not stored, exactly as a real server refuses
# one no stream owns, and the acknowledgement names the stream that stored it.
setup_overlay_dir() {  # <name> -> echoes a dir with fakebin, home, and store
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state" "$dir/home/config" "$dir/nats/msgs"
  make_nats_stub "$dir"
  printf 'firstmate firstmate.steer.\nfirstmate firstmate.assign.\n' >"$dir/nats/subjects"
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
  out=$(steer "$dir" put --stream firstmate --task t1 --seq 3 --body $'steer body\nline 2')
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

test_put_refuses_when_the_named_stream_is_not_the_steers_stream() {
  local dir err out rc
  dir=$(setup_overlay_dir wrong-stream)
  err="$dir/err"
  printf 'FIRSTMATE firstmate.steer.\n' >"$dir/nats/subjects"
  set +e
  out=$(steer "$dir" put --stream firstmate --task t1 --seq 1 --body "please rebase" 2>"$err")
  rc=$?
  set -e
  expect_code 1 "$rc" "a steer another stream would store must not report success"
  assert_not_contains "$out" "put:" "no success line may claim a stream that does not hold the steer"
  assert_contains "$(cat "$err")" "firstmate" "the failure should name the stream that was asked for"
  [ "$(published_count "$dir")" = 0 ] \
    || fail "a steer must not be published before the named stream is known to capture it"
  pass "fm-steer: put refuses before publishing when --stream is not the steer's stream"
}

test_put_refuses_a_nats_cli_that_rewrites_bodies() {
  local dir err rc log
  dir=$(setup_overlay_dir old-natscli)
  err="$dir/err"
  set +e
  NATS_FAKE_TEMPLATES=0 steer "$dir" put --stream firstmate --task t1 --seq 1 \
    --body 'ship {{Count}} now' >/dev/null 2>"$err"
  rc=$?
  set -e
  expect_code 1 "$rc" "a nats CLI that rewrites a body must not be published through"
  assert_contains "$(cat "$err")" "natscli 0.4.0" "the refusal should name the CLI the overlay needs"
  [ "$(published_count "$dir")" = 0 ] \
    || fail "nothing may be published through a CLI that rewrites bodies"
  pass "fm-steer: put refuses a nats CLI that would expand a steer body"
}

test_nats_url_must_not_carry_credentials() {
  local dir err rc log
  dir=$(setup_overlay_dir nats-userinfo)
  err="$dir/err"
  set +e
  FM_CARVERAUTO_NATS_URL='nats://fm:s3cret@nats.carverauto.dev:4222' \
    steer "$dir" put --stream firstmate --task t1 --seq 1 --body "please rebase" \
    >/dev/null 2>"$err"
  rc=$?
  set -e
  expect_code 1 "$rc" "a NATS URL carrying a password must not be used"
  assert_contains "$(cat "$err")" "NATS_CREDS" \
    "the refusal should point at the credential environment"
  [ "$(published_count "$dir")" = 0 ] || fail "a refused URL must publish nothing"
  log=$(cat "$dir/nats/argv.log" 2>/dev/null || printf '')
  assert_not_contains "$log" "s3cret" "the password must never reach the nats CLI argv"
  pass "fm-steer: a NATS URL that embeds credentials never reaches argv"
}

test_put_fails_when_no_stream_stored_the_steer() {
  local dir err rc
  dir=$(setup_overlay_dir no-stream)
  err="$dir/err"
  printf 'firstmate firstmate.assign.\n' >"$dir/nats/subjects"
  set +e
  steer "$dir" put --stream firstmate --task t1 --seq 1 --body "please rebase" \
    >/dev/null 2>"$err"
  rc=$?
  set -e
  expect_code 1 "$rc" "a steer no stream stored must not report a delivery"
  assert_contains "$(cat "$err")" "firstmate.steer.t1" "the failure should name the subject"
  [ "$(published_count "$dir")" = 0 ] || fail "nothing should have been stored"
  pass "fm-steer: put fails when no stream captured the steer subject"
}

test_nats_url_env_is_left_to_the_nats_cli() {
  local dir out log
  dir=$(setup_overlay_dir nats-env-url)
  out=$(env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" NATS_STORE="$dir/nats" \
    NATS_URL='nats://fm:s3cret@nats.carverauto.dev:4222' \
    "$STEER" put --stream firstmate --task t1 --seq 1 --body "please rebase") \
    || fail "natscli's own NATS_URL must not block a steer"
  assert_contains "$out" "subject=firstmate.steer.t1" "the steer should publish normally"
  [ "$(published_count "$dir")" = 1 ] || fail "the steer should have been stored"
  log=$(cat "$dir/nats/argv.log")
  assert_not_contains "$log" "s3cret" "NATS_URL must never be copied onto the nats CLI argv"
  assert_not_contains "$log" "server=" "the overlay passes no --server when it has no URL of its own"
  pass "fm-steer: NATS_URL stays in the nats CLI's own environment"
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
  set +e
  printf 'from stdin' | steer "$dir" put --stream firstmate --task t1 --seq 1 >/dev/null 2>"$err"
  rc=$?
  set -e
  expect_code 2 "$rc" "put takes its body from --body, never from stdin"
  assert_contains "$(cat "$err")" "--body" "the refusal should name --body"
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

test_overlapping_ack_retries_preserve_unread_steer() {
  local dir seq first second body
  dir=$(setup_overlay_dir ack-overlap)
  steer "$dir" put --stream firstmate --task t1 --seq 1 --body "first steer" >/dev/null
  steer "$dir" put --stream firstmate --task t2 --seq 1 --body "unread steer" >/dev/null
  seq=$(steer "$dir" next --stream firstmate | reported_stream_seq)
  NATS_FAKE_ACK_SLOT=1 steer "$dir" ack --stream firstmate --stream-seq "$seq" >"$dir/first" &
  first=$!
  NATS_FAKE_ACK_SLOT=2 steer "$dir" ack --stream firstmate --stream-seq "$seq" >"$dir/second" &
  second=$!
  wait "$first" || fail "first overlapping ack failed"
  wait "$second" || fail "second overlapping ack failed"
  [ "$(pending_count "$dir" firstmate)" = 1 ] \
    || fail "overlapping acknowledgements consumed an unread steer"
  body=$(steer "$dir" next --stream firstmate | after_separator | after_separator)
  [ "$body" = "unread steer" ] || fail "unread steer was not preserved: $body"
  pass "fm-steer: overlapping ack retries preserve the unread steer"
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

test_list_enumerates_the_pending_steers() {
  local dir listed seq
  dir=$(setup_overlay_dir list-enumerate)
  steer "$dir" put --stream firstmate --task t1 --seq 1 --body "first" >/dev/null
  steer "$dir" put --stream firstmate --task t2 --seq 4 --body "second" >/dev/null
  steer "$dir" put --stream firstmate --task t3 --seq 2 --body "third" >/dev/null
  listed=$(steer "$dir" list --stream firstmate)
  assert_contains "$listed" "pending=3" "list should still report the pending count"
  assert_contains "$listed" "stream-seq=1 subject=firstmate.steer.t1 task=t1 seq=1" \
    "list should name each pending steer by the sequence ack takes"
  assert_contains "$listed" "stream-seq=2 subject=firstmate.steer.t2 task=t2 seq=4" \
    "a steer behind the head must be listed without being delivered"
  assert_contains "$listed" "stream-seq=3 subject=firstmate.steer.t3 task=t3 seq=2" \
    "every pending steer should be listed"
  seq=$(steer "$dir" next --stream firstmate | reported_stream_seq)
  steer "$dir" ack --stream firstmate --stream-seq "$seq" >/dev/null
  listed=$(steer "$dir" list --stream firstmate)
  assert_contains "$listed" "pending=2" "the handled steer should leave the pending count"
  assert_not_contains "$listed" "task=t1" "a handled steer must not be listed as pending"
  assert_contains "$listed" "task=t2" "the remaining steers should still be listed"
  pass "fm-steer: list enumerates the pending steers, not just how many"
}

test_list_bounds_the_steers_it_describes() {
  local dir listed described i
  dir=$(setup_overlay_dir list-bounded)
  i=1
  while [ "$i" -le 12 ]; do
    steer "$dir" put --stream firstmate --task "t$i" --seq 1 --body "steer $i" >/dev/null
    i=$((i + 1))
  done
  listed=$(steer "$dir" list --stream firstmate)
  assert_contains "$listed" "pending=12" "the pending count stays exact however many are described"
  described=$(printf '%s\n' "$listed" | grep -c '^stream-seq=')
  [ "$described" = 10 ] \
    || fail "list described $described steers; the enumeration must stay bounded"
  assert_contains "$listed" "listed=10 more=2" \
    "list should report the pending steers it did not describe"
  pass "fm-steer: list bounds the steers it describes and reports the remainder"
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
  : >"$log"
  set +e
  FM_CARVERAUTO_NOTIFY_PY="$home/notify.py" NOTIFY_LOG="$log" \
    "$NOTIFY" archify --title "Fleet map" --html "$home/map.html" >/dev/null 2>"$err"
  rc=$?
  set -e
  expect_code 2 "$rc" "Discord renders no HTML, so archify takes no HTML attachment"
  assert_contains "$(cat "$err")" "unknown option: --html" "the refusal should name the rejected flag"
  [ ! -s "$log" ] || fail "a refused archify must not page Discord: $(cat "$log")"
  pass "notify: archify pages a PNG diagram or refuses, never HTML and never as captain-needed"
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
    NATS_FAKE_HANG="${NATS_FAKE_HANG:-0}" \
    FM_CARVERAUTO_DUAL_WRITE_BUDGET_SECS="${FM_CARVERAUTO_DUAL_WRITE_BUDGET_SECS:-10}" \
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

test_send_rings_the_doorbell_before_the_dual_write() {
  local dir
  dir=$(setup_overlay_dir send-order)
  make_tmux_stubs "$dir"
  fm_write_meta "$dir/home/state/t1.meta" "window=sess:fm-t1" "kind=ship" "harness=claude"
  printf 'on\n' >"$dir/home/config/carverauto-overlay"
  printf 'firstmate\n' >"$dir/home/config/carverauto-inbox-stream"
  : >"$dir/send.log"
  run_send "$dir" t1 "please rebase onto main" >/dev/null
  [ "$(published_count "$dir")" = 1 ] || fail "the steer should have been dual-written"
  [ -s "$dir/nats/send-log-at-publish" ] \
    || fail "the doorbell must already have rung when the overlay reached NATS"
  pass "fm-send: the doorbell rings before the overlay waits on NATS"
}

test_send_dual_write_is_bounded() {
  local dir err
  dir=$(setup_overlay_dir send-hang)
  make_tmux_stubs "$dir"
  fm_write_meta "$dir/home/state/t1.meta" "window=sess:fm-t1" "kind=ship" "harness=claude"
  printf 'on\n' >"$dir/home/config/carverauto-overlay"
  printf 'firstmate\n' >"$dir/home/config/carverauto-inbox-stream"
  : >"$dir/send.log"
  err="$dir/err"
  NATS_FAKE_HANG=1 FM_CARVERAUTO_DUAL_WRITE_BUDGET_SECS=1 \
    run_send "$dir" t1 "please rebase onto main" >/dev/null 2>"$err" \
    || fail "a broker that never answers must not fail the steer"
  [ -f "$dir/home/state/t1.inbox/001.msg" ] || fail "the on-disk record must still be written"
  [ -s "$dir/send.log" ] || fail "the doorbell must have rung despite the hung broker"
  [ "$(published_count "$dir")" = 0 ] || fail "a bounded dual-write stored nothing"
  assert_contains "$(cat "$err")" "bound" "fm-send should say the dual-write hit its bound"
  pass "fm-send: a broker that never answers cannot hold a steer open"
}

test_send_dual_write_reports_a_steer_that_did_not_land() {
  local dir rec err
  dir=$(setup_overlay_dir send-nostream)
  make_tmux_stubs "$dir"
  fm_write_meta "$dir/home/state/t1.meta" "window=sess:fm-t1" "kind=ship" "harness=claude"
  printf 'on\n' >"$dir/home/config/carverauto-overlay"
  printf 'firstmate\n' >"$dir/home/config/carverauto-inbox-stream"
  printf 'firstmate firstmate.assign.\n' >"$dir/nats/subjects"
  : >"$dir/send.log"
  err="$dir/err"
  run_send "$dir" t1 "please rebase onto main" >/dev/null 2>"$err" \
    || fail "a dual-write that did not land must not fail the steer"
  rec="$dir/home/state/t1.inbox/001.msg"
  [ -f "$rec" ] || fail "the on-disk record is still the delivery record"
  [ "$(published_count "$dir")" = 0 ] || fail "nothing should have been stored"
  assert_contains "$(cat "$err")" "dual-write did not land" \
    "fm-send should say the JetStream copy did not land"
  pass "fm-send: a steer no stream stored is reported, never counted as landed"
}

test_send_idempotent_resend_republishes_the_mirror() {
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
  [ "$(find "$dir/home/state/s1.inbox" -maxdepth 1 -type f -name '*.msg' | wc -l | tr -d ' ')" = 1 ] \
    || fail "the retry duplicated the on-disk record"
  [ "$(published_count "$dir")" = 2 ] \
    || fail "the retry must republish the mirror rather than silently skip it"
  pass "fm-send: a deduplicated resend still republishes the JetStream mirror"
}

test_send_overlay_opt_in_is_exactly_on() {
  local dir
  dir=$(setup_overlay_dir send-optin)
  make_tmux_stubs "$dir"
  fm_write_meta "$dir/home/state/t1.meta" "window=sess:fm-t1" "kind=ship" "harness=claude"
  printf 'true\n' >"$dir/home/config/carverauto-overlay"
  printf 'firstmate\n' >"$dir/home/config/carverauto-inbox-stream"
  : >"$dir/send.log"
  run_send "$dir" t1 "ordinary steer" >/dev/null
  [ -f "$dir/home/state/t1.inbox/001.msg" ] || fail "the disk inbox must still be written"
  [ "$(published_count "$dir")" = 0 ] \
    || fail "only an exact 'on' opts this home into the overlay"
  pass "fm-send: the overlay opt-in is exactly on"
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
test_put_fails_when_no_stream_stored_the_steer
test_put_refuses_when_the_named_stream_is_not_the_steers_stream
test_put_refuses_a_nats_cli_that_rewrites_bodies
test_nats_url_must_not_carry_credentials
test_nats_url_env_is_left_to_the_nats_cli
test_put_marks_fire_and_forget
test_put_requires_the_contract_fields
test_steer_has_no_contract_escape_hatches
test_next_peeks_and_ack_handles_that_steer
test_repeated_ack_never_handles_an_unread_steer
test_overlapping_ack_retries_preserve_unread_steer
test_ack_refuses_another_sequence
test_list_enumerates_the_pending_steers
test_list_bounds_the_steers_it_describes
test_inbox_does_not_touch_task_disk_inbox
test_notify_captain_needed_includes_portal_and_hides_token
test_notify_portal_url_cannot_be_suppressed
test_notify_pr_landed_rejects_bare_number
test_notify_archify_requires_a_diagram
test_portal_assign_publishes_its_own_family
test_portal_rejects_non_https
test_send_dual_write_keeps_disk_inbox
test_send_rings_the_doorbell_before_the_dual_write
test_send_dual_write_is_bounded
test_send_dual_write_reports_a_steer_that_did_not_land
test_send_idempotent_resend_republishes_the_mirror
test_send_overlay_opt_in_is_exactly_on
test_send_without_overlay_skips_dual_write
