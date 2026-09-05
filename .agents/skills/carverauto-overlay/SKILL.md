---
name: carverauto-overlay
description: >-
  Agent-only procedure for this fork's Carverauto overlay: Discord captain-attention
  pages, the JetStream steering-inbox CLI that fm-send can dual-write to, and
  portal assignment publishes for firstmate.carverauto.dev.
  Load before paging Discord for captain attention, dual-writing a steer onto
  the Carverauto JetStream inbox, or publishing a portal assignment.
user-invocable: false
metadata:
  internal: true
---

# carverauto-overlay

This is this fork's operator overlay for Carverauto.
It is not upstream firstmate.
`bin/fm-carverauto-notify.sh`, `bin/fm-carverauto-inbox.sh`, and `bin/fm-carverauto-portal.sh` own exact flags.
[`docs/configuration.md`](../../../docs/configuration.md#carverauto-overlay) owns opt-in files and environment.

Do not put a Discord webhook, bot token, NATS password, or `GITHUB_TOKEN` in git, in this skill, or in chat.

## Discord captain attention

Every message that would reach the captain in chat also goes to Discord.

Call:

```sh
bin/fm-carverauto-notify.sh captain-needed --title "<headline>" --body "<captain-facing context>"
```

Use that for decisions, blockers, credentials, no-mistakes gates that need the captain, landed PRs, Archify, and low-disk alerts.
The wrapper appends the fleet portal URL (`https://firstmate.carverauto.dev` by default) so Discord gets a live link rather than an HTML attachment.
Landed PRs use `pr-landed --url <https-url> --outcome "<one line>"`.
Archify uses `archify --title "<title>"` (optional `--png`); do not send HTML as the Discord body.

`notify.py` stays in firstmate-notify.
This wrapper never reads or prints the webhook.

A Discord page does not replace chat.
It is the same captain-attention moment, on a channel the captain will actually see.

## JetStream steering inbox

The CLI contract is `fm-steer put|next|ack|list`.
`--stream` is required on every command.
Subjects are `firstmate.steer.<task>`.
`ack` is handled; `list` is pending.
The payload is `schema=fm-task-inbox.v1` with `at`, `task`, `seq`, `body`, and optional `fire-and-forget`.
Do not invent a different subject or schema.

```sh
printf '%s' "$body" | bin/fm-steer.sh put --stream <name> --task <id>
bin/fm-steer.sh next --stream <name>
bin/fm-steer.sh ack --stream <name> --ack <ack-id>
bin/fm-steer.sh list --stream <name>
```

`fm-send` dual-writes onto this CLI after a successful on-disk enqueue when the overlay is on and a stream is configured.
The on-disk inbox under `state/<id>.inbox/` remains the delivery record.
Do not delete those files.
This CLI has no path that removes a task inbox.

File-backed rehearsal is the default without a NATS URL.
NATS credentials stay in the environment for the `nats` CLI.

## Portal assignment

When a worker is assigned, or a PR or issue URL or BuildBuddy check URL is known, publish the assignment for `https://firstmate.carverauto.dev`:

```sh
bin/fm-carverauto-portal.sh assign --stream <name> --task-id <id> --worker <name> \
  --pr-url https://... --issue-url https://... --buildbuddy-url https://...
```

Task id and worker are required.
Any URL that is supplied must be the full `https://` URL copied from the forge or from BuildBuddy, never a bare number.
The publish rides the inbox CLI and does not touch the on-disk steering inbox.
