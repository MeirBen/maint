"""Safe regression checks: all service and administrator commands are substituted."""

import errno
import fcntl
from datetime import datetime, timezone
import os
from pathlib import Path
import pty
import select
import shlex
import signal
import subprocess
import tempfile
import time
import unittest

PROJECT = Path(__file__).resolve().parents[1]


class ToolkitTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="maintenance-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.toolkit = self.root / "Toolkit with spaces"
        self.toolkit.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name in ("lib/common.sh", "local-ai.sh", "update-system.sh"):
            source = PROJECT / name
            if source.exists():
                target = self.toolkit / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(source.read_text().replace("EUID", "TEST_EUID")
                    .replace("/usr/local/sbin/local-ai-service-control", str(self.bin / "service"))
                    .replace("/usr/bin/systemd-run", str(self.bin / "browser")))
        self.trace = self.root / "trace"
        self.env = {**os.environ, "PATH": str(self.bin) + ":/usr/bin:/bin",
            "TRACE": str(self.trace), "TEST_EUID": "1000", "NO_COLOR": "1"}
        self.env.pop("SCRIPT_PAUSE_ON_EXIT", None)
        self.command("sudo", '''#!/bin/bash
printf 'sudo:%s\\n' "$*" >> "$TRACE"
if [[ "$1" == -v ]]; then exit "${AUTH_EXIT:-0}"; fi
exec "$@"
''')
        self.command("service", '''#!/bin/bash
printf 'service:%s\\n' "$*" >> "$TRACE"
printf 'Service action: %s\\n' "$1"
echo 'Service diagnostic' >&2
exit "${SERVICE_EXIT:-0}"
''')
        self.command("browser", '''#!/bin/bash
printf 'browser:%s\\n' "$*" >> "$TRACE"
exit "${BROWSER_EXIT:-0}"
''')

    def command(self, name, contents):
        path = self.bin / name
        path.write_text(contents)
        path.chmod(0o750)

    def probe(self, body, tool="probe"):
        path = self.root / (tool + "-probe.sh")
        path.write_text("#!/bin/bash\nset -Eeuo pipefail\nSCRIPT_DIR=" + shlex.quote(str(self.toolkit)) +
            '\nsource "$SCRIPT_DIR/lib/common.sh"\n' +
            'initialize_runtime "$SCRIPT_DIR" ' + shlex.quote(tool) + ' "Test task"\n' + body + "\n")
        return path

    def run_script(self, path, *arguments, input="", **changes):
        return subprocess.run(["/bin/bash", str(path), *arguments], input=input, text=True,
            capture_output=True, timeout=6, cwd=self.root, env={**self.env, **changes})

    def log(self, tool="probe"):
        return (self.toolkit / "logs" / (tool + ".log")).read_text()

    def use_log_date(self, day):
        self.env["LOG_TEST_DATE"] = day
        self.command("date", '''#!/bin/bash
if [[ "$*" == '+%F' ]]; then
    printf '%s\\n' "$LOG_TEST_DATE"
else
    exec /usr/bin/date "$@"
fi
''')

    def test_daily_logs_keep_every_run_and_roll_independently_for_each_tool(self):
        self.use_log_date("2026-10-08")
        for tool in ("update-system", "local-ai"):
            with self.subTest(tool=tool):
                path = self.probe('info "Run: $1"', tool)
                self.assertEqual(self.run_script(path, "first").returncode, 0)
                self.assertEqual(self.run_script(path, "second").returncode, 0)
                latest = self.toolkit / "logs" / (tool + ".log")
                day_one = self.toolkit / "logs" / tool / "2026-10-08.log"
                self.assertTrue(latest.is_symlink())
                self.assertEqual(latest.resolve(), day_one)
                original = day_one.read_text()
                self.assertIn("Run: first", original)
                self.assertIn("Run: second", original)
                result = self.run_script(path, "third", LOG_TEST_DATE="2026-10-09")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(day_one.read_text(), original)
                self.assertIn("Run: third", self.log(tool))
                self.assertNotIn("Run: first", self.log(tool))
                self.assertEqual(latest.resolve().name, "2026-10-09.log")

    def test_existing_latest_log_is_preserved_when_daily_logs_are_enabled(self):
        self.use_log_date("2026-10-08")
        latest = self.toolkit / "logs/probe.log"
        latest.parent.mkdir()
        latest.write_text("Existing restart error\n")
        yesterday = datetime(2026, 10, 7, 12, tzinfo=timezone.utc).timestamp()
        os.utime(latest, (yesterday, yesterday))
        result = self.run_script(self.probe("info new-run"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((latest.parent / "probe/2026-10-07.log").is_file())
        self.assertEqual((latest.parent / "probe/2026-10-07.log").read_text(),
            "Existing restart error\n")
        self.assertTrue(latest.is_symlink())
        self.assertIn("new-run", self.log())

    def test_retention_keeps_ninety_calendar_days_and_only_deletes_owned_log_files(self):
        self.use_log_date("2026-10-08")
        history = self.toolkit / "logs/probe"
        history.mkdir(parents=True)
        for name in ("2026-07-10.log", "2026-07-11.log", "2026-10-08.log", "notes.txt"):
            (history/name).write_text(name + "\n")
        other = self.toolkit / "logs/local-ai/2026-07-10.log"
        other.parent.mkdir()
        other.write_text("Other tool's log\n")
        outside = self.root / "unrelated.log"
        outside.write_text("Keep me\n")
        link = history / "2026-07-09.log"
        link.symlink_to(outside)
        result = self.run_script(self.probe("info new-run"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((history/"2026-07-10.log").exists())
        self.assertTrue((history/"2026-07-11.log").exists())
        self.assertIn("2026-10-08.log", self.log())
        self.assertTrue((history/"notes.txt").exists())
        self.assertTrue(other.exists())
        self.assertTrue(link.is_symlink())
        self.assertEqual(outside.read_text(), "Keep me\n")

    def test_failed_local_ai_run_remains_available_after_a_later_success(self):
        self.use_log_date("2026-10-08")
        failed = self.run_script(self.toolkit / "local-ai.sh", "update", SERVICE_EXIT="43")
        self.assertEqual(failed.returncode, 43, failed.stderr)
        result = self.run_script(self.toolkit / "local-ai.sh", "start")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("exit code 43", self.log("local-ai"))
        self.assertIn("Service action: start", self.log("local-ai"))

    def test_daily_logs_stay_private_across_privilege_modes(self):
        self.use_log_date("2026-10-08")
        path = self.probe("info mode-check")
        for uid in ("0", "1000"):
            result = self.run_script(path, TEST_EUID=uid)
            self.assertEqual(result.returncode, 0, result.stderr)
        history = self.toolkit / "logs/probe"
        self.assertTrue(history.is_dir())
        self.assertEqual(history.stat().st_mode & 0o777, 0o700)
        self.assertEqual((history/"2026-10-08.log").stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.log().count("mode-check"), 2)

    def test_legacy_migration_appends_without_overwriting_existing_daily_history(self):
        self.use_log_date("2026-10-08")
        history = self.toolkit / "logs/probe"
        history.mkdir(parents=True)
        daily_log = history / "2026-10-07.log"
        daily_log.write_text("Earlier history\n")
        legacy = self.toolkit / "logs/probe.log"
        legacy.write_text("Legacy history\n")
        yesterday = datetime(2026, 10, 7, 12, tzinfo=timezone.utc).timestamp()
        os.utime(legacy, (yesterday, yesterday))
        result = self.run_script(self.probe("info new-run"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(daily_log.read_text(), "Earlier history\nLegacy history\n")

    def test_failed_log_date_lookup_does_not_destroy_previous_log(self):
        legacy = self.toolkit / "logs/probe.log"
        legacy.parent.mkdir()
        legacy.write_text("Existing restart error\n")
        self.command("date", '#!/bin/sh\nexit 44\n')
        result = self.run_script(self.probe("info SHOULD_NOT_RUN"))
        self.assertEqual(result.returncode, 44, result.stderr)
        self.assertIn("Existing restart error", legacy.read_text())
        self.assertNotIn("SHOULD_NOT_RUN", legacy.read_text())

    def test_migrated_logs_older_than_the_retention_window_expire(self):
        self.use_log_date("2026-10-08")
        legacy = self.toolkit / "logs/probe.log"
        legacy.parent.mkdir()
        legacy.write_text("Expired legacy history\n")
        old_time = datetime(2026, 7, 10, 12, tzinfo=timezone.utc).timestamp()
        os.utime(legacy, (old_time, old_time))
        result = self.run_script(self.probe("info new-run"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((legacy.parent / "probe/2026-07-10.log").exists())
        self.assertNotIn("Expired legacy history", self.log())

    def test_levels_warning_count_and_command_streams_share_plain_log(self):
        result = self.run_script(self.probe('''
info 'first'
warn_condition 'one warning'
warn_note 'extra detail'
run /bin/bash -c 'echo command-output; echo command-error >&2'
show_completion_summary
'''))
        self.assertEqual(result.returncode, 0, result.stderr)
        log = self.log()
        self.assertRegex(log, r"\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\] \[INFO\] first")
        for text in ("[WARN] one warning", "[NOTE] extra detail", "command-output", "command-error",
                     "1 warning condition", "Total duration:"):
            self.assertIn(text, log)
        self.assertNotIn("\x1b", log)

    def test_error_preserves_status_and_removes_temporary_files(self):
        result = self.run_script(self.probe('''
create_temp_dir
printf 'scratch' > "$TMP_DIR/result"
run /bin/bash -c 'echo diagnostic; exit 42'
echo SHOULD_NOT_RUN
'''))
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertIn("exit code 42", self.log())
        self.assertIn("diagnostic", self.log())
        self.assertNotIn("SHOULD_NOT_RUN", result.stdout)
        self.assertEqual(list((self.toolkit / "logs").glob("maintenance.*")), [])

    def test_sudo_validation_and_argument_forwarding(self):
        path = self.probe('''
require_sudo
run_root /bin/printf '<%s>\\n' 'two words' '*literal*'
''')
        for uid in ("0", "1000"):
            with self.subTest(uid=uid):
                self.trace.unlink(missing_ok=True)
                result = self.run_script(path, TEST_EUID=uid)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("<two words>\n<*literal*>", self.log())
                if uid == "0":
                    self.assertFalse(self.trace.exists())
                else:
                    self.assertEqual(self.trace.read_text().splitlines()[0], "sudo:-v")

    def test_failed_authentication_cannot_start_a_service(self):
        result = self.run_script(self.toolkit / "local-ai.sh", "update", AUTH_EXIT="41")
        self.assertEqual(result.returncode, 41, result.stderr)
        self.assertEqual(self.trace.read_text(), "sudo:-v\n")
        self.assertIn("exit code 41", self.log("local-ai"))

    def test_local_ai_actions_keep_logs_in_both_privilege_modes(self):
        for uid in ("0", "1000"):
            for action in ("start", "stop", "update"):
                with self.subTest(uid=uid, action=action):
                    self.trace.unlink(missing_ok=True)
                    result = self.run_script(self.toolkit / "local-ai.sh", action, TEST_EUID=uid)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    log = self.log("local-ai")
                    self.assertIn("Service action: " + action, log)
                    self.assertIn("Service diagnostic", log)
                    self.assertIn("Total duration:", log)
                    trace = self.trace.read_text()
                    self.assertIn("service:" + action, trace)
                    self.assertEqual("sudo:" in trace, uid != "0")
                    self.assertEqual("browser:" in trace, uid != "0" and action == "start")

    def test_service_failure_is_logged_and_returned(self):
        result = self.run_script(self.toolkit / "local-ai.sh", "update", SERVICE_EXIT="43")
        self.assertEqual(result.returncode, 43, result.stderr)
        self.assertIn("exit code 43", self.log("local-ai"))
        self.assertNotIn("completed successfully", self.log("local-ai"))

    def test_browser_failure_is_a_warning_not_a_service_failure(self):
        result = self.run_script(self.toolkit / "local-ai.sh", "start", BROWSER_EXIT="7")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("[WARN]", self.log("local-ai"))
        self.assertIn("1 warning condition", self.log("local-ai"))

    def test_menu_exit_invalid_arguments_and_eof_preserve_previous_log(self):
        log = self.toolkit / "logs/local-ai.log"
        log.parent.mkdir()
        log.write_text("Previous run\n")
        for arguments, input_text, expected in (([], "4\n", 0), ([], "", 0),
                (["unknown"], "", 2), (["start", "extra"], "", 2)):
            result = self.run_script(self.toolkit / "local-ai.sh", *arguments, input=input_text)
            self.assertEqual(result.returncode, expected, result.stderr)
            self.assertEqual(log.read_text(), "Previous run\n")
        self.assertFalse(self.trace.exists())

    def test_noninteractive_confirmations_default_to_no(self):
        result = self.run_script(self.probe('''
if confirm 'Apply?'; then exit 91; fi
if confirm_phrase 'Remove packages?' 'APPLY'; then exit 92; fi
info 'No actions approved'
'''), input="y\nAPPLY\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("No actions approved", result.stdout)

    def system_feature_probe(self, body, tool="probe"):
        path = self.toolkit / "system-feature-probe.sh"
        source = (self.toolkit / "update-system.sh").read_text()
        self.assertTrue(source.rstrip().endswith('main "$@"'))
        # Load the real feature functions without executing system maintenance.
        definitions = source[:source.rfind('main "$@"')]
        path.write_text(definitions + '\ninitialize_runtime "$SCRIPT_DIR" ' + shlex.quote(tool) +
            ' "Test task"\ncreate_temp_dir\n' + body + "\n")
        return path

    def test_full_upgrade_with_removals_requires_exact_apply(self):
        self.command("apt-get", '''#!/bin/bash
if [[ "$*" == '--simulate dist-upgrade' ]]; then
    echo 'Remv old-driver [1.0]'
else
    printf 'apt:%s\\n' "$*" >> "$TRACE"
fi
''')
        path = self.system_feature_probe("handle_full_upgrade")
        for response in ("\n", "apply\n", "APPLY\n"):
            with self.subTest(response=response):
                self.trace.unlink(missing_ok=True)
                status, output = self.terminal_run(path, replies=(("Type APPLY", response),))
                self.assertEqual(status, 0, output)
                if response == "APPLY\n":
                    self.assertIn("apt:dist-upgrade -y", self.trace.read_text())
                else:
                    self.assertFalse(self.trace.exists(), output)

    def test_reboot_requires_explicit_yes(self):
        self.command("reboot", '#!/bin/sh\necho reboot >> "$TRACE"\n')
        self.command("sleep", '#!/bin/sh\nexit 0\n')
        path = self.system_feature_probe("REBOOT_RECOMMENDED=1\noffer_reboot")
        for response in ("\n", "y\n"):
            with self.subTest(response=response):
                self.trace.unlink(missing_ok=True)
                status, output = self.terminal_run(path, replies=(("[y/N]:", response),))
                self.assertEqual(status, 0, output)
                self.assertEqual(self.trace.exists(), response == "y\n")
                if self.trace.exists():
                    self.assertIn("reboot", self.trace.read_text().splitlines())

    def test_reboot_failure_keeps_diagnostic_and_status_in_both_launch_modes(self):
        self.command("reboot", '''#!/bin/sh
echo 'Restart refused: an application is blocking shutdown.' >&2
exit 42
''')
        self.command("sleep", '#!/bin/sh\nexit 0\n')
        path = self.system_feature_probe("REBOOT_RECOMMENDED=1\noffer_reboot", "reboot-test")
        for uid in ("0", "1000"):
            for desktop in (False, True):
                with self.subTest(uid=uid, desktop=desktop):
                    self.env["TEST_EUID"] = uid
                    status, output = self.terminal_run(path, desktop=desktop,
                        replies=(("[y/N]:", "y\n"),))
                    self.assertEqual(status, 42, output)
                    self.assertIn("Restart refused: an application is blocking shutdown.",
                        self.log("reboot-test"))
                    self.assertIn("Restart request failed", output)
                    self.assertNotIn("Restart request accepted", output)
                    self.assertEqual("Press Enter to exit" in output, desktop)

    def test_accepted_reboot_request_is_logged(self):
        self.command("reboot", '#!/bin/sh\nexit 0\n')
        self.command("sleep", '#!/bin/sh\nexit 0\n')
        path = self.system_feature_probe("REBOOT_RECOMMENDED=1\noffer_reboot")
        status, output = self.terminal_run(path, replies=(("[y/N]:", "y\n"),))
        self.assertEqual(status, 0, output)
        self.assertIn("Restart request accepted", self.log())

    def test_termination_cleans_temporary_files_and_releases_lock(self):
        ready = self.root / "ready"
        path = self.probe('create_temp_dir\n' + f'touch {shlex.quote(str(ready))}\n'
            'while true; do sleep 0.02; done')
        process = subprocess.Popen(["/bin/bash", str(path)], stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, env=self.env)
        try:
            deadline = time.monotonic() + 3
            while not ready.exists() and time.monotonic() < deadline and process.poll() is None:
                time.sleep(0.02)
            self.assertTrue(ready.exists())
            process.send_signal(signal.SIGTERM)
            output = process.communicate(timeout=3)
            self.assertEqual(process.returncode, 143, output)
            self.assertEqual(list((self.toolkit / "logs").glob("maintenance.*")), [])
            result = self.run_script(self.probe("info next-run"))
            self.assertEqual(result.returncode, 0, result.stderr)
        finally:
            if process.poll() is None:
                process.kill()
            process.communicate()

    def terminal_run(self, path, *, desktop=False, replies=(), interrupt=None):
        master, slave = pty.openpty()
        environment = {**self.env, "SCRIPT_PAUSE_ON_EXIT": "1" if desktop else "0"}
        process = subprocess.Popen(["/bin/bash", str(path)], stdin=slave, stdout=slave,
            stderr=slave, env=environment, close_fds=True)
        os.close(slave)
        output = b""
        try:
            pending = list(replies)
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                if select.select([master], [], [], 0.05)[0]:
                    try:
                        data = os.read(master, 4096)
                    except OSError as error:
                        if error.errno == errno.EIO:
                            break
                        raise
                    if not data:
                        break
                    output += data
                if pending and pending[0][0].encode() in output:
                    _, response = pending.pop(0)
                    os.write(master, response.encode())
                if interrupt is not None and b"SIGNAL_READY" in output:
                    process.send_signal(interrupt)
                    interrupt = None
                if desktop and b"Press Enter to exit" in output:
                    self.assertIsNone(process.poll())
                    self.assertEqual(list((self.toolkit / "logs").glob("maintenance.*")), [])
                    check = self.run_script(self.probe("info second-run", "probe"))
                    self.assertEqual(check.returncode, 0, check.stderr)
                    os.write(master, b"\n")
                    desktop = False
                if process.poll() is not None:
                    break
            return process.wait(timeout=1), output.decode(errors="replace")
        finally:
            if process.poll() is None:
                process.kill()
            process.wait()
            os.close(master)

    def test_cli_exits_and_desktop_pauses_after_releasing_resources(self):
        for desktop in (False, True):
            for status in (0, 42):
                with self.subTest(desktop=desktop, status=status):
                    path = self.probe(f"create_temp_dir\nrun /bin/bash -c 'exit {status}'")
                    result, output = self.terminal_run(path, desktop=desktop)
                    self.assertEqual(result, status, output)
                    self.assertEqual("Press Enter to exit" in output, desktop)

    def test_desktop_interruption_exits_without_waiting_for_enter(self):
        for signal_number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            with self.subTest(signal_number=signal_number):
                path = self.probe("create_temp_dir\ninfo SIGNAL_READY\nwhile true; do sleep 0.02; done")
                status, output = self.terminal_run(path, desktop=True, interrupt=signal_number)
                self.assertEqual(status, 128 + signal_number, output)
                self.assertNotIn("Press Enter to exit", output)
                self.assertEqual(list((self.toolkit / "logs").glob("maintenance.*")), [])

    def test_interactive_confirmations_require_yes_and_exact_phrase(self):
        path = self.probe('''
if confirm 'Proceed?'; then info approved; else info declined; fi
if confirm_phrase 'Remove?' 'APPLY'; then info removal-approved; else info removal-declined; fi
''')
        status, output = self.terminal_run(path, replies=(("[y/N]:", "\n"), ("Type APPLY", "apply\n")))
        self.assertEqual(status, 0, output)
        self.assertIn("declined", output)
        self.assertIn("removal-declined", output)
        status, output = self.terminal_run(path, replies=(("[y/N]:", "y\n"), ("Type APPLY", "APPLY\n")))
        self.assertEqual(status, 0, output)
        self.assertIn("[INFO] approved", output)
        self.assertIn("removal-approved", output)

    def test_concurrent_runs_cannot_overwrite_an_active_log(self):
        ready = self.root / "ready"
        release = self.root / "release"
        first = self.probe(f'info first-run\ntouch {shlex.quote(str(ready))}\n'
            f'while [[ ! -e {shlex.quote(str(release))} ]]; do sleep 0.02; done')
        first = first.rename(self.root / "first-run.sh")
        process = subprocess.Popen(["/bin/bash", str(first)], stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, env=self.env)
        second = None
        try:
            deadline = time.monotonic() + 3
            while not ready.exists() and time.monotonic() < deadline and process.poll() is None:
                time.sleep(0.02)
            self.assertTrue(ready.exists())
            second_path = self.probe("info second-run")
            second = subprocess.Popen(["/bin/bash", str(second_path)], stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, text=True, env=self.env)
            with self.assertRaises(subprocess.TimeoutExpired):
                second.communicate(timeout=0.2)
            self.assertIn("first-run", self.log())
            self.assertNotIn("second-run", self.log())
            release.touch()
            self.assertEqual(process.wait(timeout=3), 0)
            self.assertEqual(second.wait(timeout=3), 0)
            self.assertIn("second-run", self.log())
            self.assertIn("first-run", self.log())
        finally:
            release.touch()
            for child in (process, second):
                if child:
                    if child.poll() is None:
                        child.kill()
                    child.communicate()

    def test_day_rollover_waits_for_the_active_run_to_finish(self):
        self.use_log_date("2026-10-08")
        ready = self.root / "ready"
        release = self.root / "release"
        path = self.probe('info first-run\n' + f'touch {shlex.quote(str(ready))}\n' +
            f'while [[ ! -e {shlex.quote(str(release))} ]]; do sleep 0.02; done\ninfo first-finished')
        path = path.rename(self.root / "first-run.sh")
        first = subprocess.Popen(["/bin/bash", str(path)], stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, env=self.env)
        second = None
        try:
            deadline = time.monotonic() + 3
            while not ready.exists() and time.monotonic() < deadline and first.poll() is None:
                time.sleep(0.02)
            self.assertTrue(ready.exists())
            second_path = self.probe("info second-run")
            second = subprocess.Popen(["/bin/bash", str(second_path)], stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, text=True,
                env={**self.env, "LOG_TEST_DATE": "2026-10-09"})
            with self.assertRaises(subprocess.TimeoutExpired):
                second.communicate(timeout=0.2)
            self.assertEqual((self.toolkit / "logs/probe.log").resolve().name, "2026-10-08.log")
            release.touch()
            self.assertEqual(first.wait(timeout=3), 0)
            self.assertEqual(second.wait(timeout=3), 0)
            previous = (self.toolkit / "logs/probe/2026-10-08.log").read_text()
            self.assertIn("first-finished", previous)
            self.assertNotIn("second-run", previous)
            self.assertIn("second-run", self.log())
            self.assertNotIn("first-run", self.log())
        finally:
            release.touch()
            for child in (first, second):
                if child:
                    if child.poll() is None:
                        child.kill()
                    child.communicate()

    def test_waiting_across_midnight_keeps_the_run_start_date(self):
        clock_file = self.root / "clock-date"
        clock_file.write_text("2026-10-08\n")
        self.env["CLOCK_DATE_FILE"] = str(clock_file)
        self.command("date", '''#!/bin/bash
if [[ "$*" == '+%F' ]]; then
    cat "$CLOCK_DATE_FILE"
else
    exec /usr/bin/date "$@"
fi
''')
        logs = self.toolkit / "logs"
        logs.mkdir()
        with (logs / ".probe.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            process = subprocess.Popen(["/bin/bash", str(self.probe("info waited-run"))],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=self.env)
            try:
                with self.assertRaises(subprocess.TimeoutExpired):
                    process.communicate(timeout=0.2)
                clock_file.write_text("2026-10-09\n")
                fcntl.flock(lock, fcntl.LOCK_UN)
                output = process.communicate(timeout=3)
                self.assertEqual(process.returncode, 0, output)
                self.assertEqual((logs / "probe.log").resolve().name, "2026-10-08.log")
            finally:
                fcntl.flock(lock, fcntl.LOCK_UN)
                if process.poll() is None:
                    process.kill()
                process.communicate()


if __name__ == "__main__":
    unittest.main(verbosity=2)
