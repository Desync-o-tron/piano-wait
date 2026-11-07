#!/usr/bin/env python3
"""Tests for upload_midi.py: python3 tools/test_upload_midi.py"""

import contextlib
import io
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import upload_midi  # noqa: E402


class UploadMidiTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.good = self.root / "good.mid"
        self.good.write_bytes(b"MThd\x00\x00\x00\x06")
        (self.root / "nested").mkdir()
        (self.root / "nested" / "also.MIDI").write_bytes(b"MThd")
        self.fake = self.root / "fake.mid"
        self.fake.write_bytes(b"not midi")
        self.text = self.root / "notes.txt"
        self.text.write_bytes(b"MThd")

    def test_expands_directories_recursively_and_rejects_fakes(self):
        files, problems = upload_midi.find_midi_files([str(self.root)])
        self.assertEqual({path.name for path in files}, {"good.mid", "also.MIDI"})
        self.assertEqual(len(problems), 1)
        self.assertIn("fake.mid", problems[0])

    def test_rejects_wrong_extension_and_missing_paths(self):
        files, problems = upload_midi.find_midi_files([str(self.text), str(self.root / "missing.mid")])
        self.assertEqual(files, [])
        self.assertEqual(len(problems), 2)

    def test_dry_run_uploads_nothing_and_names_the_destination(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            status = upload_midi.main(["--bucket", "example-piano-midis", "upload", str(self.good), "--dry-run", "--prefix", "classical"])
        self.assertEqual(status, 0)
        self.assertIn("gs://example-piano-midis/classical/good.mid", output.getvalue())

    def test_nothing_to_upload_is_a_failure(self):
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(upload_midi.main(["--bucket", "example-piano-midis", "upload", str(self.fake), "--dry-run"]), 1)


if __name__ == "__main__":
    unittest.main()
