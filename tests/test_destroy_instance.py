import json
import pathlib
import plistlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "Resources"))
from create_instance import operation_lock
from destroy_instance import InstanceDestroyer


class DestroyInstanceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.home = pathlib.Path(self.temporary.name) / "home"
        self.apps = pathlib.Path(self.temporary.name) / "Applications"
        self.support = self.home / "Library/Application Support/Antigravity Multiplexer"
        self.apps.mkdir()
        self.home.mkdir()
        self.destroyer = InstanceDestroyer(self.home, self.support, [self.apps], lambda: [])

    def instance(self, index, word, bundle, key, manifest=False):
        name = "Antigravity " + word
        app = self.apps / (name + ".app")
        (app / "Contents/Resources/bin").mkdir(parents=True)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": bundle, "CFBundleDisplayName": name,
            "CFBundleURLTypes": [{"CFBundleURLSchemes": ["antigravity-" + (word.lower() if index < 8 else str(index))]}]}))
        (app / "Contents/Resources/bin/language_server").write_bytes(key.encode())
        profile = self.home / f".gemini-{index - 1}"
        profile.mkdir()
        (profile / "private.txt").write_text("profile")
        window = self.home / "Library/Application Support" / name
        window.mkdir(parents=True)
        logs = self.home / "Library/Logs" / name
        logs.mkdir(parents=True)
        credential = self.home / ".gemini" / key
        credential.parent.mkdir(exist_ok=True)
        credential.write_text("secret")
        if manifest:
            self.support.mkdir(parents=True, exist_ok=True)
            (self.support / f"instance-{index}.json").write_text(json.dumps({
                "index": index, "name": name, "app": str(app), "profile": str(profile)}))
        return app, profile, window, logs, credential

    def test_destroy_selected_legacy_instance_only_and_keep_backups(self):
        selected = self.instance(2, "Second", "local.antigravity.second", "second-standalone-oauth-token", True)
        other = self.instance(3, "Third", "local.antigravity.third", "thirdx-standalone-oauth-token")
        backup = self.support / "Backups/20260923-101143-864532/instance-2-profile.zip"
        backup.parent.mkdir(parents=True)
        backup.write_text("backup")
        name, count = self.destroyer.destroy(2, selected[0])
        self.assertEqual((name, count), ("Antigravity Second", 6))
        self.assertTrue(all(not path.exists() for path in selected))
        self.assertFalse((self.support / "instance-2.json").exists())
        self.assertTrue(all(path.exists() for path in other))
        self.assertTrue(backup.exists())

    def test_destroy_managed_instance_without_credential_file(self):
        selected = self.instance(8, "Eighth", "local.antigravity.instance8", "ag0008-standalone-oauth-token", True)
        selected[4].unlink()
        self.destroyer.destroy(8, selected[0])
        self.assertFalse(selected[0].exists())
        self.assertFalse(selected[1].exists())

    def test_reject_running_or_shared_credential(self):
        selected = self.instance(2, "Second", "local.antigravity.second", "second-standalone-oauth-token")
        self.destroyer.process_list = lambda: [str(selected[0] / "Contents/MacOS/Antigravity")]
        with self.assertRaisesRegex(RuntimeError, "仍在运行"):
            self.destroyer.destroy(2, selected[0])
        self.assertTrue(selected[0].exists())
        self.destroyer.process_list = lambda: []
        other_server = self.apps / "Antigravity Other.app/Contents/Resources/bin/language_server"
        other_server.parent.mkdir(parents=True)
        other_server.write_bytes(b"second-standalone-oauth-token")
        with self.assertRaisesRegex(RuntimeError, "其他实例引用"):
            self.destroyer.destroy(2, selected[0])
        self.assertTrue(selected[4].exists())

    def test_reject_main_identity_symlink_and_manifest_mismatch(self):
        selected = self.instance(2, "Second", "local.antigravity.second", "second-standalone-oauth-token", True)
        with self.assertRaisesRegex(RuntimeError, "主实例"):
            self.destroyer.destroy(1, selected[0])
        profile = selected[1]
        profile.rename(profile.with_name("actual"))
        profile.symlink_to(profile.with_name("actual"), target_is_directory=True)
        with self.assertRaisesRegex(RuntimeError, "符号链接"):
            self.destroyer.destroy(2, selected[0])
        profile.unlink()
        profile.with_name("actual").rename(profile)
        manifest = self.support / "instance-2.json"
        record = json.loads(manifest.read_text())
        record["profile"] = str(self.home / ".gemini")
        manifest.write_text(json.dumps(record))
        with self.assertRaisesRegex(RuntimeError, "清单"):
            self.destroyer.destroy(2, selected[0])
        self.assertTrue(selected[0].exists())

    def test_reject_while_operation_lock_held(self):
        selected = self.instance(2, "Second", "local.antigravity.second", "second-standalone-oauth-token")
        with operation_lock(self.support):
            with self.assertRaisesRegex(RuntimeError, "已有实例创建或升级"):
                self.destroyer.destroy(2, selected[0])
        self.assertTrue(selected[0].exists())


if __name__ == "__main__":
    unittest.main()
