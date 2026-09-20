#!/usr/bin/env python3
"""Supervise the existing launcher; never send game input or change macOS settings."""

import argparse
import json
import math
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import tempfile
import time


PROJECT = Path(__file__).resolve().parents[1]
INT_MAX = 9223372036854775807
POLL_SECONDS = 0.1
STOP_GRACE_SECONDS = 15
SAFETY_PREFIX = "Safety check refused the action: "


def positive_integer(value):
    if not value.isascii() or not value.isdigit():
        raise argparse.ArgumentTypeError("必須是正整數")
    number = int(value)
    if not 1 <= number <= INT_MAX:
        raise argparse.ArgumentTypeError(f"必須介於 1 到 {INT_MAX}")
    return number


def positive_seconds(value):
    try:
        number = float(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("必須是正數") from error
    if not math.isfinite(number) or not 0 < number <= INT_MAX / 60:
        raise argparse.ArgumentTypeError("必須是有效且大於零的數值")
    return number


def arguments(argv=None):
    parser = argparse.ArgumentParser(
        description="自動練等外層重啟器：遇到可恢復的視窗／擷取錯誤時有限次重開。"
    )
    parser.add_argument("--max-restarts", type=int, default=3, choices=range(0, 21),
                        metavar="N", help="最多額外重啟次數，0–20，預設 3")
    parser.add_argument("--restart-delay", type=positive_seconds, default=10,
                        metavar="SECONDS", help="重啟前等待秒數，最多 300，預設 10")
    parser.add_argument("--max-cycles", "--cycles", type=positive_integer,
                        help="整輪各次執行報告的合計場次上限")
    parser.add_argument("--max-minutes", "--minutes", type=positive_seconds,
                        help="整輪時間上限（分鐘），含等待重啟時間")
    parser.add_argument("--window-id", type=positive_integer)
    parser.add_argument("--capture-level", choices=("error", "info"), default="error")
    parser.add_argument("--output-dir", type=Path, help="整輪紀錄的新目錄")
    parser.add_argument("--wait", action="store_true", help="相容參數；本重啟器一律在前景等待")
    parser.add_argument("--dry-run", action="store_true", help="預覽設定，不建立檔案或啟動 App")
    options = parser.parse_args(argv)
    if options.restart_delay > 300:
        parser.error("--restart-delay 不可超過 300 秒")
    if options.window_id is not None and options.window_id > 4294967295:
        parser.error("--window-id 不可超過 4294967295")
    return options


def retryable_reason(reason):
    # Never reinterpret an expired authorization, permission failure, or identity change as
    # a transient window problem. Normal/safety stops are excluded by the caller as well.
    if any(token in reason for token in (
        "actionExpired", "sessionExpired", "invalidClock", "identity changed", "permission",
    )):
        return False
    if reason.startswith("ScreenCaptureKit failed: "):
        return True
    if not reason.startswith(SAFETY_PREFIX):
        return False
    detail = reason[len(SAFETY_PREFIX):]
    if detail == "the iPhone Mirroring window moved or resized during automation":
        return True
    if detail.startswith((
        "the iPhone Mirroring window moved or resized before capture; ",
        "the window geometry changed immediately before input; ",
    )):
        return True
    bounded_recovery = detail.startswith((
        "the original iPhone Mirroring window did not become available with stable geometry ",
        "the original iPhone Mirroring window did not return with its locked geometry ",
    ))
    return bounded_recovery and any(token in detail for token in (
        "reason=geometryMismatch", "reason=missing",
    )) and any(token in detail for token in (
        "recoveryStop=attemptsExhausted", "recoveryStop=recoveryExpired",
    ))


def read_terminal_report(path):
    try:
        report = json.loads(path.read_text())
        if not isinstance(report, dict):
            raise ValueError("report is not an object")
        if report.get("status") not in ("completed", "stopped", "error"):
            raise ValueError("report is not terminal")
        for key in ("completedCycles", "actionsPosted"):
            if type(report.get(key)) is not int or report[key] < 0:
                raise ValueError(f"invalid {key}")
        for key in ("endedAt", "finalReason"):
            if not isinstance(report.get(key), str) or not report[key].strip():
                raise ValueError(f"missing {key}")
        return report
    except (OSError, ValueError) as error:
        raise ValueError(f"沒有完整的結束報告，無法確認能否重啟：{path}（{error}）") from error


def launcher_wait_completed(directory):
    try:
        receipt = json.loads((directory / ".launcher-wait.json").read_text())
        return isinstance(receipt, dict) and receipt.get("openWaitCompleted") is True
    except (OSError, ValueError):
        return False


def request_stop(path):
    # Do not truncate an existing STOP or follow a symlink supplied at this path.
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    os.close(descriptor)


class Supervisor:
    def __init__(self, options, directory):
        self.options = options
        self.directory = directory
        self.stop = directory / "STOP"
        self.started = time.monotonic()
        self.deadline = (self.started + options.max_minutes * 60
                         if options.max_minutes is not None else None)
        self.cancelled = False
        self.stop_reason = None
        self.active = None
        self.window_id = options.window_id
        self.report = {
            "status": "running", "finalReason": None, "completedCycles": 0,
            "cycleCountMeaning": "sum of run reports; a result seen again after restart may count twice",
            "restarts": 0, "attempts": [], "stopFile": str(self.stop),
        }

    def save(self):
        self.report["elapsedSeconds"] = time.monotonic() - self.started
        temporary = self.directory / "supervisor-report.json.tmp"
        temporary.write_text(json.dumps(self.report, ensure_ascii=False, indent=2) + "\n")
        temporary.replace(self.directory / "supervisor-report.json")

    def boundary(self):
        if self.stop_reason is not None:
            return self.stop_reason
        if self.cancelled or os.path.lexists(self.stop):
            self.stop_reason = "userStopRequested"
        elif self.active is not None and os.path.lexists(self.active / "STOP"):
            self.stop_reason = "childStopRequested"
        elif self.deadline is not None and time.monotonic() >= self.deadline:
            self.stop_reason = "maximumRuntimeReached"
        if self.stop_reason is not None:
            request_stop(self.stop)
        return self.stop_reason

    def finish(self, status, reason, exit_code):
        self.report.update(status=status, finalReason=reason)
        self.save()
        print(f"重啟器結束：{reason}；各次報告合計 {self.report['completedCycles']} 場", flush=True)
        return exit_code

    def launch_arguments(self, run_directory):
        command = ["/bin/zsh", str(PROJECT / "auto-level.zsh"), "--wait",
                   "--output-dir", str(run_directory), "--capture-level", self.options.capture_level]
        if self.window_id is not None:
            command += ["--window-id", str(self.window_id)]
        if self.options.max_cycles is not None:
            command += ["--max-cycles", str(self.options.max_cycles - self.report["completedCycles"])]
        if self.deadline is not None:
            # The parent enforces the exact shared deadline. This rounded-up child limit is
            # also useful if the supervisor is unexpectedly terminated.
            minutes = max(1, math.ceil((self.deadline - time.monotonic()) / 60))
            command += ["--max-minutes", str(minutes)]
        return command

    def run(self):
        for event in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(event, self.on_signal)
        self.save()
        print(f"整輪紀錄：{self.directory}", flush=True)
        print(f"停止指令：touch {shlex.quote(str(self.stop))}（也可按 Ctrl-C）", flush=True)
        for attempt in range(1, self.options.max_restarts + 2):
            if self.boundary():
                return self.finish("stopped", self.stop_reason, 0)
            self.active = self.directory / f"attempt-{attempt:03d}"
            self.report["restarts"] = attempt - 1
            self.report["activeRunDirectory"] = str(self.active)
            self.save()
            print(f"第 {attempt} 次執行；紀錄：{self.active}", flush=True)
            launcher_log = self.directory / f"attempt-{attempt:03d}.launcher.log"
            with launcher_log.open("xb") as output:
                # Ctrl-C belongs to the supervisor. Keep the launcher/open -W alive until
                # the App observes STOP and exits; killing a waiter does not stop the App.
                process = subprocess.Popen(self.launch_arguments(self.active), stdout=output,
                                           stderr=subprocess.STDOUT, start_new_session=True)
                stop_started = None
                while process.poll() is None:
                    if self.boundary():
                        if stop_started is None:
                            stop_started = time.monotonic()
                            print("已要求停止，等待本次 App 收尾；不會再重啟。", flush=True)
                        if self.active.is_dir():
                            request_stop(self.active / "STOP")
                        if time.monotonic() - stop_started >= STOP_GRACE_SECONDS:
                            # Reserve the directory if launch setup has not reached mkdir yet.
                            # A delayed launcher must either fail creation or observe this STOP.
                            self.active.mkdir(exist_ok=True)
                            request_stop(self.active / "STOP")
                            return self.finish("error", "stopPending: 尚未確認 App 結束，已保留 STOP，不會重啟", 1)
                    time.sleep(POLL_SECONDS)
            self.report["attempts"].append({"directory": str(self.active),
                                            "launcherExitCode": process.returncode})
            try:
                terminal = read_terminal_report(self.active / "run-report.json")
            except ValueError as error:
                return self.finish("stopped" if self.boundary() else "error",
                                   self.stop_reason or str(error), 0 if self.stop_reason else 1)
            self.report["attempts"][-1].update(
                status=terminal["status"], finalReason=terminal["finalReason"],
                completedCycles=terminal["completedCycles"], report=str(self.active / "run-report.json")
            )
            self.report["completedCycles"] += terminal["completedCycles"]
            self.save()
            if self.boundary():
                return self.finish("stopped", self.stop_reason, 0)
            if process.returncode not in (0, 1):
                return self.finish("error", f"launcherFailed: {process.returncode}；請查看 {launcher_log}", 1)
            if not launcher_wait_completed(self.active):
                return self.finish("error", f"尚未確認 open -W 正常完成；不會重啟，請查看 {launcher_log}", 1)
            if terminal["status"] in ("completed", "stopped"):
                if process.returncode != 0:
                    return self.finish("error", f"launcherFailed；請查看 {launcher_log}", 1)
                return self.finish(terminal["status"], terminal["finalReason"], 0)
            if process.returncode != 1 or not retryable_reason(terminal["finalReason"]):
                return self.finish("error", terminal["finalReason"], 1)
            if self.options.max_cycles is not None and self.report["completedCycles"] >= self.options.max_cycles:
                return self.finish("completed", "maximumCyclesReached", 0)
            if attempt > self.options.max_restarts:
                return self.finish("error", "maximumRestartsReached: " + terminal["finalReason"], 1)
            # Reuse the original window number, never silently select a different mirror.
            reported_window = terminal.get("window")
            reported_id = reported_window.get("windowID") if isinstance(reported_window, dict) else None
            if self.window_id is None:
                if type(reported_id) is not int or not 1 <= reported_id <= 4294967295:
                    return self.finish("error", "結束報告缺少視窗 ID，無法安全重啟", 1)
                self.window_id = reported_id
            elif type(reported_id) is not int or reported_id != self.window_id:
                return self.finish("error", "結束報告的視窗 ID 與指定視窗不符，不會重啟", 1)
            print(f"可恢復錯誤：{terminal['finalReason']}\n等待 {self.options.restart_delay:g} 秒後重啟。", flush=True)
            wake_at = time.monotonic() + self.options.restart_delay
            while time.monotonic() < wake_at:
                if self.boundary():
                    return self.finish("stopped", self.stop_reason, 0)
                time.sleep(min(POLL_SECONDS, max(0, wake_at - time.monotonic())))
        raise AssertionError("restart loop must terminate")

    def on_signal(self, _event, _frame):
        self.cancelled = True


def main(argv=None):
    options = arguments(argv)
    if options.dry_run:
        print(f"DRY RUN：最多額外重啟 {options.max_restarts} 次；每次等待 {options.restart_delay:g} 秒。")
        print("呼叫 auto-level.zsh --wait；整輪 STOP、時間及合計場次限制跨重啟保留。")
        return 0
    directory = options.output_dir
    try:
        if directory is None:
            logs = PROJECT / "logs"
            logs.mkdir(exist_ok=True)
            directory = Path(tempfile.mkdtemp(prefix="auto-level-restart-", dir=logs))
        else:
            directory = directory.expanduser().absolute()
            directory.mkdir(parents=True, exist_ok=False)
        return Supervisor(options, directory).run()
    except (OSError, ValueError) as error:
        print(f"重啟器錯誤：{error}；不會繼續啟動其他執行。", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
