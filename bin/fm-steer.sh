#!/usr/bin/env bash
# fm-steer - OpenSpec add-firstmate-portal steering-inbox CLI.
#
# Usage: fm-steer.sh put|next|ack|list --stream <name> ...
# This is the contract name firstmate-notify's portal change owns.
# bin/fm-carverauto-inbox.sh is this fork's implementation; read that header
# for flags, payload schema=fm-task-inbox.v1, subject firstmate.steer.<task>,
# ack=handled, list=pending, and the rule that the on-disk inbox is never
# deleted.
set -euo pipefail
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-carverauto-inbox.sh" "$@"
