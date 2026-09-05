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
`bin/fm-carverauto-notify.sh`, `bin/fm-steer.sh`, and `bin/fm-carverauto-portal.sh` own exact flags.
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
Archify uses `archify --title "<title>" --png <path>`; it requires a `--png` or `--html` diagram, and a text-only page is `captain-needed`.

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
printf '%s' "$body" | bin/fm-steer.sh put --stream <name> --task <id> --seq <n>
bin/fm-steer.sh next --stream <name>
bin/fm-steer.sh ack --stream <name> --stream-seq <n>
bin/fm-steer.sh list --stream <name>
```

`next` peeks the durable consumer and leaves the steer pending, reporting the `stream-seq` that identifies it.
`ack` takes that same `--stream-seq` and is what marks that steer handled; it refuses any other sequence rather than handling a steer nobody read.
`list` reports the pending count and then one line per pending steer - `stream-seq`, subject, task, and record seq - without delivering any of them.

`fm-send` dual-writes onto this CLI after a successful on-disk enqueue and after the doorbell rings, when the overlay is on and a stream is configured.
A re-run that deduplicates onto an existing record publishes again, so the JetStream mirror is at-least-once rather than silently missing.
The on-disk inbox under `state/<id>.inbox/` remains the delivery record.
Do not delete those files.
This CLI has no path that removes a task inbox.

JetStream is the only store: the `nats` CLI must be on PATH and be natscli 0.4.0 or newer (older ones expand `{{...}}` in a steer body and are refused).
`put` publishes to JetStream, so it fails rather than reporting a delivery when no stream captured the subject.
`next`, `ack`, and `list` need a durable pull consumer named after the stream (`AckPolicy=explicit`) to exist already; the overlay never creates one.
NATS credentials stay in that CLI's environment (`NATS_USER`, `NATS_PASSWORD`, `NATS_CREDS`); a server URL that embeds them is refused, because the URL rides argv.
A dual-write that cannot reach NATS prints a notice; the on-disk record is still the delivered steer.

## Portal assignment

When a worker is assigned, or a PR or issue URL or BuildBuddy check URL is known, publish the assignment for `https://firstmate.carverauto.dev`:

```sh
bin/fm-carverauto-portal.sh assign --task-id <id> --worker <name> \
  --pr-url https://... --issue-url https://... --buildbuddy-url https://...
```

Task id and worker are required.
Any URL that is supplied must be the full `https://` URL copied from the forge or from BuildBuddy, never a bare number.
An assignment is its own message family on `firstmate.assign.<task-id>`, published by that script, never through `fm-steer`.
It does not touch the on-disk steering inbox.
