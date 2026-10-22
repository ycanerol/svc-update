#!/usr/bin/env bash
# Integration test inside a throwaway systemd container: tg-gate + svc-update (podman), fake Telegram.
set -uo pipefail
export TG_GATE_API=http://127.0.0.1:8081
CHAT=5550001 STRANGER=5550999 T=/srv/faketg
D_OLD=sha256:1699d99cb4b9acc17f74ca670b3d8d0b7ba27c948b3445f0593b58ebece92f04   # whoami v1.10.4
PASS=0 FAIL=0 UID_N=1
ok()   { PASS=$((PASS+1)); echo "PASS  $*"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL  $*"; }
step() { echo; echo "=== $*"; }
check() { local d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
sent_has() { python3 -c "import json,sys; sys.exit(not any(sys.argv[1] in json.loads(l).get('visible','') for l in open('$T/sendMessage.jsonl')))" "$1" 2>/dev/null; }
wait_sent() {  # wait_sent DESC TEXT [SECONDS]
  local i; for i in $(seq "${3:-60}"); do sent_has "$2" && { ok "$1"; return 0; }; sleep 1; done
  bad "$1 (no message containing: $2)"; return 1
}
not_sent_after() { sleep "${3:-4}"; if sent_has "$2"; then bad "$1"; else ok "$1"; fi; }
inject() { UID_N=$((UID_N+1)); printf '%s' "$1" | python3 -c "import json,sys; u=json.load(sys.stdin); u['update_id']=$UID_N; json.dump(u, open('$T/inject/%06d.json' % $UID_N, 'w'))"; }
press()  { inject "{\"callback_query\": {\"id\": \"cb$UID_N\", \"data\": \"$1\", \"from\": {\"id\": ${2:-$CHAT}}, \"message\": {\"chat\": {\"id\": ${2:-$CHAT}}}}}"; }
say_cmd(){ inject "{\"message\": {\"text\": \"$1\", \"from\": {\"id\": $CHAT}, \"chat\": {\"id\": $CHAT, \"type\": \"private\"}}}"; }
last_token() { python3 -c "
import json; t=None
for l in open('$T/sendMessage.jsonl'):
    m=json.loads(l)
    for row in m.get('reply_markup',{}).get('inline_keyboard',[]):
        for b in row:
            if b['callback_data'].startswith('svc-update:u:'): t=b['callback_data']
print(t)"; }

step "setup: fake Telegram, git origins, users"
install -m 755 /itest/fake-telegram.py /usr/local/bin/fake-telegram
printf '[Service]\nExecStart=/usr/local/bin/fake-telegram\n' > /etc/systemd/system/fake-tg.service
systemctl daemon-reload && systemctl start fake-tg && sleep 1
git config --global --add safe.directory '*'; git config --global user.email t@example.com; git config --global user.name t
mkdir -p /srv/origin
for r in tg-gate svc-update; do
  git clone -q --bare /src/$r /srv/origin/$r.git && git clone -q /srv/origin/$r.git /opt/$r
done
useradd -m alice
systemctl enable --now podman.socket >/dev/null 2>&1

step "tg-gate install (before setup)"
out=$(/opt/tg-gate/install.sh 2>&1); echo "$out"
check "install says to run setup" grep -q "run  sudo tg-gate setup" <<<"$out"
check "outbox is 1730 tg-gate:tg-notify" test "$(stat -c '%a %U:%G' /var/spool/tg-gate/out)" = "1730 tg-gate:tg-notify"
check "tg-notify symlink" test "$(readlink /usr/local/bin/tg-notify)" = /opt/tg-gate/tg-gate
mkdir -p /etc/systemd/system/tg-gate.service.d
printf '[Service]\nEnvironment=TG_GATE_API=http://127.0.0.1:8081\n' > /etc/systemd/system/tg-gate.service.d/test.conf
systemctl daemon-reload
usermod -aG tg-notify alice

step "tg-gate setup"
printf '123456:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\ny\n' | tg-gate setup --chat-id $CHAT 2>&1 | grep -v GetPassWarning
check "creds root 600" test "$(stat -c '%a %U' /etc/tg-gate/telegram)" = "600 root"
# Docker Desktop's VM kernel can't do systemd's LoadCredential (works on the real hosts): test-only stand-in
install -d -o tg-gate -m 0700 /etc/tg-gate-test && install -o tg-gate -m 0600 /etc/tg-gate/telegram /etc/tg-gate-test/telegram
printf '[Service]\nEnvironment=TG_GATE_API=http://127.0.0.1:8081\nLoadCredential=\nEnvironment=CREDENTIALS_DIRECTORY=/etc/tg-gate-test\n' > /etc/systemd/system/tg-gate.service.d/test.conf
systemctl daemon-reload && systemctl restart tg-gate && sleep 2
check "tg-gate.service active" systemctl is-active --quiet tg-gate
wait_sent "setup test message" "setup done on"
sleep 3; tg-gate status
check "polling off without plugins" bash -c "tg-gate status | grep -q 'polling off'"

step "tg-notify: labels, levels, dedup, ownership"
tg-notify --tool t1 "from root"
runuser -u alice -- tg-notify --tool t1 --level alert "from alice"
for i in 1 2 3; do runuser -u alice -- tg-notify --tool disk --key sdb --quiet 1h "disk gone $i"; done
wait_sent "root label [t1]" "[t1] from root"
wait_sent "non-root label [t1@alice] + alert" "🚨 [t1@alice] from alice"
wait_sent "first of a dedup key" "disk gone 1"
not_sent_after "repeats with the same key dropped" "disk gone 2"
runuser -u nobody -- tg-notify "from nobody" >/dev/null 2>&1
check "non-member cannot queue" bash -c "! runuser -u nobody -- tg-notify x 2>/dev/null"

step "formatting and silent bursts"
sleep 125   # let earlier sends leave the 2-minute window
tg-notify --tool fmt 'run `svc-update apply x` <now> & check
```
a < b
```'
for i in 1 2 3 4; do tg-notify --tool burst "burst $i"; done
wait_sent "4th burst message sent" "burst 4"
check "sent as HTML with code/pre and escaping" bash -c "grep -F 'run <code>svc-update apply x</code> &lt;now&gt; &amp; check' $T/sendMessage.jsonl | grep -q '<pre>a &lt; b</pre>' && grep -F 'burst 1' $T/sendMessage.jsonl | grep -q '\"parse_mode\": \"HTML\"'"
check "first 3 in 2 min notify, 4th and 5th are silent" python3 -c "
import json
ms=[json.loads(l) for l in open('$T/sendMessage.jsonl')]
fl=[m.get('disable_notification')=='true' for m in ms if m['visible'].startswith(('[fmt]','[burst]'))]
assert fl==[False,False,False,True,True], fl"
runuser -u alice -- tg-notify --silent --tool quiet "explicitly silent"
wait_sent "--silent message sent" "explicitly silent"
check "--silent sets disable_notification" bash -c "grep -F 'explicitly silent' $T/sendMessage.jsonl | grep -q '\"disable_notification\": \"true\"'"

step "outbox attacks"
runuser -u alice -- ln -s /etc/tg-gate/telegram /var/spool/tg-gate/out/evil.json
runuser -u alice -- bash -c 'echo "{\"v\":1,\"tool\":\"x\",\"text\":\"big\"}" > /tmp/a.json; ln /etc/passwd /var/spool/tg-gate/out/hard.json' 2>/dev/null
sleep 4
check "symlinked token never sent" bash -c "! grep -q AAAAAAAAAAAAAAAA $T/sendMessage.jsonl"
check "symlink rejected and removed" bash -c "journalctl -u tg-gate --no-pager | grep -q 'rejected evil.json' && ! test -e /var/spool/tg-gate/out/evil.json"
check "alice cannot list the outbox" bash -c "! runuser -u alice -- ls /var/spool/tg-gate/out"

step "svc-update install (root, podman auto-detected)"
mkdir -p /srv/whoami && cat > /srv/whoami/compose.yml <<EOF
services:
  whoami:
    image: traefik/whoami:v1.10.4@$D_OLD
    ports: ["8080:80"]
EOF
out=$(/opt/svc-update/install.sh 2>&1); echo "$out"
check "engine podman detected" grep -q "engine: podman" <<<"$out"
check "plugin registered, polling on" bash -c "tg-gate status | grep -q 'polling on' && tg-gate status | grep -q 'plugin svc-update'"
check "path unit active" systemctl is-active --quiet tg-gate-plugin@svc-update.path
check "check timer enabled" systemctl is-enabled --quiet svc-update-check.timer
check "inbox owned tg-gate:root 2770" test "$(stat -c '%a %U:%G' /var/spool/tg-gate/in/svc-update)" = "2770 tg-gate:root"
cat > /etc/svc-update/services/whoami.toml <<'EOF'
name = "whoami"
compose_dir = "/srv/whoami"
compose_service = "whoami"
image = "traefik/whoami"
tag_format = "v{version}"
[source]
type = "github"
repo = "traefik/whoami"
min_age_days = 3
[health]
url = "http://127.0.0.1:8080/"
timeout_s = 120
settle_s = 3
[hooks]
pre = "echo pre > pre.marker"
rollback = "echo rollback > rollback.marker"
EOF
(cd /srv/whoami && podman compose up -d >/dev/null 2>&1)
check "whoami v1.10.4 answers" bash -c "for i in \$(seq 30); do curl -sf localhost:8080 >/dev/null && exit 0; sleep 1; done; exit 1"
svc-update status
check "status offers 1.12.0" bash -c "svc-update status | grep -q -- '-> 1.12.0'"

step "check -> buttons -> press -> update"
svc-update check
wait_sent "offer message" "whoami: 1.10.4 → 1.12.0"
TOK=$(last_token); echo "button: $TOK"
check "button carries plugin:verb:token" grep -qE '^svc-update:u:[0-9a-f]{12}$' <<<"$TOK"
press "$TOK" $STRANGER
sleep 4
check "stranger's press ignored" bash -c "journalctl -u tg-gate --no-pager | grep -q 'ignored callback from unauthorised id $STRANGER'"
press "${TOK/:u:/:x:}"
sleep 3
check "unknown verb answered" grep -q "Unknown button" $T/answerCallbackQuery.jsonl
press "$TOK"
wait_sent "update started" "⏳ whoami: updating v1.10.4 → v1.12.0" 60
wait_sent "update done" "✅ whoami updated to v1.12.0" 240
check "compose repinned to v1.12.0@digest" grep -qE 'image: traefik/whoami:v1.12.0@sha256:[0-9a-f]{64}' /srv/whoami/compose.yml
check "pre hook ran" test -f /srv/whoami/pre.marker
check "compose backup kept" bash -c "ls /srv/whoami/compose.yml.bak-svc-update-* >/dev/null"
press "$TOK"
wait_sent "button is single use" "expired or was already used"

step "commands"
say_cmd "/status"
wait_sent "/status reply" "services:"
say_cmd "/check@adama_test_bot"
wait_sent "/check reply when nothing new" "No updates available"
say_cmd "/rm"; sleep 3
check "unknown command not queued" bash -c "! journalctl -u tg-gate-plugin@svc-update --no-pager | grep -q rejected"

step "failed update -> automatic rollback"
sed -i "s|image: .*|image: traefik/whoami:v1.10.4@$D_OLD|" /srv/whoami/compose.yml
(cd /srv/whoami && podman compose up -d >/dev/null 2>&1)
# the new version must fail and the old one pass: whoami's /api is JSON without "version"
sed -i 's|^url = .*|url = "http://127.0.0.1:8080/api"\nversion_key = "version"|; s|^timeout_s = 120|timeout_s = 25|' /etc/svc-update/services/whoami.toml
svc-update apply whoami -y > /tmp/rollback.out 2>&1; rc=$?
tail -3 /tmp/rollback.out
check "apply exits 1" test $rc = 1
wait_sent "failure reported with rollback" "rolled back to v1.10.4"
check "rollback hook ran" test -f /srv/whoami/rollback.marker
check "compose restored to v1.10.4" grep -q "v1.10.4@$D_OLD" /srv/whoami/compose.yml
check "old version serves again" bash -c "for i in \$(seq 20); do curl -sf localhost:8080 >/dev/null && exit 0; sleep 1; done; exit 1"
sed -i 's|^url = .*|url = "http://127.0.0.1:8080/"|; /^version_key/d; s|^timeout_s = 25|timeout_s = 120|' /etc/svc-update/services/whoami.toml

step "--force (age gate bypass)"
sed -i 's|^min_age_days = 3|min_age_days = 1000|' /etc/svc-update/services/whoami.toml
out=$(svc-update apply whoami 2>&1); echo "$out"
check "plain apply refuses young release, hints --force" grep -q "inside the age gate" <<<"$out"
out=$(printf '\n' | svc-update apply whoami --force 2>&1); rc=$?; echo "$out" | tail -4
check "menu lists numbered releases" grep -q "1) 1.12.0" <<<"$out"
check "Enter cancels (exit 1)" test $rc = 1
check "Enter says aborted" grep -q aborted <<<"$out"
out=$(svc-update apply whoami --force --version 9.9.9 2>&1); echo "$out"
check "unknown version refused" grep -q "is not a newer stable release" <<<"$out"
out=$(svc-update apply whoami --force --version 1.12.0 -y 2>&1); rc=$?; echo "$out" | tail -3
check "forced apply succeeds" test $rc = 0
check "age gate bypass printed" grep -q "AGE GATE BYPASSED" <<<"$out"
wait_sent "bypass notice sent" "age gate bypassed with --force for 1.12.0"
check "no downgrade via --force" bash -c "svc-update apply whoami --force --version 1.11.0 -y 2>&1 | grep -q 'no downgrades'"
sed -i 's|^min_age_days = 1000|min_age_days = 3|' /etc/svc-update/services/whoami.toml

step "unit failure report, gate down fallback"
systemctl start tg-gate-failed@demo.service
wait_sent "OnFailure helper alert" "🚨 [systemd] demo failed"
systemctl stop tg-gate; touch -d '-5 min' /var/lib/tg-gate/alive
tg-notify --tool t2 "root while gate is down"
wait_sent "root sends directly when gate is down" "[t2] root while gate is down" 10
runuser -u alice -- tg-notify --tool t2 "alice while gate is down"
not_sent_after "non-root message waits for the gate" "alice while gate is down" 3
systemctl start tg-gate
wait_sent "queued message delivered after restart" "[t2@alice] alice while gate is down"

step "update-check (notice once an upstream commit is 12 h old)"
check "update-check timer enabled" systemctl is-enabled --quiet tg-gate-update-check.timer
check "svc-update registered for update-check" grep -q 'repo = "/opt/svc-update"' /etc/tg-gate/updates.d/svc-update.toml
check "update-check (unit, sandboxed) ok while up to date" systemctl start tg-gate-update-check.service
for r in tg-gate svc-update; do
  rm -rf /srv/work && git clone -q /srv/origin/$r.git /srv/work
  git -C /srv/work commit -q --allow-empty -m "test: upstream ahead" && git -C /srv/work push -q
done
check "update-check (unit) ok while behind, inside the delay" systemctl start tg-gate-update-check.service
check "first seen recorded for both" python3 -c "import json; s=json.load(open('/var/lib/tg-gate/update-check.json')); assert set(s) == {'tg-gate', 'svc-update'} and not any('notified' in e for e in s.values())"
not_sent_after "no notice before 12 h" "Updates for the tools" 3
mkdir -p /etc/systemd/system/tg-gate-update-check.service.d
printf '[Service]\nExecStart=\nExecStart=/usr/bin/python3 -I /opt/tg-gate/tg-gate update-check --delay 0\n' > /etc/systemd/system/tg-gate-update-check.service.d/test.conf
systemctl daemon-reload
check "update-check (unit) ok once due" systemctl start tg-gate-update-check.service
wait_sent "notice names tg-gate" "sudo tg-gate self-update"
wait_sent "notice names svc-update" "sudo svc-update self-update"
check "clones unchanged by update-check" bash -c "! git -C /opt/tg-gate log -1 --format=%s | grep -q 'upstream ahead'"
n=$(grep -c "Updates for the tools" $T/sendMessage.jsonl)
systemctl start tg-gate-update-check.service; sleep 3
check "reported once" test "$(grep -c "Updates for the tools" $T/sendMessage.jsonl)" = "$n"
rm -r /etc/systemd/system/tg-gate-update-check.service.d && systemctl daemon-reload

step "self-update (tg-gate and svc-update)"
for r in tg-gate svc-update; do
  rm -rf /srv/work && git clone -q /srv/origin/$r.git /srv/work
  echo "test change" >> /srv/work/README.md && git -C /srv/work commit -qam "test: README" && git -C /srv/work push -q
  out=$($r self-update -y 2>&1); rc=$?; echo "$out" | tail -4
  check "$r self-update ok" test $rc = 0
  check "$r fast-forwarded" bash -c "git -C /opt/$r log -1 --format=%s | grep -q 'test: README'"
  wait_sent "$r update notice" "$( [ $r = tg-gate ] && echo '[tg-gate] updated' || echo 'svc-update on')"
  out=$($r self-update -y 2>&1); check "$r then up to date" grep -q "up to date" <<<"$out"
done
check "gate still running after self-update" systemctl is-active --quiet tg-gate

echo; echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
