#!/usr/bin/env bash
# Behavior tests for the failed-launch custody fix in bin/fm-spawn.sh.
#
# A spawn whose `treehouse get` outlasts the 60s isolation wait exits with no
# worktree, no claim, and no task record, while the pane's allocation can still
# complete late into a slot no record describes. The fix has two halves: the
# deadline abort closes the endpoint it created, and --recover-late-slot
# proves a stranded slot and returns it to the pool.
#
# The fake tmux below is stateful (window list, kill log, scripted pane reads)
# so the tests observe the close and the recovery through the real spawn flow;
# the fake treehouse observes `return --force`. Real git repos back the
# project and pool-slot layout, and the real agent-state classifier reads the
# scripted pane command.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-late-slot)

# make_late_fakebin <case-dir> writes the stateful fake tmux plus the
# observing fake treehouse into <case-dir>/fakebin and echoes it. Per-case
# files driving the fakes: windows (window names, one per line), kills
# (kill-window log), pane_path, pane_command, returns (treehouse return log).
make_late_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    cat "${LATE_CASE:?}/pane_path" 2>/dev/null || true
    exit 0
    ;;
  *"#{pane_current_command}"*)
    cat "${LATE_CASE:?}/pane_command" 2>/dev/null || true
    exit 0
    ;;
  *"#{pane_tty}"*)
    exit 0
    ;;
esac
case "${1:-}" in
  display-message)
    printf '%s\n' "${LATE_SESSION:-firstmate}"
    exit 0
    ;;
  list-windows)
    cat "${LATE_CASE:?}/windows" 2>/dev/null || true
    exit 0
    ;;
  new-window)
    name=""
    prev=""
    for a in "$@"; do
      if [ "$prev" = "-n" ]; then name="$a"; fi
      prev="$a"
    done
    printf '%s\n' "$name" >> "${LATE_CASE:?}/windows"
    printf '@%s\n' "$(wc -l < "${LATE_CASE:?}/windows")"
    exit 0
    ;;
  kill-window)
    printf 'kill-window %s\n' "$*" >> "${LATE_CASE:?}/kills"
    t=""
    prev=""
    for a in "$@"; do
      if [ "$prev" = "-t" ]; then t="$a"; fi
      prev="$a"
    done
    case "$t" in
      @*) ;;
      *)
        w=${t#*:}
        w=${w#=}
        grep -vxF "$w" "${LATE_CASE:?}/windows" > "${LATE_CASE:?}/windows.tmp" || true
        mv -f "${LATE_CASE:?}/windows.tmp" "${LATE_CASE:?}/windows"
        ;;
    esac
    exit 0
    ;;
  send-keys|has-session|new-session|set-window-option) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = return ]; then
  printf 'treehouse %s\n' "$*" >> "${LATE_CASE:?}/returns"
  exit "${LATE_TREEHOUSE_RC:-0}"
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

# make_pool_case <name> <id> builds a home, a project repo, and a pool slot
# holding a linked worktree of that project, with the stranded endpoint window
# pre-seeded. Echoes "case|home|proj|slot".
make_pool_case() {
  local name=$1 id=$2 case_dir home proj pool slot fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  pool="$case_dir/pool"
  slot="$pool/62/repo"
  fakebin=$(make_late_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_git_init_commit "$proj"
  mkdir -p "$pool/62"
  git -C "$proj" worktree add --quiet -b "slot-$name" "$slot"
  : > "$pool/treehouse-state.json"
  fm_test_spawn_brief "$home" "$id" "Exercise late-slot recovery for $id."
  : > "$case_dir/windows"
  printf '%s\n' "fm-$id" >> "$case_dir/windows"
  : > "$case_dir/kills"
  : > "$case_dir/returns"
  printf '%s\n' "$slot" > "$case_dir/pane_path"
  printf 'zsh\n' > "$case_dir/pane_command"
  printf '%s\n' "$case_dir|$home|$proj|$slot|$fakebin"
}

read_pool_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR SLOT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_recovery() {
  local id=$1 endpoint=${2:-"firstmate:fm-$1"}
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    LATE_CASE="$CASE_DIR" LATE_SESSION=firstmate \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --recover-late-slot --endpoint "$endpoint" --backend tmux 2>&1
}

return_calls() {
  grep -c "treehouse return" "$CASE_DIR/returns" 2>/dev/null || true
}

kill_calls() {
  grep -c "kill-window" "$CASE_DIR/kills" 2>/dev/null || true
}

cleanup_task_tmp() {
  rm -rf "/tmp/fm-$1"
}

# The deadline abort closes the endpoint its spawn created, so a `treehouse
# get` still in flight cannot complete late into a slot no record describes.
test_deadline_abort_closes_its_endpoint() {
  local id case_dir home proj fakebin out status
  id=late-abort-close-z1
  case_dir="$TMP_ROOT/$id"
  home="$case_dir/home"
  proj="$case_dir/project"
  fakebin=$(make_late_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_git_init_commit "$proj"
  fm_test_spawn_brief "$home" "$id" "Exercise deadline abort endpoint close for $id."
  : > "$case_dir/windows"
  : > "$case_dir/kills"
  : > "$case_dir/returns"
  printf '%s\n' "$proj" > "$case_dir/pane_path"
  printf 'zsh\n' > "$case_dir/pane_command"
  fm_test_fake_sleep_noop "$fakebin"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    LATE_CASE="$case_dir" LATE_SESSION=firstmate \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" --mode no-mistakes --yolo off 2>&1)
  status=$?
  cleanup_task_tmp "$id"
  [ "$status" -ne 0 ] || fail "spawn accepted a pane that never left the project"$'\n'"$out"
  assert_contains "$out" "did not enter an isolated worktree" \
    "abort did not explain the isolation wait ran out"
  assert_contains "$out" "endpoint was closed" \
    "abort did not report closing its endpoint"
  assert_contains "$(cat "$case_dir/kills")" "fm-$id" \
    "abort did not close the window it created"
  [ ! -e "$home/state/$id.meta" ] && [ ! -L "$home/state/$id.meta" ] || \
    fail "refused spawn published task metadata"
  [ "$(grep -c "treehouse return" "$case_dir/returns" 2>/dev/null || true)" -eq 0 ] || \
    fail "deadline abort returned a slot it never adopted"
  pass "a spawn that outlasts the isolation wait closes its endpoint"
}

# A slot whose allocation completed after its spawn refused it is proven from
# the live endpoint and returned to the pool.
test_recovery_returns_stranded_slot() {
  local rec id out status
  id=late-recover-ok-z2
  rec=$(make_pool_case recover-ok "$id")
  read_pool_record "$rec"

  out=$(run_recovery "$id")
  status=$?
  expect_code 0 "$status" "recovery should return the proven stranded slot"$'\n'"$out"
  assert_contains "$out" "recovered $id slot=$SLOT_DIR" \
    "recovery did not name the returned slot"
  assert_contains "$out" "claim=absent" \
    "recovery did not report the claim evidence"
  [ "$(return_calls)" -eq 1 ] || fail "recovery did not return the slot exactly once"
  assert_contains "$(cat "$CASE_DIR/returns")" "$SLOT_DIR" \
    "treehouse return was not aimed at the stranded slot"
  [ "$(kill_calls)" -eq 1 ] || fail "recovery did not close the stranded endpoint"
  [ ! -e "$HOME_DIR/state/$id.meta" ] && [ ! -L "$HOME_DIR/state/$id.meta" ] || \
    fail "recovery published a task record it must never create"
  pass "a late-allocated slot is proven from its endpoint and returned"
}

# A second run converges: the endpoint is gone, so it reports nothing to do
# instead of returning anything twice.
test_recovery_is_idempotent() {
  local rec id out status
  id=late-recover-idem-z3
  rec=$(make_pool_case recover-idem "$id")
  read_pool_record "$rec"

  out=$(run_recovery "$id")
  expect_code 0 "$?" "first recovery should succeed"$'\n'"$out"
  out=$(run_recovery "$id")
  status=$?
  expect_code 0 "$status" "second recovery should converge instead of acting twice"$'\n'"$out"
  assert_contains "$out" "nothing to return" \
    "second recovery did not report the already-recovered state"
  [ "$(return_calls)" -eq 1 ] || fail "recovery returned the slot more than once across runs"
  pass "recovery re-runs converge without a second return"
}

# An endpoint running an agent is never returned, however idle the slot looks.
test_recovery_refuses_live_agent() {
  local rec id out status
  id=late-recover-alive-z4
  rec=$(make_pool_case recover-alive "$id")
  read_pool_record "$rec"
  printf 'claude\n' > "$CASE_DIR/pane_command"

  out=$(run_recovery "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "recovery returned a slot whose endpoint runs an agent"$'\n'"$out"
  assert_contains "$out" "'alive'" \
    "refusal did not name the agent verdict"
  [ "$(return_calls)" -eq 0 ] || fail "refused recovery returned the slot"
  [ "$(kill_calls)" -eq 0 ] || fail "refused recovery closed the endpoint"
  pass "an endpoint running an agent refuses recovery"
}

# An endpoint the classifier cannot settle is refused rather than guessed past.
test_recovery_refuses_ambiguous_pane() {
  local rec id out status
  id=late-recover-ambig-z5
  rec=$(make_pool_case recover-ambig "$id")
  read_pool_record "$rec"
  printf 'node\n' > "$CASE_DIR/pane_command"

  out=$(run_recovery "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "recovery returned a slot from an ambiguous endpoint"$'\n'"$out"
  assert_contains "$out" "'ambiguous'" \
    "refusal did not name the ambiguous verdict"
  [ "$(return_calls)" -eq 0 ] || fail "refused recovery returned the slot"
  pass "an ambiguous endpoint refuses recovery"
}

# A slot claimed by another task is left untouched.
test_recovery_refuses_other_claim() {
  local rec id out status marker
  id=late-recover-claim-z6
  rec=$(make_pool_case recover-claim "$id")
  read_pool_record "$rec"
  marker="$(dirname "$SLOT_DIR")/.fm-slot-owner"
  {
    printf 'task=%s\n' "some-other-task"
    printf 'home=%s\n' "$HOME_DIR"
  } > "$marker"

  out=$(run_recovery "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "recovery returned a slot claimed by another task"$'\n'"$out"
  assert_contains "$out" "some-other-task" \
    "refusal did not name the owning task"
  [ "$(return_calls)" -eq 0 ] || fail "refused recovery returned the slot"
  [ -f "$marker" ] || fail "refused recovery removed another task's claim"
  pass "a slot claimed by another task is left untouched"
}

# Unlanded work is preserved: a dirty slot refuses instead of being reset.
test_recovery_refuses_dirty_slot() {
  local rec id out status
  id=late-recover-dirty-z7
  rec=$(make_pool_case recover-dirty "$id")
  read_pool_record "$rec"
  printf 'precious\n' > "$SLOT_DIR/UNLANDED.txt"

  out=$(run_recovery "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "recovery returned a slot holding unlanded work"$'\n'"$out"
  assert_contains "$out" "unlanded work" \
    "refusal did not say the work is preserved"
  [ "$(return_calls)" -eq 0 ] || fail "refused recovery returned the slot"
  [ -f "$SLOT_DIR/UNLANDED.txt" ] || fail "refused recovery removed the unlanded work"
  [ "$(cat "$SLOT_DIR/UNLANDED.txt")" = "precious" ] || fail "refused recovery altered the unlanded work"
  pass "a dirty slot refuses recovery and keeps its work"
}

# A task that already has a record belongs to relaunch/teardown, never here.
test_recovery_refuses_existing_record() {
  local rec id out status
  id=late-recover-meta-z8
  rec=$(make_pool_case recover-meta "$id")
  read_pool_record "$rec"
  printf 'window=%s\n' "firstmate:fm-$id" > "$HOME_DIR/state/$id.meta"

  out=$(run_recovery "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "recovery acted for a task that already has a record"$'\n'"$out"
  assert_contains "$out" "already has a record" \
    "refusal did not point at the existing record"
  [ "$(return_calls)" -eq 0 ] || fail "refused recovery returned the slot"
  pass "an existing task record refuses recovery"
}

# A pane sitting outside any pool slot refuses: only treehouse-owned copies go back.
test_recovery_refuses_non_pool_path() {
  local rec id out status other
  id=late-recover-nonpool-z9
  rec=$(make_pool_case recover-nonpool "$id")
  read_pool_record "$rec"
  other="$TMP_ROOT/recover-nonpool/other-checkout"
  fm_git_init_commit "$other"
  printf '%s\n' "$other" > "$CASE_DIR/pane_path"

  out=$(run_recovery "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "recovery returned a copy treehouse does not own"$'\n'"$out"
  assert_contains "$out" "not a Treehouse pool slot" \
    "refusal did not name the pool ownership proof"
  [ "$(return_calls)" -eq 0 ] || fail "refused recovery returned the slot"
  pass "a non-pool copy refuses recovery"
}

# A pane still in the project refuses through the same isolation predicate.
test_recovery_refuses_project_path() {
  local rec id out status
  id=late-recover-proj-z10
  rec=$(make_pool_case recover-proj "$id")
  read_pool_record "$rec"
  printf '%s\n' "$PROJ_DIR" > "$CASE_DIR/pane_path"

  out=$(run_recovery "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "recovery returned the spawning project itself"$'\n'"$out"
  [ "$(return_calls)" -eq 0 ] || fail "refused recovery returned the slot"
  pass "the spawning project itself refuses recovery"
}

# Contradicting flags, missing required handles, and foreign window names all
# refuse before any proof runs.
test_recovery_refuses_contradictions() {
  local rec id out status
  id=late-recover-contra-z11
  rec=$(make_pool_case recover-contra "$id")
  read_pool_record "$rec"
  recover_base() {
    FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
      FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
      FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
      FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
      LATE_CASE="$CASE_DIR" LATE_SESSION=firstmate \
      PATH="$FAKEBIN_DIR:$PATH" \
      "$SPAWN" "$@" 2>&1
  }

  out=$(recover_base "$id" "$PROJ_DIR" --recover-late-slot --endpoint "firstmate:fm-$id" --backend tmux --relaunch)
  [ "$?" -ne 0 ] || fail "recovery accepted --relaunch"$'\n'"$out"
  assert_contains "$out" "--relaunch" "relaunch contradiction was not named"

  out=$(recover_base "$id" "$PROJ_DIR" --recover-late-slot --endpoint "firstmate:fm-$id")
  [ "$?" -ne 0 ] || fail "recovery accepted a missing --backend"$'\n'"$out"
  assert_contains "$out" "--backend" "backend requirement was not named"

  out=$(recover_base "$id" "$PROJ_DIR" --recover-late-slot --backend tmux)
  [ "$?" -ne 0 ] || fail "recovery accepted a missing --endpoint"$'\n'"$out"
  assert_contains "$out" "--endpoint" "endpoint requirement was not named"

  out=$(recover_base "$id" "$PROJ_DIR" --recover-late-slot --endpoint "firstmate:fm-$id" --backend tmux --mode direct-PR)
  [ "$?" -ne 0 ] || fail "recovery accepted a launch flag"$'\n'"$out"
  assert_contains "$out" "launches nothing" "launch-flag contradiction was not named"

  out=$(recover_base "$id" "$PROJ_DIR" --recover-late-slot --endpoint "firstmate:fm-$id" --backend orca)
  [ "$?" -ne 0 ] || fail "recovery accepted a backend with no agent-state classifier"$'\n'"$out"

  out=$(recover_base "$id" "$PROJ_DIR" --recover-late-slot --endpoint "nocolon" --backend tmux)
  [ "$?" -ne 0 ] || fail "recovery accepted an ambiguous endpoint"$'\n'"$out"
  assert_contains "$out" "ambiguous endpoint" "endpoint ambiguity was not named"

  printf '%s\n' "other-window" >> "$CASE_DIR/windows"
  out=$(recover_base "$id" "$PROJ_DIR" --recover-late-slot --endpoint "firstmate:other-window" --backend tmux)
  [ "$?" -ne 0 ] || fail "recovery accepted a foreign window name"$'\n'"$out"
  assert_contains "$out" "fm-$id" "window binding refusal did not name this task's window"

  out=$(recover_base "$id=proj" --recover-late-slot --endpoint "firstmate:fm-$id" --backend tmux)
  [ "$?" -ne 0 ] || fail "recovery accepted batch dispatch"$'\n'"$out"

  [ "$(return_calls)" -eq 0 ] || fail "a contradiction refusal returned the slot"
  [ "$(kill_calls)" -eq 0 ] || fail "a contradiction refusal closed the endpoint"
  pass "contradictions refuse before any proof runs"
}

# An endpoint that is already gone converges to a no-op success.
test_recovery_missing_endpoint_noop() {
  local rec id out status
  id=late-recover-gone-z12
  rec=$(make_pool_case recover-gone "$id")
  read_pool_record "$rec"
  : > "$CASE_DIR/windows"

  out=$(run_recovery "$id")
  status=$?
  expect_code 0 "$status" "gone endpoint should converge to nothing-to-do"$'\n'"$out"
  assert_contains "$out" "nothing to return" \
    "no-op did not report the already-recovered state"
  [ "$(return_calls)" -eq 0 ] || fail "no-op recovery returned a slot"
  pass "an already-gone endpoint converges without acting"
}

test_deadline_abort_closes_its_endpoint
test_recovery_returns_stranded_slot
test_recovery_is_idempotent
test_recovery_refuses_live_agent
test_recovery_refuses_ambiguous_pane
test_recovery_refuses_other_claim
test_recovery_refuses_dirty_slot
test_recovery_refuses_existing_record
test_recovery_refuses_non_pool_path
test_recovery_refuses_project_path
test_recovery_refuses_contradictions
test_recovery_missing_endpoint_noop

echo "# all fm-spawn-late-slot tests passed"
