#!/usr/bin/env python3
"""List and explicitly delete local upgrade backup batches."""
import argparse
import json
import os
import pathlib
import re
import shutil
import sys
import tempfile

from create_instance import APP_SUPPORT, operation_lock, require

BATCH_NAME = re.compile(r"\d{8}-\d{6}-\d{6}\Z")
ARCHIVE_NAME = re.compile(r"instance-\d+-(?:app|profile|window)\.zip\Z")


class BackupManager:
    def __init__(self, support=APP_SUPPORT):
        self.support = pathlib.Path(support)
        self.root = self.support / "Backups"

    def _root(self):
        require(not self.root.is_symlink(), "备份根目录是符号链接，停止操作")
        return self.root

    def _batch(self, name):
        require(BATCH_NAME.fullmatch(name) is not None, "备份批次名称无效")
        root = self._root()
        path = root / name
        require(root.is_dir() and path.is_dir() and not path.is_symlink(), "备份批次不存在或不是普通目录")
        require(path.resolve().parent == root.resolve(), "备份路径不在指定目录内")
        return path

    def _references(self):
        result = set()
        for manifest in self.support.glob("instance-*.json"):
            try:
                record = json.loads(manifest.read_text())
                value = record.get("upgrade_backup")
                if value:
                    result.add(pathlib.Path(value).resolve())
            except (OSError, ValueError, TypeError):
                continue
        return result

    def _info(self, path, references):
        archives = []
        deletable = True
        for child in path.iterdir():
            if child.name == ".DS_Store" or child.name.startswith("._"):
                continue
            if child.is_symlink() or not child.is_file() or not ARCHIVE_NAME.fullmatch(child.name):
                deletable = False
                continue
            archives.append(child)
        return {"name": path.name, "archiveCount": len(archives),
                "bytes": sum(item.stat().st_size for item in archives),
                "referenced": path.resolve() in references, "deletable": deletable}

    def list(self):
        root = self._root()
        if not root.is_dir():
            return []
        references = self._references()
        return [self._info(self._batch(path.name), references)
                for path in sorted(root.iterdir(), reverse=True)
                if path.is_dir() and not path.is_symlink() and BATCH_NAME.fullmatch(path.name)]

    def _clear_references(self, removed):
        for manifest in self.support.glob("instance-*.json"):
            try:
                record = json.loads(manifest.read_text())
                value = record.get("upgrade_backup")
                if not value or pathlib.Path(value).resolve() != removed:
                    continue
                record.pop("upgrade_backup", None)
                with tempfile.NamedTemporaryFile("w", dir=self.support, prefix="backup-manifest-",
                                                 suffix=".json", delete=False) as stream:
                    temporary = pathlib.Path(stream.name)
                    json.dump(record, stream, ensure_ascii=False, indent=2)
                os.replace(temporary, manifest)
            except (OSError, ValueError, TypeError):
                continue

    def delete(self, name):
        with operation_lock(self.support):
            path = self._batch(name)
            info = self._info(path, self._references())
            require(info["deletable"], "备份目录包含非预期文件，请先在访达检查")
            removed = path.resolve()
            shutil.rmtree(path)
            self._clear_references(removed)
            return info


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("list", "delete"))
    parser.add_argument("name", nargs="?")
    args = parser.parse_args()
    manager = BackupManager()
    try:
        if args.action == "list":
            print(json.dumps(manager.list(), ensure_ascii=False))
        else:
            require(args.name is not None, "请选择要删除的备份批次")
            info = manager.delete(args.name)
            print(f"已永久删除备份：{info['name']}（{info['archiveCount']} 个文件）")
    except Exception as error:
        print(f"备份操作失败：{error}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
