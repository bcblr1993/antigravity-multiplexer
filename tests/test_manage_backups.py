import json
import pathlib
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "Resources"))
from manage_backups import BackupManager
from create_instance import operation_lock


class BackupManagerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.support = pathlib.Path(self.temporary.name) / "support"
        self.root = self.support / "Backups"
        self.root.mkdir(parents=True)
        self.manager = BackupManager(self.support)

    def batch(self, name, archive="instance-2-app.zip"):
        path = self.root / name
        path.mkdir()
        with zipfile.ZipFile(path / archive, "w") as output:
            output.writestr("example.txt", "backup")
        return path

    def test_delete_only_selected_batch_and_clear_rollback_reference(self):
        older = self.batch("20260923-101038-559341")
        newer = self.batch("20260923-101143-864532")
        manifest = self.support / "instance-2.json"
        manifest.write_text(json.dumps({"index": 2, "upgrade_backup": str(newer)}))

        listed = self.manager.list()
        self.assertEqual([item["name"] for item in listed], [newer.name, older.name])
        self.assertTrue(listed[0]["referenced"])
        self.assertGreater(listed[0]["bytes"], 0)
        self.manager.delete(newer.name)

        self.assertTrue(older.exists())
        self.assertFalse(newer.exists())
        self.assertNotIn("upgrade_backup", json.loads(manifest.read_text()))

    def test_reject_traversal_and_unexpected_content(self):
        batch = self.batch("20260923-101038-559341")
        with self.assertRaises(RuntimeError):
            self.manager.delete("../support")
        (batch / "personal.txt").write_text("keep")
        self.assertFalse(self.manager.list()[0]["deletable"])
        with self.assertRaises(RuntimeError):
            self.manager.delete(batch.name)
        self.assertTrue((batch / "personal.txt").exists())

    def test_reject_symlinked_batch(self):
        outside = pathlib.Path(self.temporary.name) / "outside"
        outside.mkdir()
        (self.root / "20260923-101038-559341").symlink_to(outside, target_is_directory=True)
        with self.assertRaises(RuntimeError):
            self.manager.delete("20260923-101038-559341")
        self.assertTrue(outside.exists())

    def test_reject_delete_while_upgrade_lock_is_held(self):
        batch = self.batch("20260923-101038-559341")
        with operation_lock(self.support):
            with self.assertRaisesRegex(RuntimeError, "已有实例创建或升级"):
                self.manager.delete(batch.name)
        self.assertTrue(batch.exists())


if __name__ == "__main__":
    unittest.main()
