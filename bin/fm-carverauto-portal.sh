#!/usr/bin/env bash
# Publish a fleet-portal assignment onto JetStream for firstmate.carverauto.dev.
#
# Usage:
#   fm-carverauto-portal.sh assign --stream <name> --task-id <id> --worker <name> \
#     [--pr-url <https-url>] [--issue-url <https-url>] [--buildbuddy-url <https-url>] \
#     [--subject <subject>]
#
# --stream is required. Task id and worker are required. Any URL that is
# supplied must be a full https URL (PR, issue, or BuildBuddy check).
# The payload is JSON schema fm-carverauto-portal-assign.v1 and is published
# through bin/fm-carverauto-inbox.sh put, so the on-disk steering inbox is
# never touched.
#
# Default subject: firstmate.portal.assign
# Default portal_url: https://firstmate.carverauto.dev
# bin/fm-carverauto-lib.sh owns overlay opt-in and URL resolution.
# The carverauto-overlay skill owns when firstmate must publish.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-carverauto-lib.sh
. "$SCRIPT_DIR/fm-carverauto-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 2; }

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
TASK_ID=
WORKER=
PR_URL=
ISSUE_URL=
BB_URL=
SUBJECT=firstmate.portal.assign

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help|help) usage ;;
    assign)
      [ -z "$CMD" ] || die "multiple commands"
      CMD=$1
      shift
      ;;
    --stream)
      [ -n "${2-}" ] || die "--stream needs a name"
      STREAM=$2
      shift 2
      ;;
    --task-id)
      [ -n "${2-}" ] || die "--task-id needs a value"
      TASK_ID=$2
      shift 2
      ;;
    --worker)
      [ -n "${2-}" ] || die "--worker needs a value"
      WORKER=$2
      shift 2
      ;;
    --pr-url)
      [ -n "${2-}" ] || die "--pr-url needs a value"
      PR_URL=$2
      shift 2
      ;;
    --issue-url)
      [ -n "${2-}" ] || die "--issue-url needs a value"
      ISSUE_URL=$2
      shift 2
      ;;
    --buildbuddy-url)
      [ -n "${2-}" ] || die "--buildbuddy-url needs a value"
      BB_URL=$2
      shift 2
      ;;
    --subject)
      [ -n "${2-}" ] || die "--subject needs a value"
      SUBJECT=$2
      shift 2
      ;;
    --) shift; break ;;
    -*) die "unknown option: $1" ;;
    *) die "unexpected argument: $1" ;;
  esac
done

[ "$CMD" = assign ] || die "command required: assign"
[ -n "$STREAM" ] || die "--stream is required"
[ -n "$TASK_ID" ] || die "--task-id is required"
[ -n "$WORKER" ] || die "--worker is required"

require_https_opt() {
  local url=$1 flag=$2
  [ -n "$url" ] || return 0
  fm_carverauto_require_https "$url" || die "$flag must be a full https URL"
}

require_https_opt "$PR_URL" --pr-url
require_https_opt "$ISSUE_URL" --issue-url
require_https_opt "$BB_URL" --buildbuddy-url
command -v python3 >/dev/null 2>&1 || die "python3 is required to encode the assignment"

PORTAL=$(fm_carverauto_portal_url)
AT=$(fm_carverauto_now)
PAYLOAD=$(python3 - "$TASK_ID" "$WORKER" "$PR_URL" "$ISSUE_URL" "$BB_URL" "$PORTAL" "$AT" <<'PY'
import json, sys
task, worker, pr, issue, bb, portal, at = sys.argv[1:8]

def opt(v):
    return v if v else None

print(json.dumps({
    "schema": "fm-carverauto-portal-assign.v1",
    "task_id": task,
    "worker": worker,
    "pr_url": opt(pr),
    "issue_url": opt(issue),
    "buildbuddy_url": opt(bb),
    "portal_url": portal,
    "at": at,
}, separators=(",", ":")))
PY
)

printf '%s' "$PAYLOAD" | "$SCRIPT_DIR/fm-carverauto-inbox.sh" put \
  --stream "$STREAM" \
  --subject "$SUBJECT" \
  --schema "$FM_CARVERAUTO_PORTAL_SCHEMA" \
  --task "$TASK_ID"
