#!/usr/bin/env bash
# End-to-end test of tg-gate + svc-update in a throwaway systemd container (Debian, rootful podman, fake
# Telegram API). Needs Docker and both repos side by side:  tests/integration/run.sh [path/to/tg-gate]
# Tests the committed state of both repos (they are cloned inside the container).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SVC=$(cd "$HERE/../.." && pwd)
TGG=$(cd "${1:-$SVC/../tg-gate}" && pwd)
docker build -q -t svc-itest "$HERE" >/dev/null
docker rm -f svc-itest >/dev/null 2>&1 || true
docker run -d --name svc-itest --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run \
  --tmpfs /run/lock -v "$TGG:/src/tg-gate:ro" -v "$SVC:/src/svc-update:ro" -v "$HERE:/itest:ro" svc-itest >/dev/null
trap 'docker rm -f svc-itest >/dev/null' EXIT
sleep 5
docker exec svc-itest bash /itest/run-tests.sh
