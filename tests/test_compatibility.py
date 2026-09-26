import json
import pathlib
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "Resources"))
from create_instance import KNOWN
from upgrade_all import source_info


class CompatibilityTests(unittest.TestCase):
    def test_unknown_version_is_rejected_before_signature_or_copy(self):
        with tempfile.TemporaryDirectory() as directory:
            source = pathlib.Path(directory)
            (source / "Contents").mkdir()
            (source / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "com.google.antigravity",
                "CFBundleShortVersionString": "999.0.0",
            }))
            with patch("upgrade_all.run") as run:
                with self.assertRaisesRegex(RuntimeError, "尚未经过适配验证"):
                    source_info(source)
                run.assert_not_called()

    def test_changed_source_hash_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            source = pathlib.Path(directory)
            resources = source / "Contents/Resources"
            resources.mkdir(parents=True)
            (source / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "com.google.antigravity",
                "CFBundleShortVersionString": "2.17.0",
            }))
            (resources / "app.asar").write_bytes(b"changed official source")
            with patch("upgrade_all.run") as run:
                run.return_value.stderr = "TeamIdentifier=EQHXZ8M8AV arm64"
                with self.assertRaisesRegex(RuntimeError, "ASAR 哈希不匹配"):
                    source_info(source)


if __name__ == "__main__":
    unittest.main()
