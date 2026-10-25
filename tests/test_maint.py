"""Safe regression checks: all service and administrator commands are substituted."""

import errno
import fcntl
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

PROBE_MODULE = '''
MODULE_TITLE='Probe'
MODULE_ACTIONS=('work|Do probe work' 'wait|Wait for a signal' 'fail|Fail in a helper'
    'early|Summarize early' 'quit|Exit early')
action_work() {
    create_temp_dir
    info 'probe-work'
    run /bin/bash -c "exit ${PROBE_EXIT:-0}"
}
action_wait() {
    create_temp_dir
    info SIGNAL_READY
    while true; do sleep 0.02; done
}
action_fail() { fail_helper; }
fail_helper() { run /bin/bash -c 'exit 42'; }
action_early() { show_completion_summary; info after-summary; }
action_quit() { info leaving; exit 0; }
'''


class MaintTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="maint-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.maint_root = self.root / "maint with spaces"
        self.entry_point = self.maint_root / "maint"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        sources = [PROJECT / "maint", PROJECT / "completion.bash", *PROJECT.glob("lib/*.sh"),
            *PROJECT.glob("modules/*.sh")]
        for source in sources:
            target = self.maint_root / source.relative_to(PROJECT)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(source.read_text().replace("EUID", "TEST_EUID"))
        self.trace = self.root / "trace"
        self.env = {**os.environ, "PATH": str(self.bin) + ":/usr/bin:/bin",
            "TRACE": str(self.trace), "TEST_EUID": "1000", "NO_COLOR": "1"}
        self.command("sudo", '''#!/bin/bash
printf 'sudo:%s\\n' "$*" >> "$TRACE"
if [[ "$1" == -v ]]; then exit "${AUTH_EXIT:-0}"; fi
exec "$@"
''')

    def command(self, name, contents):
        path = self.bin / name
        path.write_text(contents)
        path.chmod(0o750)

    def add_probe_module(self):
        (self.maint_root / "modules/probe.sh").write_text(PROBE_MODULE)

    def probe(self, body, module="probe"):
        path = self.root / (module + "-probe.sh")
        path.write_text("#!/bin/bash\nset -Eeuo pipefail\nsource " +
            shlex.quote(str(self.maint_root / "lib/common.sh")) +
            "\ninitialize_runtime " + shlex.quote(module) + ' "Test task"\n' + body + "\n")
        return path

    def sys_module_probe(self, body, module="probe"):
        path = self.root / "sys-module-probe.sh"
        path.write_text("#!/bin/bash\nset -Eeuo pipefail\nsource " +
            shlex.quote(str(self.maint_root / "lib/common.sh")) + "\nsource " +
            shlex.quote(str(self.maint_root / "modules/sys.sh")) +
            "\ninitialize_runtime " + shlex.quote(module) + ' "Test task"\ncreate_temp_dir\n' + body + "\n")
        return path

    def run_script(self, path, *arguments, input="", **changes):
        return subprocess.run(["/bin/bash", str(path), *arguments], input=input, text=True,
            capture_output=True, timeout=6, cwd=self.root, env={**self.env, **changes})

    def maint(self, *arguments, input="", **changes):
        return self.run_script(self.entry_point, *arguments, input=input, **changes)

    def log(self, module="probe"):
        return (self.maint_root / "logs" / (module + ".log")).read_text()

    def temporary_folders(self):
        return list((self.maint_root / "logs").glob("maint.*"))

    def wait_for_lock(self, module="probe"):
        with (self.maint_root / "logs" / ("." + module + ".lock")).open("a") as lock:
            deadline = time.monotonic() + 3
            while True:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    fcntl.flock(lock, fcntl.LOCK_UN)
                    return
                except BlockingIOError:
                    self.assertLess(time.monotonic(), deadline, "lock was never released")
                    time.sleep(0.02)

    def use_log_date(self, day):
        self.env["LOG_TEST_DATE"] = day
        self.command("date", '''#!/bin/bash
if [[ "$*" == '+%F' ]]; then
    printf '%s\\n' "$LOG_TEST_DATE"
else
    exec /usr/bin/date "$@"
fi
''')

    def terminal_run(self, script, *arguments, replies=(), interrupt=None):
        """Runs a script on a terminal. A reply may be a function run before answering."""
        master, slave = pty.openpty()
        process = subprocess.Popen(["/bin/bash", str(script), *arguments],
            stdin=slave, stdout=slave, stderr=slave, env=self.env, close_fds=True,
            start_new_session=True)
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
                    prompt, response = pending.pop(0)
                    output = output.replace(prompt.encode(), b"<answered>", 1)
                    if callable(response):
                        response = response()
                    os.write(master, response.encode())
                if interrupt is not None and b"SIGNAL_READY" in output:
                    # A terminal delivers Ctrl+C and hangups to the whole foreground group.
                    os.killpg(process.pid, interrupt)
                    interrupt = None
                if process.poll() is not None:
                    break
            return process.wait(timeout=3), output.decode(errors="replace")
        finally:
            if process.poll() is None:
                process.kill()
            process.wait()
            os.close(master)

    def test_daily_logs_keep_every_run_and_roll_independently_for_each_module(self):
        self.use_log_date("2026-10-08")
        for module in ("sys", "probe"):
            with self.subTest(module=module):
                path = self.probe('info "Run: $1"', module)
                self.assertEqual(self.run_script(path, "first").returncode, 0)
                self.assertEqual(self.run_script(path, "second").returncode, 0)
                latest = self.maint_root / "logs" / (module + ".log")
                day_one = self.maint_root / "logs" / module / "2026-10-08.log"
                self.assertTrue(latest.is_symlink())
                self.assertEqual(latest.resolve(), day_one)
                original = day_one.read_text()
                self.assertIn("Run: first", original)
                self.assertIn("Run: second", original)
                result = self.run_script(path, "third", LOG_TEST_DATE="2026-10-09")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(day_one.read_text(), original)
                self.assertIn("Run: third", self.log(module))
                self.assertNotIn("Run: first", self.log(module))
                self.assertEqual(latest.resolve().name, "2026-10-09.log")

    def test_retention_keeps_ninety_calendar_days_and_only_deletes_owned_log_files(self):
        self.use_log_date("2026-10-08")
        history = self.maint_root / "logs/probe"
        history.mkdir(parents=True)
        for name in ("2026-07-10.log", "2026-07-11.log", "2026-10-08.log", "notes.txt"):
            (history/name).write_text(name + "\n")
        other = self.maint_root / "logs/other/2026-07-10.log"
        other.parent.mkdir()
        other.write_text("Other module's log\n")
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

    def test_failed_run_remains_available_after_a_later_success(self):
        self.use_log_date("2026-10-08")
        self.add_probe_module()
        failed = self.maint("probe", "work", PROBE_EXIT="43")
        self.assertEqual(failed.returncode, 43, failed.stderr)
        result = self.maint("probe", "work")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("exit code 43", self.log())
        self.assertIn("completed successfully", self.log())

    def test_daily_logs_stay_private_across_privilege_modes(self):
        self.use_log_date("2026-10-08")
        path = self.probe("info mode-check")
        for uid in ("0", "1000"):
            result = self.run_script(path, TEST_EUID=uid)
            self.assertEqual(result.returncode, 0, result.stderr)
        history = self.maint_root / "logs/probe"
        self.assertTrue(history.is_dir())
        self.assertEqual(history.stat().st_mode & 0o777, 0o700)
        self.assertEqual((history/"2026-10-08.log").stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.log().count("mode-check"), 2)

    def test_failed_date_lookup_stops_before_the_action_runs(self):
        self.command("date", '#!/bin/sh\nexit 44\n')
        result = self.run_script(self.probe("echo SHOULD_NOT_RUN"))
        self.assertEqual(result.returncode, 44, result.stderr)
        self.assertNotIn("SHOULD_NOT_RUN", result.stdout)

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
        self.assertRegex(log, r"\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\] \[INFO\] ===== Test task \| user ")
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
        self.assertEqual(self.temporary_folders(), [])

    def test_failure_log_names_the_failing_call_chain(self):
        self.add_probe_module()
        lines = PROBE_MODULE.split("\n")
        call_line = 1 + next(i for i, line in enumerate(lines) if line.startswith("action_fail()"))
        run_line = 1 + next(i for i, line in enumerate(lines) if line.startswith("fail_helper()"))
        result = self.maint("probe", "fail")
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertRegex(self.log(), r"Probe fail failed with exit code 42 at: "
            rf"action_fail \(probe\.sh:{call_line}\) > fail_helper \(probe\.sh:{run_line}\) > "
            r"run \(common\.sh:\d+\)")

    def test_failures_outside_commands_are_logged_once(self):
        for module, body, status in (("unset", 'info "value: ${NOT_SET}"', 1), ("exit", "exit 3", 3),
                ("command", "run /bin/bash -c 'exit 42'", 42)):
            with self.subTest(module=module):
                result = self.run_script(self.probe(body, module))
                self.assertEqual(result.returncode, status, result.stderr)
                self.assertEqual(self.log(module).count("Test task failed with exit code"), 1,
                    self.log(module))
                self.assertIn(f"failed with exit code {status}", self.log(module))

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

    def test_failed_authentication_stops_privileged_command(self):
        result = self.run_script(self.probe("require_sudo\nrun_root /bin/true"), AUTH_EXIT="41")
        self.assertEqual(result.returncode, 41, result.stderr)
        self.assertEqual(self.trace.read_text(), "sudo:-v\n")
        self.assertIn("exit code 41", self.log())

    def test_menu_exit_invalid_arguments_and_eof_preserve_previous_log(self):
        log = self.maint_root / "logs/sys.log"
        log.parent.mkdir()
        log.write_text("Previous run\n")
        for arguments, input_text, expected in (([], "0\n", 0), (["sys"], "0\n", 0),
                (["sys"], "", 0), (["sys"], "9\nx\n", 0), (["unknown"], "", 2),
                (["../lib/common"], "", 2), (["sys", "bogus"], "", 2),
                (["sys", "update", "extra"], "", 2)):
            with self.subTest(arguments=arguments, input_text=input_text):
                result = self.maint(*arguments, input=input_text)
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertEqual(log.read_text(), "Previous run\n")
        self.assertFalse(self.trace.exists())

    def test_unknown_names_list_the_valid_choices(self):
        for arguments, expected in (
                (["nope"], "Unknown module 'nope'. Choose from: docker, sys."),
                (["nope", "start"], "Unknown module 'nope'. Choose from: docker, sys."),
                (["sys", "nope"], "Unknown action 'nope' for sys. Choose from: update.")):
            with self.subTest(arguments=arguments):
                result = self.maint(*arguments)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn(expected, result.stderr)

    def test_tab_completion_offers_modules_then_their_actions(self):
        self.entry_point.chmod(0o750)
        (self.bin / "maint").symlink_to(self.entry_point)
        script = ("source " + shlex.quote(str(self.maint_root / "completion.bash")) +
            '\nCOMP_WORDS=("$@"); COMP_CWORD=$(($# - 1)); _maint; printf "%s\\n" "${COMPREPLY[@]}"')
        for words, expected in ((["maint", ""], ["help", "list", "docker", "sys"]),
                (["maint", "s"], ["sys"]), (["maint", "sys", "u"], ["update"]),
                (["maint", "sys", "update", ""], [""])):
            with self.subTest(words=words):
                result = subprocess.run(["/bin/bash", "-c", script, "completion", *words],
                    capture_output=True, text=True, timeout=6, env=self.env)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.split("\n")[:-1], expected)

    def test_modules_are_discovered_and_broken_modules_are_skipped(self):
        self.add_probe_module()
        (self.maint_root / "modules/broken.sh").write_text("MODULE_TITLE='Broken'\nMODULE_ACTIONS=('go|Go')\n")
        (self.maint_root / "modules/empty.sh").write_text("MODULE_TITLE='Empty'\n")
        (self.maint_root / "modules/help.sh").write_text(
            "MODULE_TITLE='Help'\nMODULE_ACTIONS=('go|Go')\naction_go() { info help-go; }\n")
        (self.maint_root / "modules/noisy.sh").write_text(
            "MODULE_TITLE='Noisy'\nMODULE_ACTIONS=('go|Go')\necho noise-at-load\naction_go() { :; }\n")
        help_text = self.maint("help")
        self.assertEqual(help_text.returncode, 0, help_text.stderr)
        self.assertIn("maint probe work", help_text.stdout)
        self.assertIn("maint sys update", help_text.stdout)
        self.assertNotIn("broken", help_text.stdout)
        self.assertIn("Skipping module broken.sh", help_text.stderr)
        self.assertIn("Skipping module empty.sh", help_text.stderr)
        self.assertNotIn("unbound", help_text.stderr)
        self.assertIn("Skipping module help.sh: help is a built-in command.", help_text.stderr)
        listing = self.maint("list")
        self.assertEqual(listing.returncode, 0, listing.stderr)
        self.assertIn("probe\twork\tProbe\tDo probe work\n", listing.stdout)
        self.assertIn("sys\tupdate\tSystem\t", listing.stdout)
        self.assertIn("noisy\tgo\tNoisy\tGo\n", listing.stdout)
        self.assertNotIn("noise-at-load", listing.stdout)
        self.assertNotIn("help\t", listing.stdout)
        self.assertNotIn("broken", listing.stdout)
        result = self.maint("probe", input="1\n0\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("probe-work", self.log())
        self.assertEqual(self.maint("broken", "go").returncode, 2)
        self.assertEqual(self.maint("help", "go").returncode, 2)

    def test_runner_summarizes_each_action_exactly_once(self):
        self.add_probe_module()
        for action, expected_tail in (("work", "probe-work"), ("early", "after-summary"),
                ("quit", "leaving")):
            with self.subTest(action=action):
                (self.maint_root / "logs/probe.log").unlink(missing_ok=True)
                for path in (self.maint_root / "logs/probe").glob("*.log"):
                    path.unlink()
                result = self.maint("probe", action)
                self.assertEqual(result.returncode, 0, result.stderr)
                log = self.log()
                self.assertEqual(log.count("completed successfully"), 1, log)
                self.assertEqual(log.count("Total duration:"), 1, log)
                self.assertIn(expected_tail, log)

    def test_noninteractive_confirmations_default_to_no(self):
        result = self.run_script(self.probe('''
if confirm 'Apply?'; then exit 91; fi
if confirm_phrase 'Remove packages?' 'APPLY'; then exit 92; fi
info 'No actions approved'
'''), input="y\nAPPLY\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("No actions approved", result.stdout)

    def test_full_upgrade_with_removals_requires_exact_apply(self):
        self.command("apt-get", '''#!/bin/bash
if [[ "$*" == '--simulate dist-upgrade' ]]; then
    echo 'Remv old-driver [1.0]'
else
    printf 'apt:%s\\n' "$*" >> "$TRACE"
fi
''')
        path = self.sys_module_probe("handle_full_upgrade")
        for response in ("\n", "apply\n", "APPLY\n"):
            with self.subTest(response=response):
                self.trace.unlink(missing_ok=True)
                status, output = self.terminal_run(path, replies=(("Type APPLY", response),))
                self.assertEqual(status, 0, output)
                if response == "APPLY\n":
                    self.assertIn("apt:dist-upgrade -y", self.trace.read_text())
                else:
                    self.assertFalse(self.trace.exists(), output)

    def test_disk_space_check_stops_below_the_configured_minimum(self):
        self.command("df", '''#!/bin/bash
if [[ "$1" == --output=avail ]]; then printf 'Avail\\n%s\\n' "$AVAIL_KIB"
else printf 'Filesystem Size Used Avail Use%% Mounted\\n/dev/x 9G 8G 1G 90%% /\\n'; fi
''')
        path = self.sys_module_probe("check_disk_space")
        for available_kib, status, message in ((1024 * 1024, 1, "Less than 2 GiB is free"),
                (3 * 1024 * 1024, 0, "Disk-space check passed.")):
            with self.subTest(available_kib=available_kib):
                result = self.run_script(path, AVAIL_KIB=str(available_kib))
                self.assertEqual(result.returncode, status, result.stderr)
                self.assertIn(message, self.log())

    def test_reboot_requires_explicit_yes(self):
        self.command("reboot", '#!/bin/sh\necho reboot >> "$TRACE"\n')
        self.command("sleep", '#!/bin/sh\nexit 0\n')
        path = self.sys_module_probe("REBOOT_RECOMMENDED=1\noffer_reboot")
        for response in ("\n", "y\n"):
            with self.subTest(response=response):
                self.trace.unlink(missing_ok=True)
                status, output = self.terminal_run(path, replies=(("[y/N]:", response),))
                self.assertEqual(status, 0, output)
                self.assertEqual(self.trace.exists(), response == "y\n")
                if self.trace.exists():
                    self.assertIn("reboot", self.trace.read_text().splitlines())

    def test_reboot_failure_keeps_diagnostic_and_status_in_both_privilege_modes(self):
        self.command("reboot", '''#!/bin/sh
echo 'Restart refused: an application is blocking shutdown.' >&2
exit 42
''')
        self.command("sleep", '#!/bin/sh\nexit 0\n')
        path = self.sys_module_probe("REBOOT_RECOMMENDED=1\noffer_reboot", "reboot-test")
        for uid in ("0", "1000"):
            with self.subTest(uid=uid):
                self.env["TEST_EUID"] = uid
                status, output = self.terminal_run(path, replies=(("[y/N]:", "y\n"),))
                self.assertEqual(status, 42, output)
                self.assertIn("Restart refused: an application is blocking shutdown.",
                    self.log("reboot-test"))
                self.assertIn("Restart request failed", output)
                self.assertNotIn("Restart request accepted", output)

    def test_accepted_reboot_request_is_logged(self):
        self.command("reboot", '#!/bin/sh\nexit 0\n')
        self.command("sleep", '#!/bin/sh\nexit 0\n')
        path = self.sys_module_probe("REBOOT_RECOMMENDED=1\noffer_reboot")
        status, output = self.terminal_run(path, replies=(("[y/N]:", "y\n"),))
        self.assertEqual(status, 0, output)
        self.assertIn("Restart request accepted", self.log())

    def test_termination_cleans_temporary_files_releases_lock_and_is_logged(self):
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
            self.assertEqual(self.temporary_folders(), [])
            self.assertIn("Test task was interrupted (SIGTERM)", self.log())
            result = self.run_script(self.probe("info next-run"))
            self.assertEqual(result.returncode, 0, result.stderr)
        finally:
            if process.poll() is None:
                process.kill()
            process.communicate()

    def test_menu_returns_after_each_action_with_resources_released(self):
        self.add_probe_module()
        for status in (0, 42):
            with self.subTest(status=status):
                self.env["PROBE_EXIT"] = str(status)
                second_run = []

                def check_released():
                    self.assertEqual(self.temporary_folders(), [])
                    second_run.append(self.run_script(self.probe("info second-run")))
                    return "\n"

                result, output = self.terminal_run(self.entry_point, "probe", replies=(
                    ("Choose [0-5]:", "1\n"),
                    ("Press Enter to return to the menu", check_released),
                    ("Choose [0-5]:", "0\n")))
                self.assertEqual(result, 0, output)
                self.assertEqual(second_run[0].returncode, 0, second_run[0].stderr)
                self.assertIn("probe-work", output)
                self.assertEqual("exit code 42" in output, status == 42)

    def test_direct_action_exits_without_pausing(self):
        self.add_probe_module()
        for status in (0, 42):
            with self.subTest(status=status):
                self.env["PROBE_EXIT"] = str(status)
                result, output = self.terminal_run(self.entry_point, "probe", "work")
                self.assertEqual(result, status, output)
                self.assertNotIn("Press Enter", output)

    def test_interrupted_menu_action_exits_after_cleanup_without_returning_to_the_menu(self):
        self.add_probe_module()
        for signal_number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            with self.subTest(signal_number=signal_number):
                status, output = self.terminal_run(self.entry_point, "probe",
                    replies=(("Choose [0-5]:", "2\n"),), interrupt=signal_number)
                self.assertEqual(status, 128 + signal_number, output)
                self.assertNotIn("Press Enter", output)
                self.wait_for_lock()
                self.assertEqual(self.temporary_folders(), [])
                self.assertIn("Probe wait was interrupted (" + signal.Signals(signal_number).name + ")",
                    self.log())

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
            _, second_errors = second.communicate(timeout=3)
            self.assertEqual(second.returncode, 0, second_errors)
            self.assertIn("Waiting up to 180 seconds for another Test task run to finish", second_errors)
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
            self.assertEqual((self.maint_root / "logs/probe.log").resolve().name, "2026-10-08.log")
            release.touch()
            self.assertEqual(first.wait(timeout=3), 0)
            self.assertEqual(second.wait(timeout=3), 0)
            previous = (self.maint_root / "logs/probe/2026-10-08.log").read_text()
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
        logs = self.maint_root / "logs"
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
