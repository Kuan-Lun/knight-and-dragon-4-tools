#!/usr/bin/env python3
"""Exercise the restart supervisor without launching an app or sending input."""

from __future__ import annotations

import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest


PROJECT = Path(__file__).resolve().parents[2]
GEOMETRY_ERROR = (
    "Safety check refused the action: the iPhone Mirroring window moved or resized "
    "during automation"
)

FAKE_RUNNER = r'''
import json
import os
from pathlib import Path
import signal
import sys
import time

project = Path(__file__).resolve().parent
arguments = sys.argv[1:]
options = {}
index = 0
while index < len(arguments):
    argument = arguments[index]
    if argument in ("--wait", "--confirm-no-talisman", "--no-talisman"):
        options[argument] = True
        index += 1
    elif "=" in argument:
        key, value = argument.split("=", 1)
        options[key] = value
        index += 1
    else:
        options[argument] = arguments[index + 1]
        index += 2

output = Path(options["--output-dir"])
output.mkdir(parents=True, exist_ok=False)
call_file = project / "calls.jsonl"
existing = call_file.read_text().splitlines() if call_file.exists() else []
scenario = json.loads((project / "scenario.json").read_text())
step = scenario[min(len(existing), len(scenario) - 1)]
with call_file.open("a") as handle:
    handle.write(json.dumps({"arguments": arguments, "options": options,
                             "output": str(output), "started": time.monotonic()}) + "\n")
Path(str(output) + ".stdout.log").write_text("stdout for " + output.name + "\n")
Path(str(output) + ".stderr.log").write_text("stderr for " + output.name + "\n")

def unexpected_signal(number, _frame):
    (project / "unexpected-child-signal").write_text(str(number))
    sys.exit(90)

signal.signal(signal.SIGINT, unexpected_signal)
signal.signal(signal.SIGTERM, unexpected_signal)
signal.signal(signal.SIGHUP, unexpected_signal)

report = {
    "schemaVersion": 5,
    "status": step.get("status", "completed"),
    "completedCycles": step.get("cycles", 1),
    "actionsPosted": step.get("actions", 1),
    "startedAt": "2026-09-16T01:00:00Z",
    "endedAt": "2026-09-16T01:00:01Z",
    "finalReason": step.get("reason", "maximumCyclesReached(limit: 1)"),
    "outputDirectory": str(output),
    "stopFile": str(output / "STOP"),
    "window": {"processID": 6891, "windowID": 169,
               "bundleIdentifier": "com.apple.ScreenContinuity"},
    "events": [],
}
report.update(step.get("report_fields", {}))
for name in step.get("omit", []):
    report.pop(name, None)
report_path = output / "run-report.json"

def write_report(value):
    temporary = output / "report.tmp"
    temporary.write_text(json.dumps(value))
    temporary.replace(report_path)

if step.get("wait_stop"):
    checkpoint = dict(report, status="running", endedAt=None, finalReason=None)
    write_report(checkpoint)
    deadline = time.monotonic() + 5
    while not (output / "STOP").exists():
        if time.monotonic() >= deadline:
            sys.exit(91)
        time.sleep(0.01)
    report.update(status="stopped", finalReason="stopFileDetected")
    (project / "child-observed-stop").write_text(str(output))
time.sleep(step.get("delay", 0))
if step.get("touch_stop"):
    (output / "STOP").touch()
if step.get("malformed"):
    report_path.write_text("{broken-json")
elif not step.get("no_report"):
    write_report(report)
if not step.get("omit_wait_receipt"):
    (output / ".launcher-wait.json").write_text(json.dumps(
        step.get("wait_receipt", {"openWaitCompleted": True})
    ))
sys.exit(step.get("exit", 1 if report["status"] == "error" else 0))
'''


class RestartSupervisorTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="auto-level-restart-tests.")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "isolated project"
        (self.root / "Scripts").mkdir(parents=True)
        for source in ("auto-level-restart.zsh", "Scripts/auto-level-supervisor.py"):
            shutil.copy2(PROJECT / source, self.root / source)
        (self.root / "fake-runner.py").write_text(FAKE_RUNNER)
        (self.root / "auto-level.zsh").write_text(
            "#!/bin/zsh\nexec " + shlex.quote(sys.executable) + " "
            + shlex.quote(str(self.root / "fake-runner.py")) + ' "$@"\n'
        )
        self.output = self.root / "session output"
        self.processes = []
        self.addCleanup(self.clean_processes)

    def clean_processes(self):
        for process in self.processes:
            if process.poll() is None:
                self.output.mkdir(parents=True, exist_ok=True)
                (self.output / "STOP").touch()
                try:
                    process.communicate(timeout=7)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.communicate(timeout=2)

    def configure(self, steps):
        (self.root / "scenario.json").write_text(json.dumps(steps))

    def command(self, *arguments):
        return ["/bin/zsh", str(self.root / "auto-level-restart.zsh"),
                "--output-dir", str(self.output), "--restart-delay", "0.05", *arguments]

    def start(self, *arguments):
        process = subprocess.Popen(
            self.command(*arguments), cwd=self.root,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            start_new_session=True,
        )
        self.processes.append(process)
        return process

    def finish(self, process, expected=0):
        stdout, stderr = process.communicate(timeout=8)
        self.assertEqual(process.returncode, expected, stdout + stderr)
        return stdout + stderr

    def run_supervisor(self, steps, *arguments, expected=0):
        self.configure(steps)
        return self.finish(self.start(*arguments), expected)

    def calls(self):
        path = self.root / "calls.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def report(self):
        return json.loads((self.output / "supervisor-report.json").read_text())

    def await_condition(self, predicate, process):
        deadline = time.monotonic() + 4
        while time.monotonic() < deadline:
            if predicate():
                return
            if process.poll() is not None:
                stdout, stderr = process.communicate()
                self.fail("Supervisor exited before expected checkpoint: " + stdout + stderr)
            time.sleep(0.01)
        self.fail("Supervisor did not reach the expected checkpoint")

    def test_geometry_failure_restarts_with_independent_retained_logs(self):
        self.run_supervisor([
            {"status": "error", "reason": GEOMETRY_ERROR, "cycles": 2},
            {"status": "completed", "cycles": 3},
        ], "--max-restarts", "1", "--window-id", "169", "--capture-level", "info", "--wait")
        calls = self.calls()
        self.assertEqual(len(calls), 2)
        self.assertNotEqual(calls[0]["output"], calls[1]["output"])
        for call in calls:
            self.assertTrue(call["options"]["--wait"])
            self.assertEqual(call["options"]["--window-id"], "169")
            self.assertEqual(call["options"]["--capture-level"], "info")
            self.assertTrue(Path(call["output"], "run-report.json").is_file())
            self.assertTrue(Path(call["output"] + ".stdout.log").is_file())
            self.assertTrue(Path(call["output"] + ".stderr.log").is_file())
        report = self.report()
        self.assertEqual(report["status"], "completed")
        self.assertEqual(report["completedCycles"], 5)
        self.assertEqual(report["restarts"], 1)
        self.assertEqual(len(report["attempts"]), 2)

    def test_retry_cap_applies_to_total_restarts(self):
        self.run_supervisor([{"status": "error", "reason": GEOMETRY_ERROR, "cycles": 0}],
                            "--max-restarts", "2", expected=1)
        self.assertEqual(len(self.calls()), 3)
        self.assertEqual(self.report()["restarts"], 2)
        self.assertEqual(self.report()["status"], "error")

    def test_safety_stop_is_not_restarted(self):
        self.run_supervisor([{"status": "stopped",
                              "reason": "uncertainStateExceededGrace(kind: unknown)"}])
        self.assertEqual(len(self.calls()), 1)
        self.assertEqual(self.report()["status"], "stopped")

    def test_unknown_and_permission_errors_are_not_restarted(self):
        for reason in ("Unexpected internal failure", "Screen recording permission is required",
                       "Accessibility permission is required"):
            with self.subTest(reason=reason):
                self.output = self.root / ("error output " + str(len(self.calls())))
                previous = len(self.calls())
                self.run_supervisor([{"status": "error", "reason": reason}], expected=1)
                self.assertEqual(len(self.calls()), previous + 1)

    def test_invalid_or_unfinished_reports_are_not_restarted(self):
        variants = [
            {"status": "running", "reason": GEOMETRY_ERROR, "exit": 1},
            {"malformed": True, "exit": 1},
            {"no_report": True, "exit": 1},
            {"status": "error", "reason": GEOMETRY_ERROR, "omit": ["endedAt"]},
            {"status": "error", "reason": GEOMETRY_ERROR, "cycles": True},
            {"status": "error", "reason": GEOMETRY_ERROR, "actions": -1},
            {"status": "error", "reason": GEOMETRY_ERROR, "report_fields": {"window": None}},
            {"status": "error", "reason": GEOMETRY_ERROR, "report_fields": {"window": []}},
            {"status": "error", "reason": GEOMETRY_ERROR, "omit_wait_receipt": True},
            {"status": "error", "reason": GEOMETRY_ERROR,
             "wait_receipt": {"openWaitCompleted": False}},
        ]
        for index, step in enumerate(variants):
            with self.subTest(step=step):
                self.output = self.root / ("invalid report " + str(index))
                previous = len(self.calls())
                self.run_supervisor([step], expected=1)
                self.assertEqual(len(self.calls()), previous + 1)
                self.assertEqual(self.report()["status"], "error")

    def test_error_report_requires_error_exit_before_retry(self):
        self.run_supervisor([{"status": "error", "reason": GEOMETRY_ERROR, "exit": 0}], expected=1)
        self.assertEqual(len(self.calls()), 1)

    def test_cycle_limit_is_reduced_by_raw_counts_across_restarts(self):
        self.run_supervisor([
            {"status": "error", "reason": GEOMETRY_ERROR, "cycles": 2},
            {"status": "completed", "cycles": 3},
        ], "--cycles", "5")
        calls = self.calls()
        self.assertEqual([call["options"]["--max-cycles"] for call in calls], ["5", "3"])
        self.assertEqual(self.report()["completedCycles"], 5)

    def test_global_deadline_includes_restart_delay(self):
        self.configure([{"status": "error", "reason": GEOMETRY_ERROR, "cycles": 0}])
        command = self.command("--minutes", "0.005")
        command[command.index("--restart-delay") + 1] = "1"
        started = time.monotonic()
        process = subprocess.Popen(command, cwd=self.root, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True, start_new_session=True)
        self.processes.append(process)
        self.finish(process)
        self.assertLess(time.monotonic() - started, 3)
        self.assertEqual(len(self.calls()), 1)
        self.assertEqual(self.report()["status"], "stopped")

    def test_parent_stop_is_forwarded_to_active_run(self):
        self.configure([{"wait_stop": True, "cycles": 0}])
        process = self.start()
        self.await_condition(lambda: bool(self.calls()), process)
        (self.output / "STOP").touch()
        self.finish(process)
        self.assertTrue((self.root / "child-observed-stop").is_file())
        self.assertTrue(Path(self.calls()[0]["output"], "STOP").exists())
        self.assertEqual(len(self.calls()), 1)
        self.assertEqual(self.report()["status"], "stopped")

    def test_global_deadline_stops_active_child(self):
        self.run_supervisor([{"wait_stop": True, "cycles": 0}], "--max-minutes", "0.005")
        self.assertEqual(len(self.calls()), 1)
        self.assertTrue((self.root / "child-observed-stop").is_file())
        self.assertTrue(Path(self.calls()[0]["output"], "STOP").exists())
        self.assertEqual(self.report()["status"], "stopped")

    def test_stop_during_retry_delay_prevents_next_attempt(self):
        self.configure([{"status": "error", "reason": GEOMETRY_ERROR, "cycles": 0}])
        command = self.command()
        command[command.index("--restart-delay") + 1] = "1"
        process = subprocess.Popen(command, cwd=self.root, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True, start_new_session=True)
        self.processes.append(process)
        self.await_condition(lambda: bool(self.calls()) and
                             Path(self.calls()[0]["output"], "run-report.json").is_file(), process)
        time.sleep(0.1)
        (self.output / "STOP").touch()
        self.finish(process)
        self.assertEqual(len(self.calls()), 1)

    def test_attempt_stop_file_wins_over_retryable_error(self):
        self.run_supervisor([{"status": "error", "reason": GEOMETRY_ERROR,
                              "touch_stop": True, "cycles": 0}])
        self.assertEqual(len(self.calls()), 1)
        self.assertEqual(self.report()["status"], "stopped")

    def test_terminal_ctrl_c_uses_stop_and_does_not_signal_child(self):
        self.configure([{"wait_stop": True, "cycles": 0}])
        process = self.start()
        self.await_condition(lambda: bool(self.calls()) and
                             Path(self.calls()[0]["output"], "run-report.json").is_file(), process)
        os.killpg(process.pid, signal.SIGINT)
        self.finish(process)
        self.assertTrue((self.root / "child-observed-stop").is_file())
        self.assertFalse((self.root / "unexpected-child-signal").exists())
        self.assertEqual(len(self.calls()), 1)
        self.assertEqual(self.report()["status"], "stopped")

    def test_dry_run_creates_nothing_and_launches_nothing(self):
        self.run_supervisor([{"status": "error", "reason": "must not run"}],
                            "--max-restarts", "0", "--dry-run")
        self.assertFalse(self.output.exists())
        self.assertFalse((self.root / "calls.jsonl").exists())

    def test_invalid_flags_are_rejected_before_creating_output(self):
        self.configure([{}])
        invalid_options = [
            ("--max-restarts", "-1"), ("--max-restarts", "21"),
            ("--max-cycles", "0"), ("--max-cycles", "9223372036854775808"),
            ("--max-minutes", "0"), ("--max-minutes", "inf"),
            ("--restart-delay", "0"), ("--restart-delay", "301"),
            ("--capture-level", "debug"), ("--window-id", "0"), ("--unknown",),
        ]
        for options in invalid_options:
            with self.subTest(options=options):
                command = self.command()
                if options[0] == "--restart-delay":
                    del command[-2:]
                process = subprocess.Popen(command + list(options), cwd=self.root,
                                           stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                           text=True, start_new_session=True)
                self.processes.append(process)
                self.finish(process, expected=2)
                self.assertFalse(self.output.exists())
                self.assertFalse((self.root / "calls.jsonl").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
