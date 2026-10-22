# svc-update

Approve-then-automate updates for containers you run with Docker Compose or Podman Compose.

Images stay pinned by **tag and digest** in your compose files (`image: app:v1.2.3@sha256:…`), which is good
for supply-chain safety but makes every update a chore. svc-update keeps the pinning and your approval, and
does the rest: once a day it sends one Telegram message with an **[Update]** / **[Skip]** button per service,
and a tap runs the backup hook, pulls the exact digest, repins the compose file, restarts the service, checks
that it is healthy and reports the new version, and rolls back automatically if it is not.

Telegram goes through [tg-gate](https://github.com/ycanerol/tg-gate) (svc-update registers as its plugin).
Without tg-gate, svc-update still works from the command line and only logs.

## Install

Requirements: Linux with systemd, `/usr/bin/python3` 3.11+, git, and Docker with Compose v2 or Podman 4.7+
with a compose provider. Install tg-gate first if you want Telegram.

```sh
sudo git clone https://github.com/ycanerol/svc-update /opt/svc-update
sudo /opt/svc-update/install.sh --run-as alice --check-time 11:30   # default: root, 11:30
```

`--run-as` is the user that runs checks and updates; it needs access to docker or podman. The installer sets
up `svc-update-check.timer`, registers the tg-gate plugin (buttons, `/status`, `/check`) when tg-gate is
installed, and remembers its options in `/etc/svc-update/install.env`.

Update later with `sudo svc-update self-update`: it shows the new commits, asks, checks that the new code
compiles, waits until no update is running, fast-forwards and re-runs `install.sh`. Nothing updates itself;
with tg-gate installed, its hourly update check tells you once a new commit has been on GitHub for 12 h.

**Rootless Podman:** run `loginctl enable-linger alice` and, as alice,
`systemctl --user enable podman-restart.service`, or containers will not come back after a reboot.

## Add a service

Copy [`examples/service.toml`](examples/service.toml) to `<config>/services/<name>.toml` (root:
`/etc/svc-update/services/`, other users: `~/.config/svc-update/services/`), pin the image once by hand, then:

```
$ svc-update status
app                v1.10.4@1f0e3a9c2b7d          -> 1.12.0
```

Sources:
- `github`: the newest stable GitHub release that is at least `min_age_days` (default 3) old; the image tag
  comes from `tag_format` (e.g. `v{version}-slim`).
- `registry-digest`: the pinned tag (`latest`, `18`, `9-alpine`…) moved to a new image on ghcr.io, lscr.io or
  Docker Hub; offered once this host has seen the new digest for `min_age_days`.

Optional `<config>/svc-update.toml`: `engine = "podman"` (default: docker if installed, else podman).

## Commands

```
svc-update check [--reoffer]        what the timer runs; --reoffer offers again what was already offered
svc-update status                   running vs available, including releases still inside the age gate
svc-update apply NAME [-y]          update now (asks y/N)
svc-update apply NAME --force       also offer releases younger than min_age_days: numbered list, Enter cancels
svc-update apply NAME --force --version 1.2.3 [-y]
svc-update process-requests         run queued button presses / commands (started by tg-gate)
svc-update test-telegram
sudo svc-update self-update [-y]
```

In Telegram: the buttons, `/status` and `/check`.

## Guardrails

- Stable releases only (no drafts or pre-releases), at least `min_age_days` old. `--force` skips only this
  age gate, and only at the command line: it is never reachable from Telegram, it logs the release's age
  and it sends a ⚠️ notice.
- The offer is anchored to the registry digest at check time, and apply pulls exactly `image@digest`: a tag
  re-pushed after the offer is refused.
- No downgrades: anything not newer than what runs is refused, so stale buttons can't move a service back.
- A new offer withdraws older buttons for that service; each button works once, for 7 days, for exactly the
  offered version. Requests older than an hour are ignored.
- One update at a time (lock). SIGTERM is deferred until an update has finished or rolled back; an update
  that was killed anyway (OOM, power loss) is reported on the next run.
- Failure before the switch (hook, pull, digest, compose validation) changes nothing. Failure after it
  restores the compose file, runs your rollback hook and starts the old image.

## Files

| root | other users | What |
|---|---|---|
| `/etc/svc-update/services/*.toml` | `~/.config/svc-update/services/*.toml` | one file per service |
| `/var/lib/svc-update/` | `~/.local/state/svc-update/` | `state.json`, `svc-update.log`, one log per update in `runs/` |

Compose backups are written next to each compose file as `*.bak-svc-update-<time>`.
Tests: `python3 -m unittest discover -s tests`; end to end (Docker, with tg-gate cloned next to this repo): `tests/integration/run.sh`.
