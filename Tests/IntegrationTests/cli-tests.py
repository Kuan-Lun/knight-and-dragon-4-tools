#!/usr/bin/env python3
"""Exercise the compiled CLI offline; no GUI, permissions, or input commands.

Usage: python3 Tests/IntegrationTests/cli-tests.py /path/to/mirror-probe
Only Python's standard library is required. Each subprocess has a timeout and
uses an isolated working directory. The real fixture is copied before use.
"""

import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib
from datetime import datetime


PROJECT_DIR = Path(__file__).resolve().parents[2]
FIXTURE = PROJECT_DIR / "Tests/MirrorProbeCoreTests/Fixtures/visual-result-latest-experience.png"
BINARY = None
UNKNOWN_COMMAND = "__integration_unknown_command__"


def png_bytes(width, height, pixel=(0, 0, 0, 255)):
    """Make a deterministic RGBA PNG without image libraries or external tools."""
    def chunk(kind, data):
        return (
            struct.pack(">I", len(data)) + kind + data
            + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
        )

    header = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    rows = (b"\x00" + bytes(pixel) * width) * height
    return (
        b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header)
        + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")
    )


class OfflineCLIIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="mirror-probe-cli-")
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name).resolve()
        self.input = self.work / "frame with spaces 'quote'.png"
        shutil.copyfile(FIXTURE, self.input)
        self.original_hash = hashlib.sha256(self.input.read_bytes()).hexdigest()
        self.report = self.work / "nested report directory" / "analysis result.json"

    def run_cli(self, *arguments, expected_exit=0):
        # Keep future additions offline as well. Live automation commands must
        # never enter this process suite, even with deliberately invalid options.
        allowed = {"help", "--help", "-h", "analyze-file", UNKNOWN_COMMAND}
        self.assertTrue(not arguments or arguments[0] in allowed)
        result = subprocess.run(
            [str(BINARY), *map(str, arguments)],
            cwd=self.work,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        self.assertEqual(
            result.returncode, expected_exit,
            f"Arguments: {arguments!r}\nstdout: {result.stdout}\nstderr: {result.stderr}",
        )
        self.assertEqual(hashlib.sha256(self.input.read_bytes()).hexdigest(), self.original_hash)
        return result

    def assert_failure(self, *arguments, diagnostic):
        result = self.run_cli(*arguments, expected_exit=1)
        self.assertEqual(result.stdout, "")
        self.assertIn("error: ", result.stderr)
        self.assertIn(diagnostic, result.stderr)
        self.assertFalse(self.report.exists(), "Invalid input must not produce an analysis report")
        return result

    def assert_report_contract(self, report, input_path):
        self.assertEqual(report["schemaVersion"], 3)
        self.assertEqual(report["command"], "analyze-file")
        self.assertEqual(report["profile"], "zh-Hant-v1")
        self.assertEqual(report["recognitionMode"], "visualRegions")
        datetime.fromisoformat(report["timestamp"].replace("Z", "+00:00"))
        self.assertEqual(set(report["source"]), {"kind", "path"})
        self.assertEqual(report["source"]["kind"], "file")
        # Foundation standardizes /private/var to /var on macOS.
        self.assertEqual(Path(report["source"]["path"]).resolve(), input_path.resolve())
        self.assertEqual(report["safety"], {
            "readOnly": True, "inputEventsPosted": 0, "actionAuthorization": "none",
        })
        encoded = input_path.read_bytes()
        width, height = struct.unpack(">II", encoded[16:24])
        layout = report["contentLayout"]
        self.assertEqual(set(layout), {
            "detected", "sourceWidth", "sourceHeight", "sourceContentX", "sourceContentY",
            "contentWidth", "contentHeight", "canvasWidth", "canvasHeight", "canvasContentX",
            "canvasContentY", "identity",
        })
        self.assertEqual((layout["sourceWidth"], layout["sourceHeight"]), (width, height))
        if layout["detected"]:
            # A detected border places the content on a reference-proportioned canvas.
            self.assertAlmostEqual(layout["canvasWidth"] / layout["canvasHeight"], 406 / 890, delta=0.01)
        else:
            self.assertTrue(layout["identity"])
            self.assertEqual((layout["canvasWidth"], layout["canvasHeight"]), (width, height))
        self.assertEqual(report["image"], {
            "width": width, "height": height, "orientation": "up",
            "pngSHA256": hashlib.sha256(encoded).hexdigest(),
        })
        self.assertEqual(report["ocr"], {
            "engine": "none", "requestRevision": 0, "recognitionLevel": "notUsed",
            "languages": [], "usesLanguageCorrection": False,
            "coordinateSpace": "normalizedTopLeft", "observations": [],
        })
        metrics = report["frameMetrics"]
        self.assertGreater(metrics["sampledPixels"], 0)
        for key in (
            "alphaCoverage", "nearBlackRatio", "meanLuminance",
            "luminanceStandardDeviation", "luminanceP05", "luminanceP95",
        ):
            self.assertGreaterEqual(metrics[key], 0, key)
            self.assertLessEqual(metrics[key], 1, key)
        self.assertIsInstance(report["classification"]["allowedActions"], list)
        self.assertIsInstance(report["classification"]["evidence"], list)

    def test_help_and_no_arguments(self):
        for arguments in ((), ("help",), ("--help",), ("-h",)):
            with self.subTest(arguments=arguments):
                result = self.run_cli(*arguments)
                self.assertIn("Usage:", result.stdout)
                self.assertIn("analyze-file --input IMAGE.png", result.stdout)
                self.assertEqual(result.stderr, "")
        self.assertEqual(list(self.work.iterdir()), [self.input])

    def test_unknown_command(self):
        self.assert_failure(UNKNOWN_COMMAND, diagnostic=f"Unknown command '{UNKNOWN_COMMAND}'")

    def test_real_fixture_to_json_report(self):
        result = self.run_cli(
            "analyze-file", "--input", self.input,
            "--report", self.report, "--profile", "zh-Hant-v1",
        )
        report = json.loads(result.stdout)
        self.assertEqual(result.stderr, "")
        self.assert_report_contract(report, self.input)
        self.assertEqual(json.loads(self.report.read_text()), report)
        self.assertEqual(report["status"], "classified")
        self.assertEqual(report["classification"]["state"], "missionCompleteRepeatSelected")
        self.assertEqual(
            [action["name"] for action in report["classification"]["allowedActions"]],
            ["advanceMissionComplete"],
        )
        self.assertGreaterEqual(report["frameMetrics"]["alphaCoverage"], 0.995)
        self.assertLess(report["frameMetrics"]["nearBlackRatio"], 0.98)

    def test_relative_input_without_report_has_no_output_files(self):
        result = self.run_cli("analyze-file", "--input", self.input.name)
        self.assert_report_contract(json.loads(result.stdout), self.input)
        self.assertEqual(list(self.work.iterdir()), [self.input])

    def test_blank_image_is_rejected_without_action(self):
        blank = self.work / "blank.png"
        blank.write_bytes(png_bytes(32, 64))
        result = self.run_cli("analyze-file", "--input", blank, "--report", self.report)
        report = json.loads(result.stdout)
        self.assert_report_contract(report, blank)
        self.assertEqual(report["status"], "rejected")
        self.assertEqual(report["classification"]["state"], "unknown")
        self.assertEqual(report["classification"]["allowedActions"], [])
        self.assertEqual(report["classification"]["evidence"], [])
        self.assertEqual(json.loads(self.report.read_text()), report)

    def test_missing_input_option(self):
        self.assert_failure("analyze-file", diagnostic="analyze-file requires --input IMAGE.png")

    def test_missing_option_value(self):
        for option in ("--input", "--report", "--profile"):
            with self.subTest(option=option):
                self.assert_failure("analyze-file", option, diagnostic=f"Option '{option}' requires a value")
                self.assert_failure(
                    "analyze-file", option, "--not-a-value",
                    diagnostic=f"Option '{option}' requires a value",
                )

    def test_unknown_option_and_positional_argument(self):
        self.assert_failure("analyze-file", "--typo", diagnostic="Unknown option '--typo'")
        self.assert_failure("analyze-file", "frame.png", diagnostic="Unexpected positional argument 'frame.png'")

    def test_duplicate_options(self):
        for option, value in (
            ("--input", self.input), ("--report", self.report), ("--profile", "zh-Hant-v1"),
        ):
            with self.subTest(option=option):
                self.assert_failure(
                    "analyze-file", option, value, option, value,
                    diagnostic=f"Option '{option}' may only be supplied once",
                )

    def test_profile_cannot_change_thresholds(self):
        self.assert_failure(
            "analyze-file", "--input", self.input, "--profile", "unrestricted",
            diagnostic="--profile must be zh-Hant-v1; confidence thresholds cannot be lowered",
        )

    def test_missing_input_file(self):
        self.assert_failure(
            "analyze-file", "--input", self.work / "absent.png", "--report", self.report,
            diagnostic="could not open a readable regular PNG without following a symbolic link",
        )

    def test_report_cannot_replace_input_or_path_alias(self):
        aliases = [self.input, self.work / "unused" / ".." / self.input.name]
        symlink = self.work / "input-alias.png"
        symlink.symlink_to(self.input)
        aliases.append(symlink)
        for output in aliases:
            with self.subTest(output=output):
                self.assert_failure(
                    "analyze-file", "--input", self.input, "--report", output,
                    diagnostic="--input and --report must refer to different files",
                )

    def test_symbolic_link_input_is_rejected(self):
        alias = self.work / "symlink.png"
        alias.symlink_to(self.input)
        self.assert_failure(
            "analyze-file", "--input", alias, "--report", self.report,
            diagnostic="could not open a readable regular PNG without following a symbolic link",
        )

    def test_directory_and_fifo_are_rejected_without_blocking(self):
        fifo = self.work / "pipe.png"
        os.mkfifo(fifo)
        for path in (self.work, fifo):
            with self.subTest(path=path):
                self.assert_failure(
                    "analyze-file", "--input", path, "--report", self.report,
                    diagnostic="the opened input is not a regular file",
                )

    def test_empty_and_oversized_files(self):
        invalid = self.work / "invalid-size.png"
        for size in (0, 50 * 1024 * 1024 + 1):
            with self.subTest(size=size):
                with invalid.open("wb") as output:
                    output.truncate(size)
                self.assert_failure(
                    "analyze-file", "--input", invalid, "--report", self.report,
                    diagnostic="PNG must be between 1 byte and 50 MiB",
                )

    def test_corrupt_png(self):
        corrupt = self.work / "corrupt.png"
        for data in (b"not an image", b"\x89PNG\r\n\x1a\ninvalid truncated image"):
            with self.subTest(data=data):
                corrupt.write_bytes(data)
                self.assert_failure(
                    "analyze-file", "--input", corrupt, "--report", self.report,
                    diagnostic="Could not load the input image:",
                )

    def test_non_png_image(self):
        other_format = self.work / "actually-a-gif.png"
        other_format.write_bytes(bytes.fromhex(
            "47494638396101000100800000000000ffffff21f90401000000002c"
            "00000000010001000002024401003b"
        ))
        self.assert_failure(
            "analyze-file", "--input", other_format, "--report", self.report,
            diagnostic="only PNG input is accepted",
        )

    def test_png_dimension_limit(self):
        oversized = self.work / "too-wide.png"
        oversized.write_bytes(png_bytes(10001, 1))
        self.assert_failure(
            "analyze-file", "--input", oversized, "--report", self.report,
            diagnostic="PNG dimensions must be at most 10,000 pixels per side and 25 megapixels",
        )


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("Usage: python3 Tests/IntegrationTests/cli-tests.py /path/to/mirror-probe")
    BINARY = Path(sys.argv[1]).resolve()
    if not BINARY.is_file() or not os.access(BINARY, os.X_OK):
        sys.exit(f"Executable not found: {BINARY}")
    unittest.main(argv=[sys.argv[0]], verbosity=2)
