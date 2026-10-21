"""Unit tests for svc-update (stdlib only): python3 -m unittest discover -s tests"""
import argparse, http.server, importlib.machinery, importlib.util, io, json, os, tempfile, threading, time, unittest
from contextlib import redirect_stdout
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
_loader = importlib.machinery.SourceFileLoader("svc_update", os.path.join(HERE, "..", "svc-update"))
_spec = importlib.util.spec_from_loader("svc_update", _loader)
su = importlib.util.module_from_spec(_spec)
_loader.exec_module(su)

DAY = 86400
D_OLD, D_NEW, D_NEWER = ("sha256:" + c * 64 for c in "abc")


def iso(t):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        t = self.tmp.name
        su.STATE_DIR = os.path.join(t, "state")
        su.STATE, su.LOG, su.RUNS = (os.path.join(su.STATE_DIR, n) for n in ("state.json", "svc-update.log", "runs"))
        su.SERVICES = os.path.join(t, "services")
        su.PLUGIN_FILE = os.path.join(t, "no-plugin")
        su.TG_NOTIFY = os.path.join(t, "no-tg-notify")
        su.INBOX = os.path.join(t, "inbox")
        for d in (su.SERVICES, su.INBOX, os.path.join(t, "app")):
            os.makedirs(d)
        self.compose = os.path.join(t, "app", "compose.yml")
        self.now = time.time()
        self.sent = []
        p = mock.patch.object(su, "send", lambda text, buttons=None, level="info": self.sent.append((text, buttons, level)) or True)
        p.start()
        self.addCleanup(p.stop)
        self.addCleanup(self.tmp.cleanup)

    def service(self, src, tag, digest=D_OLD, image="ghcr.io/org/app", tag_format="v{version}-slim"):
        with open(self.compose, "w") as f:
            f.write("services:\n  app:\n    image: %s:%s@%s\n    restart: unless-stopped\n" % (image, tag, digest))
        path = os.path.join(su.SERVICES, "app.toml")
        with open(path, "w") as f:
            f.write('name = "app"\ncompose_dir = "%s"\ncompose_service = "app"\nimage = "%s"\ntag_format = "%s"\n'
                    '[source]\n%s\nmin_age_days = 3\n' % (os.path.dirname(self.compose), image, tag_format, src))
        return su.Service(path)

    def github(self, releases):
        """releases: (tag, age_days, prerelease, body)"""
        rels = [{"tag_name": t, "published_at": iso(self.now - a * DAY), "prerelease": pre, "draft": False,
                 "html_url": "https://example/" + t, "body": body} for t, a, pre, body in releases]

        def fake(url, headers=None, timeout=20):
            if url.endswith("/releases?per_page=30"):
                return rels
            if "security-advisories" in url:
                return []
            raise AssertionError(url)
        return mock.patch.multiple(su, http_json=fake, registry_digest=lambda image, tag: "sha256:" + "d" * 64)


class Versions(Base):
    def test_vtuple_and_tag_format(self):
        s = self.service('type = "github"\nrepo = "org/app"', "v2.25.2-slim")
        self.assertEqual(s.running(), "2.25.2")
        self.assertEqual(s.tag_for("2.26.0"), "v2.26.0-slim")
        self.assertLess(su.vtuple("0.19.4"), su.vtuple("0.20.0"))
        self.assertEqual(su.vtuple("1.2.3-rc1"), (1, 2, 3))

    def test_age_gate_and_young(self):
        s = self.service('type = "github"\nrepo = "org/app"', "v0.19.3-slim")
        with self.github([("v0.20.0", 0.3, False, "Breaking: migration"), ("v0.20.0-beta1", 2, True, ""),
                          ("v0.19.4", 5, False, "fixes CVE-2026-1"), ("v0.19.3", 9, False, "")]):
            cand, young = s.candidate()
        self.assertEqual((cand["version"], cand["tag"], cand["n_releases"], cand["security"], cand["breaking"]),
                         ("0.19.4", "v0.19.4-slim", 1, True, False))
        self.assertEqual(young["version"], "0.20.0")

    def test_nothing_newer(self):
        s = self.service('type = "github"\nrepo = "org/app"', "v0.20.0-slim")
        with self.github([("v0.20.0", 5, False, ""), ("v0.19.4", 9, False, "")]):
            self.assertEqual(s.candidate(), (None, None))


class Digest(Base):
    def test_first_seen_gate(self):
        s = self.service('type = "registry-digest"\nurl = "https://hub/postgres"', "18", image="postgres",
                         tag_format="{version}")
        with mock.patch.object(su, "registry_digest", lambda image, tag: D_NEW):
            st = {}
            cand, young = s.candidate(st)
            self.assertIsNone(cand)
            self.assertEqual(young["version"], "18@" + D_NEW[7:19])
            st["first_seen"]["app"][D_NEW] -= 4 * DAY          # seen 4 days ago
            cand, _ = s.candidate(st)
            self.assertEqual((cand["tag"], cand["expect_digest"]), ("18", D_NEW))
        with mock.patch.object(su, "registry_digest", lambda image, tag: D_NEWER):
            s.candidate(st)
            self.assertEqual(list(st["first_seen"]["app"]), [D_NEWER])   # tag moved again: clock restarts

    def test_rewrite_compose(self):
        s = self.service('type = "registry-digest"', "18", image="postgres", tag_format="{version}")
        s.rewrite_compose("18", D_NEW)
        self.assertEqual(s.pinned(), ("18", D_NEW))
        with open(self.compose) as f:
            self.assertIn("    restart: unless-stopped\n", f.read())


class Force(Base):
    def args(self, **kw):
        return argparse.Namespace(**dict({"service": "app", "yes": False, "force": True, "version": None}, **kw))

    def test_menu_default_is_cancel(self):
        s = self.service('type = "github"\nrepo = "org/app"', "v0.19.3-slim")
        with self.github([("v0.20.0", 0.3, False, ""), ("v0.19.4", 5, False, "")]), \
                mock.patch("builtins.input", return_value=""), redirect_stdout(io.StringIO()) as out:
            u, ups = su.choose_forced(s, self.args())
        self.assertIsNone(u)
        self.assertIn("1) 0.20.0", out.getvalue())
        self.assertIn("inside the age gate", out.getvalue())
        self.assertIn("2) 0.19.4", out.getvalue())

    def test_version_picks_young_release_and_refuses_unknown(self):
        s = self.service('type = "github"\nrepo = "org/app"', "v0.19.3-slim")
        with self.github([("v0.20.0", 0.3, False, ""), ("v0.19.4", 5, False, ""), ("v0.19.3", 9, False, "")]):
            u, ups = su.choose_forced(s, self.args(version="v0.20.0"))
            self.assertEqual(u["version"], "0.20.0")
            off = s.offer(u, ups)
            self.assertEqual(off["n_releases"], 2)
            self.assertGreater(off["eligible"], self.now)
            for bad in ("0.19.3", "0.18.0", "0.21.0"):              # running, older, nonexistent
                with self.assertRaises(SystemExit):
                    su.choose_forced(s, self.args(version=bad))

    def test_cli_apply_forced_sends_warning(self):
        self.service('type = "github"\nrepo = "org/app"', "v0.19.3-slim")
        calls = []
        with self.github([("v0.20.0", 0.3, False, "")]), \
                mock.patch.object(su, "do_apply", lambda s, v, t, d: calls.append((v, t, d)) or 0), \
                redirect_stdout(io.StringIO()) as out:
            rc = su.cmd_apply(self.args(version="0.20.0", yes=True))
        self.assertEqual((rc, calls), (0, [("0.20.0", "v0.20.0-slim", "sha256:" + "d" * 64)]))
        self.assertIn("AGE GATE BYPASSED", out.getvalue())
        self.assertEqual(self.sent[0][2], "warn")


class Requests(Base):
    def req(self, **kw):
        return dict({"v": 1, "plugin": "svc-update", "kind": "callback", "verb": "u", "token": "a1b2c3d4e5f6",
                     "from": 1, "ts": time.time()}, **kw)

    def test_valid_request(self):
        self.assertTrue(su.valid_request(self.req()))
        self.assertTrue(su.valid_request(self.req(kind="command", command="check")))
        for bad in (self.req(v=2), self.req(plugin="other"), self.req(verb="x"), self.req(token="zz"),
                    self.req(ts=time.time() - 7200), self.req(kind="command", command="rm"), "x", None):
            self.assertFalse(su.valid_request(bad), bad)

    def test_button_is_single_use(self):
        self.service('type = "github"\nrepo = "org/app"', "v0.19.3-slim")
        su.save_state({"pending": {"a1b2c3d4e5f6": {"svc": "app", "version": "0.19.4", "tag": "v0.19.4-slim",
                                                    "expect_digest": D_NEW, "created": time.time()}}})
        applied = []
        with mock.patch.object(su, "do_apply", lambda s, v, t, d: applied.append(v) or 0):
            for _ in range(2):
                with open(os.path.join(su.INBOX, "%d.json" % time.time_ns()), "w") as f:
                    json.dump(self.req(), f)
                su.cmd_process(None)
        self.assertEqual(applied, ["0.19.4"])
        self.assertIn("expired or was already used", self.sent[-1][0])
        self.assertEqual(os.listdir(su.INBOX), [])


class HealthUrl(Base):
    def setUp(self):
        super().setUp()
        body = {"/healthz": b"ok", "/about": json.dumps({"version": "v0.20.0"}).encode()}

        class H(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                b = body.get(self.path)
                self.send_response(200 if b else 404)
                self.end_headers()
                self.wfile.write(b or b"")

            def log_message(self, *a):
                pass
        self.srv = http.server.HTTPServer(("127.0.0.1", 0), H)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.addCleanup(self.srv.server_close)
        self.addCleanup(self.srv.shutdown)
        self.base = "http://127.0.0.1:%d" % self.srv.server_port

    def svc(self, health):
        s = self.service('type = "github"\nrepo = "org/app"', "v0.19.3-slim")
        s.health = health
        return s

    def test_plain_text_health_endpoint(self):
        # otterwiki: /-/healthz answers "ok", not JSON; that must pass (and the rollback check too)
        s = self.svc({"url": self.base + "/healthz"})
        self.assertEqual(s.check_url("2.26.0"), (True, "url ok (HTTP 200)"))
        self.assertTrue(s.check_url(None)[0])

    def test_version_key(self):
        s = self.svc({"url": self.base + "/about", "version_key": "version"})
        self.assertEqual(s.check_url("0.20.0"), (True, "reports version 0.20.0"))
        self.assertFalse(s.check_url("0.19.4")[0])
        self.assertTrue(s.check_url(None)[0])                       # rollback: no version expected
        self.assertFalse(self.svc({"url": self.base + "/missing"}).check_url(None)[0])


class Engine(Base):
    def test_container_state_docker_and_podman_json(self):
        s = self.service('type = "github"\nrepo = "org/app"', "v0.19.3-slim")
        docker = [{"State": {"Status": "running", "Health": {"Status": "healthy"}}, "RestartCount": 0}]
        podman_nohc = [{"State": {"Status": "running", "Health": {"Status": ""}}, "RestartCount": 2}]
        for js, want in ((docker, ("running", "healthy", 0)), (podman_nohc, ("running", "none", 2))):
            outs = iter([mock.Mock(stdout="cid1\n"), mock.Mock(stdout=json.dumps(js))])
            with mock.patch.object(su, "run", lambda *a, **k: next(outs)), \
                    mock.patch.object(su, "engine", lambda: "podman"):
                self.assertEqual(s.container_state(), want)


if __name__ == "__main__":
    unittest.main()
