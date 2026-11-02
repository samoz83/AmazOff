#!/usr/bin/env python3
"""Isolated startup/repair tests; no root, mounts, TV or network required."""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

SOURCE = Path(os.environ.get("AMAZOFF_SOURCE", Path(__file__).resolve().parents[2]))
SHELL = shlex.split(os.environ.get("AMAZOFF_TEST_SHELL", "sh"))


class Fixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)

    def runsh(self, script, *, timeout=10, env=None):
        return subprocess.run(SHELL + ["-c", script], text=True,
                              capture_output=True, timeout=timeout, env=env)

    def assert_ok(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


class RepairTests(Fixture):
    def script(self, body):
        return f"""
BASE={shlex.quote(str(self.base))}
TARGET_DIR="$BASE/target"; CERT_DIR="$BASE/cert"; TARGET_APP_NAME=amazon
mkdir -p "$TARGET_DIR/bin/certs" "$CERT_DIR"
printf correct >"$CERT_DIR/test.0"
log() {{ echo "$*" >>"$BASE/log"; }}
die() {{ log "$*"; exit 1; }}
require_root() {{ :; }}
. {shlex.quote(str(SOURCE / 'tools/lib/patch.sh'))}
HOSTS_SYSTEM="$BASE/hosts"; HOSTS_JAIL="$BASE/jail/hosts"
writable_system_hosts() {{ :; }}
unpatch_rootfs_hosts() {{ :; }}
printf '127.0.0.1 localhost\\n0.0.0.0 unrelated.example\\n' >"$HOSTS_SYSTEM"
set -e
{body}
"""

    def test_ipv6_loss_is_detected_and_repaired(self):
        for which in ["HOSTS_SYSTEM", "HOSTS_JAIL"]:
            with self.subTest(which=which):
                self.assert_ok(self.runsh(self.script(f"""
patch_hosts
sed '/^::1 /d' "${which}" >"$BASE/edit"; cat "$BASE/edit" >"${which}"
if hosts_patched; then echo 'missing IPv6 accepted' >&2; exit 1; fi
patch_hosts
hosts_patched
[ "$(grep -cxF "$HOST_ENTRY_V6" "${which}")" = 1 ]
unpatch_hosts
! grep -F cloudfront.xp-assets.aiv-cdn.net "$HOSTS_SYSTEM" "$HOSTS_JAIL"
grep -qxF '0.0.0.0 unrelated.example' "$HOSTS_SYSTEM"
""")))

    def test_wrong_certificate_is_detected_and_repaired(self):
        self.assert_ok(self.runsh(self.script("""
printf wrong >"$TARGET_CERT_DIR/$CERT_NAME"
if cert_pinned; then echo 'wrong CA accepted' >&2; exit 1; fi
patch_cert_pin
cert_pinned
cmp "$TARGET_CERT_DIR/$CERT_NAME" "$CERT_DIR/$CERT_NAME"
""")))

    def test_hosts_preparation_failure_precedes_prime_changes(self):
        self.assert_ok(self.runsh(self.script("""
writable_system_hosts() { return 1; }
patch_default_conf() { echo config >>"$BASE/mutations"; }
patch_cert_pin() { echo cert >>"$BASE/mutations"; }
toast() { :; }
if do_patch; then echo 'failed hosts preparation accepted' >&2; exit 1; fi
[ ! -f "$BASE/mutations" ]
""")))

    def test_jail_write_failure_is_not_success(self):
        self.assert_ok(self.runsh(self.script("""
patch_hosts_helper() { [ "$1" != "$HOSTS_JAIL" ]; }
if patch_hosts; then echo 'jail write failure accepted' >&2; exit 1; fi
""")))

    def test_lovefilm_missing_source_preserves_targets(self):
        result = self.runsh(self.script("""
CONFIGS_DIR="$BASE/config"; PATCHER_RESOURCES_DIR="$BASE/resources"
mkdir -p "$CONFIGS_DIR" "$PATCHER_RESOURCES_DIR/patch"
TARGET_CONF_LOVEFILM="$BASE/lovefilm-config"
TARGET_CHUNK_LOVEFILM="$BASE/lovefilm-chunk"
printf existing >"$TARGET_CONF_LOVEFILM"
printf existing >"$TARGET_CHUNK_LOVEFILM"
do_patch_lovefilm
"""))
        self.assertNotEqual(result.returncode, 0)
        for name in ["lovefilm-config", "lovefilm-chunk"]:
            self.assertEqual((self.base / name).read_text(), "existing")


class ControlTests(Fixture):
    def test_failed_start_and_stop_return_error_with_one_json_result(self):
        for operation in ["start", "stop"]:
            with self.subTest(operation=operation):
                tools = self.base / operation
                (tools / "lib").mkdir(parents=True)
                shutil.copy(SOURCE / "tools/patchctl.sh", tools / "patchctl.sh")
                (tools / "lib/common.sh").write_text(f"""
BASE={shlex.quote(str(tools))}; LOG="$BASE/log"
TARGET_APP_NAME=amazon; APP_NAME_LOVEFILM=lovefilm; AUTOSTART_ENTRY=unused
require_root() {{ :; }}
log() {{ echo "$*" >>"$LOG"; }}
""")
                (tools / "lib/patch.sh").write_text("""
do_patch() { echo unwanted_stdout; return 1; }
do_unpatch() { echo unwanted_stdout; return 1; }
hosts_patched() { return 0; }
cert_pinned() { return 0; }
""")
                for filename, prefix in [("netshim.sh", "netshim"), ("monitor.sh", "monitor")]:
                    start = prefix + ("_start_nginx" if prefix == "netshim" else "_start")
                    stop = prefix + ("_stop_nginx" if prefix == "netshim" else "_stop")
                    (tools / "lib" / filename).write_text(f"""
{start}() {{ echo started >>"$BASE/started"; touch "$BASE/{prefix}"; }}
{stop}() {{ rm -f "$BASE/{prefix}"; }}
{prefix}_running() {{ [ -f "$BASE/{prefix}" ]; }}
""")
                result = subprocess.run(SHELL + [str(tools / "patchctl.sh"), operation],
                                        capture_output=True, text=True, timeout=5)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                state = json.loads(result.stdout)
                self.assertIn("state", state)
                self.assertFalse((tools / "started").exists(),
                                 "services started after patch failure")


class HiddenHostsTests(unittest.TestCase):
    def exercise(self, entrypoint):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            clean = "# another manager\n127.0.0.1 localhost\n0.0.0.0 other.example\n"
            redirects = ("127.0.0.1 cloudfront.xp-assets.aiv-cdn.net\n"
                         "::1 cloudfront.xp-assets.aiv-cdn.net\n")
            for name in ["visible", "jail", "hidden"]:
                (base / name).write_text(clean + redirects)
            script = f"""
set -eu
BASE='{base}'; CERT_DIR="$BASE"; TARGET_DIR="$BASE"; TARGET_APP_NAME=amazon
log() {{ :; }}
die() {{ echo "$*" >&2; exit 1; }}
. '{SOURCE}/tools/lib/patch.sh'
HOSTS_SYSTEM="$BASE/visible"; HOSTS_JAIL="$BASE/jail"
# Keep the actual rootfs cleanup and file-editing functions. Only OS mount
# discovery/bind operations are represented by an isolated temporary tree.
grep() {{
  if [ "$#" = 3 ] && [ "$1" = -q ] && [ "$3" = /proc/mounts ]; then return 0; fi
  command grep "$@"
}}
mount() {{
  [ "$#" = 3 ] && [ "$1" = --bind ] && [ "$2" = / ] || exit 90
  mkdir -p "$3/etc"
  cp "$BASE/hidden" "$3/etc/hosts"
  printf '%s\\n' "$3" >"$BASE/private-root-view"
}}
umount() {{
  [ "$1" = "$(cat "$BASE/private-root-view")" ] || exit 91
  cp "$1/etc/hosts" "$BASE/hidden"
  rm "$1/etc/hosts"; rmdir "$1/etc"
  echo released >"$BASE/private-view-released"
}}
{entrypoint}
"""
            result = subprocess.run(SHELL + ["-c", script], capture_output=True,
                                    text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual((base / "hidden").read_text(), clean,
                             "hidden original still contains AmazOff redirects")
            self.assertTrue((base / "private-view-released").exists())
            if entrypoint == "unpatch_hosts":
                self.assertEqual((base / "visible").read_text(), clean)
                self.assertEqual((base / "jail").read_text(), clean)

    def test_direct_rootfs_cleanup_positive_control(self):
        self.exercise("unpatch_rootfs_hosts")

    def test_complete_stop_cleans_hidden_original(self):
        self.exercise("unpatch_hosts")


class BootTests(Fixture):
    def boot(self, scenario, twice=False):
        tools = self.base / "tools"
        shutil.copytree(SOURCE / "tools", tools)
        (tools / "lib/common.sh").write_text(f"""
BASE={shlex.quote(str(self.base))}; LOG="$BASE/log"
TOOLS_DIR={shlex.quote(str(tools))}; SCRIPTS_DIR="$TOOLS_DIR/lib"
TARGET_APP_NAME=amazon
require_root() {{ :; }}
log() {{ echo "$*" >>"$LOG"; }}
""")
        (tools / "patchctl.sh").write_text("""#!/bin/sh
echo start >>"$TEST_DIR/actions"
[ "$SCENARIO" != start_fail ]
""")
        (tools / "patchctl.sh").chmod(0o755)
        # Exercise real readiness and retry code; replace only device inputs.
        for filename in ["patch.sh", "netshim.sh", "monitor.sh"]:
            (tools / "lib" / filename).write_text("")
        readiness = tools / "lib/readiness.sh"
        if readiness.exists():
            with readiness.open("a") as f:
                f.write(f"""
CERT_DIR={shlex.quote(str(SOURCE / 'resources/amazon/tls'))}
CERT_NAME=322ca25a.0
monitor_running() {{ [ "$SCENARIO" != missing_monitor ]; }}
netshim_running() {{ return 0; }}
hosts_patched() {{ [ "$SCENARIO" != missing_ipv6 ]; }}
cert_pinned() {{ [ "$SCENARIO" != wrong_ca ]; }}
hosts_conflicts() {{ [ "$SCENARIO" != conflict ] || echo conflict; }}
is_lovefilm_patched() {{ [ "$SCENARIO" = lovefilm ]; }}
[ "$SCENARIO" != lovefilm ] || TARGET_APP_NAME=lovefilm
amazoff_uptime_seconds() {{ cat "$BASE/uptime"; }}
sleep() {{
  n=$(cat "$BASE/uptime"); echo $((n + $1)) >"$BASE/uptime"
  [ "$SCENARIO" != clock_recovers ] || echo 1793601531 >"$BASE/clock"
}}
curl() {{
  echo tls >>"$BASE/actions"
  # Verify the actual shipped chain. No connection or clock change occurs.
  case " $* " in *' --head '*|*' -I '*) ;; *) return 91;; esac
  case " $* " in *' --cacert '*) ;; *) return 92;; esac
  case " $* " in *" --cacert $CERT_DIR/$CERT_NAME "*) ;; *) return 94;; esac
  case " $* " in *' --insecure '*|*' -k '*|*ATVUnfPlayerBundle*) return 93;; esac
  host=cloudfront.xp-assets.aiv-cdn.net
  [ "$SCENARIO" != invalid_tls ] || host=wrong.example
  openssl verify -CAfile "$CERT_DIR/322ca25a.0" -purpose sslserver \
    -verify_hostname "$host" -attime "$(cat "$BASE/clock")" \
    "$CERT_DIR/server.crt" >/dev/null
}}
""")
        (self.base / "uptime").write_text("0\n")
        (self.base / "clock").write_text(
            "1609459231\n" if scenario == "clock_recovers" else "1793601531\n")
        binpath = self.base / "bin"
        binpath.mkdir()
        luna = binpath / "luna-send"
        luna.write_text("#!/bin/sh\necho luna >>\"$TEST_DIR/actions\"\nexit 1\n")
        luna.chmod(0o755)
        if scenario == "legacy_timeout":
            wrapper = binpath / "timeout"
            wrapper.write_text("""#!/usr/bin/env python3
import os, sys
if sys.argv[1] == "--help":
    print("Usage: timeout [-t SECS] [-s SIG] PROG ARGS")
    sys.exit(0)
assert sys.argv[1] == "-t"
os.execvp(sys.argv[3], sys.argv[3:])
""")
            wrapper.chmod(0o755)
        env = dict(os.environ, TEST_DIR=str(self.base), SCENARIO=scenario,
                   PATH=str(binpath) + os.pathsep + os.environ["PATH"])
        results = [subprocess.run(["sh", str(tools / "autostart.sh")],
                                  env=env, text=True, capture_output=True, timeout=10)
                   for _ in range(2 if twice else 1)]
        actions = ((self.base / "actions").read_text().splitlines()
                   if (self.base / "actions").exists() else [])
        return results, actions

    def test_success_never_controls_prime_and_runs_once(self):
        results, actions = self.boot("foreground", twice=True)
        for result in results:
            self.assert_ok(result)
        self.assertEqual(actions, ["start", "tls"])
        self.assertTrue((self.base / "boot.complete").exists())

    def test_background_prime_is_untouched(self):
        results, actions = self.boot("background")
        self.assert_ok(results[0])
        self.assertNotIn("luna", actions)

    def test_absent_prime_stays_absent(self):
        results, actions = self.boot("absent")
        self.assert_ok(results[0])
        self.assertNotIn("luna", actions)

    def test_failed_start_never_marks_completion_or_controls_prime(self):
        results, actions = self.boot("start_fail")
        self.assertNotEqual(results[0].returncode, 0)
        self.assertEqual(actions, ["start"])
        self.assertFalse((self.base / "boot.complete").exists())

    def test_clock_recovers_without_disabling_certificate_validation(self):
        results, actions = self.boot("clock_recovers")
        self.assert_ok(results[0])
        self.assertEqual(actions, ["start", "tls", "tls"])
        self.assertIn("certificate is not yet valid", (self.base / "boot.log").read_text())
        self.assertTrue((self.base / "boot.complete").exists())

    def test_invalid_tls_remains_failure_with_bounded_retries(self):
        results, actions = self.boot("invalid_tls")
        self.assertNotEqual(results[0].returncode, 0)
        self.assertNotIn("luna", actions)
        self.assertGreater(actions.count("tls"), 1)
        self.assertLessEqual(actions.count("tls"), 32)
        self.assertGreaterEqual(int((self.base / "uptime").read_text()), 60)
        self.assertIn("hostname mismatch", (self.base / "boot.log").read_text())
        self.assertFalse((self.base / "boot.complete").exists())

    def test_legacy_timeout(self):
        results, actions = self.boot("legacy_timeout")
        self.assert_ok(results[0])
        self.assertEqual(actions, ["start", "tls"])

    def test_missing_monitor_never_passes_readiness(self):
        results, actions = self.boot("missing_monitor")
        self.assertNotEqual(results[0].returncode, 0)
        self.assertEqual(actions, ["start"])
        self.assertFalse((self.base / "boot.complete").exists())

    def test_missing_ipv6_never_passes_readiness(self):
        results, actions = self.boot("missing_ipv6")
        self.assertNotEqual(results[0].returncode, 0)
        self.assertEqual(actions, ["start"])
        self.assertFalse((self.base / "boot.complete").exists())

    def test_wrong_ca_never_passes_readiness(self):
        results, actions = self.boot("wrong_ca")
        self.assertNotEqual(results[0].returncode, 0)
        self.assertEqual(actions, ["start"])
        self.assertFalse((self.base / "boot.complete").exists())

    def test_conflicting_hosts_never_pass_readiness(self):
        results, actions = self.boot("conflict")
        self.assertNotEqual(results[0].returncode, 0)
        self.assertEqual(actions, ["start"])
        self.assertFalse((self.base / "boot.complete").exists())

    def test_lovefilm_does_not_need_tls(self):
        results, actions = self.boot("lovefilm")
        self.assert_ok(results[0])
        self.assertEqual(actions, ["start"])


if __name__ == "__main__":
    for command in ["sh", "openssl", "timeout"]:
        if not shutil.which(command):
            raise SystemExit(f"Required test dependency missing: {command}")
    unittest.main(verbosity=2)
