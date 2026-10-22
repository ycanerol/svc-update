#!/usr/bin/env bash
# Install or refresh svc-update from this clone (idempotent; `svc-update self-update` runs it after every pull).
#   sudo ./install.sh [--run-as USER] [--check-time HH:MM]
# --run-as: the user that runs checks and updates (default root; must be able to use docker/podman).
# Both options are remembered in /etc/svc-update/install.env. See README.md.
set -euo pipefail
PREFIX=$(cd "$(dirname "$0")" && pwd -P)
UNITS=/etc/systemd/system
ENV_FILE=/etc/svc-update/install.env
say() { printf '  %-4s %s\n' "$1" "$2"; }
die() { echo "install.sh: $*" >&2; exit 1; }

RUN_AS=root CHECK_TIME=11:30
[ ! -f "$ENV_FILE" ] || . <(grep -E '^(RUN_AS|CHECK_TIME)=[A-Za-z0-9_.:-]+$' "$ENV_FILE")
while [ $# -gt 0 ]; do
  case "$1" in
    --run-as) RUN_AS=$2; shift 2 ;;
    --check-time) CHECK_TIME=$2; shift 2 ;;
    *) die "unknown option $1" ;;
  esac
done

[ "$(id -u)" = 0 ] || die "run as root: sudo $0"
command -v systemctl >/dev/null || die "systemd is required"
[ -x /usr/bin/python3 ] || die "/usr/bin/python3 is required"
/usr/bin/python3 -c 'import sys; sys.exit(sys.version_info < (3, 11))' || die "python >= 3.11 is required (tomllib)"
[[ "$CHECK_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || die "--check-time must be HH:MM"
getent passwd "$RUN_AS" >/dev/null || die "no such user: $RUN_AS"
bad=$(find "$PREFIX" ! -type l \( ! -user root -o -perm /022 \) -print -quit)
[ -z "$bad" ] || die "$PREFIX must be owned by root and not group/world writable (first offender: $bad)"

echo "svc-update install (commit $(git -C "$PREFIX" rev-parse --short HEAD 2>/dev/null || echo '?'), run as $RUN_AS, check $CHECK_TIME)"

# container engine, as svc-update will pick it
as_user() { if [ "$RUN_AS" = root ]; then "$@"; else runuser -u "$RUN_AS" -- "$@"; fi; }
HOME_DIR=$(getent passwd "$RUN_AS" | cut -d: -f6)
if [ "$RUN_AS" = root ]; then CONF=/etc/svc-update; STATE=/var/lib/svc-update
else CONF=$HOME_DIR/.config/svc-update; STATE=$HOME_DIR/.local/state/svc-update; fi
ENGINE=$(sed -n 's/^engine *= *"\(docker\|podman\)".*/\1/p' "$CONF/svc-update.toml" 2>/dev/null || true)
[ -n "$ENGINE" ] || ENGINE=$(command -v docker >/dev/null && echo docker || { command -v podman >/dev/null && echo podman; } || true)
[ -n "$ENGINE" ] || die "neither docker nor podman found"
if as_user "$ENGINE" compose version >/dev/null 2>&1; then
  say ok "engine: $ENGINE ($(as_user "$ENGINE" compose version 2>/dev/null | head -1))"
else
  say '!!' "engine: $ENGINE, but '$ENGINE compose version' fails as $RUN_AS (compose missing or no access)"
fi
if [ "$ENGINE" = podman ] && [ "$RUN_AS" != root ]; then
  [ "$(loginctl show-user "$RUN_AS" -p Linger --value 2>/dev/null)" = yes ] ||
    say '!!' "rootless podman: containers stop at logout/reboot without  loginctl enable-linger $RUN_AS"
  say '!!' "rootless podman: containers restart after a reboot only with  systemctl --user enable podman-restart.service  (as $RUN_AS)"
fi

# config and state (never overwritten)
OWNER=$RUN_AS:$(id -gn "$RUN_AS")
for d in "$CONF" "$CONF/services" "$STATE"; do
  [ -d "$d" ] || { install -d -m 0700 -o "${OWNER%%:*}" -g "${OWNER##*:}" "$d"; say new "$d"; }
done
install -d -m 0755 /etc/svc-update
printf 'RUN_AS=%s\nCHECK_TIME=%s\n' "$RUN_AS" "$CHECK_TIME" > "$ENV_FILE"

if [ "$(readlink /usr/local/bin/svc-update 2>/dev/null)" != "$PREFIX/svc-update" ]; then
  ln -sfn "$PREFIX/svc-update" /usr/local/bin/svc-update; say new "/usr/local/bin/svc-update -> $PREFIX/svc-update"
fi

for f in "$PREFIX"/systemd/*; do
  dst="$UNITS/$(basename "$f")"
  new=$(sed -e "s|@PREFIX@|$PREFIX|g" -e "s|@RUN_AS@|$RUN_AS|g" -e "s|@CHECK_TIME@|$CHECK_TIME|g" "$f")
  if [ ! -f "$dst" ] || [ "$new" != "$(cat "$dst")" ]; then
    printf '%s\n' "$new" > "$dst"; say unit "$(basename "$f")"
  fi
done
systemctl daemon-reload
systemctl enable --quiet --now svc-update-check.timer

# Telegram: register as a tg-gate plugin when tg-gate is installed
if [ -d /etc/tg-gate/plugins.d ] && command -v tg-gate >/dev/null; then
  [ "$(tg-gate --protocol)" = 1 ] || die "tg-gate protocol $(tg-gate --protocol) is not supported (need 1): update one of them"
  AFTER='[]'; [ "$ENGINE" = docker ] && AFTER='["docker.service"]'
  cat > /etc/tg-gate/plugins.d/svc-update.toml <<EOF
# Written by svc-update's install.sh. Buttons: u = update, s = skip.
name = "svc-update"
user = "$RUN_AS"
exec = "/usr/local/bin/svc-update process-requests"
verbs = ["u", "s"]
timeout = "3h"
after = $AFTER

[commands]
status = "running vs available versions"
check = "check for updates now"
EOF
  say ok "tg-gate plugin svc-update registered (user $RUN_AS)"
  # tg-gate's hourly update-check tells you once when this clone is 12 h behind GitHub (tg-gate >= update-check)
  if [ -d /etc/tg-gate/updates.d ]; then
    cat > /etc/tg-gate/updates.d/svc-update.toml <<EOF
# Written by svc-update's install.sh, read by tg-gate update-check.
repo = "$PREFIX"
command = "sudo svc-update self-update"
EOF
    say ok "update notices: registered with tg-gate update-check"
  fi
  tg-gate sync
  [ "$RUN_AS" = root ] || id -nG "$RUN_AS" | grep -qw tg-notify ||
    { usermod -aG tg-notify "$RUN_AS"; say new "$RUN_AS added to group tg-notify"; }
else
  say '!!' "tg-gate not installed: no Telegram messages, svc-update only logs (install tg-gate, then re-run this)"
fi
say ok "done. Service template: $PREFIX/examples/service.toml -> $CONF/services/<name>.toml, then: svc-update status"
