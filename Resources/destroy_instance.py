#!/usr/bin/env python3
"""Permanently remove one verified local clone and its isolated data."""
import argparse
import json
import os
import pathlib
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

from create_instance import APP_SUPPORT, operation_lock, ordinal_name, require

KEY_PATTERN = re.compile(rb"[a-z0-9-]{6}-standalone-oauth-token")
LEGACY = {2: "second", 3: "third", 4: "fourth", 5: "fifth", 6: "sixth", 7: "seventh"}


class InstanceDestroyer:
    def __init__(self, home=None, support=None, roots=None, process_list=None):
        self.home = pathlib.Path(home) if home is not None else pathlib.Path.home()
        self.support = pathlib.Path(support) if support is not None else APP_SUPPORT
        self.roots = [pathlib.Path(root) for root in (roots or [pathlib.Path("/Applications"), self.home / "Applications"])]
        self.process_list = process_list or (lambda: subprocess.check_output(["ps", "-axo", "comm="], text=True).splitlines())

    @staticmethod
    def _ordinary(path, directory):
        require(not path.is_symlink(), f"路径是符号链接，停止销毁：{path}")
        if path.exists():
            require(path.is_dir() if directory else path.is_file(), f"路径类型异常：{path}")

    @staticmethod
    def _key(app):
        server = app / "Contents/Resources/bin/language_server"
        require(server.is_file() and not server.is_symlink(), "实例语言服务文件异常")
        keys = set(KEY_PATTERN.findall(server.read_bytes())) - {b"jetski-standalone-oauth-token"}
        require(len(keys) == 1, "无法确认此实例的独立凭据标识")
        return keys.pop().decode("ascii")

    def _inspect(self, index, app):
        require(2 <= index <= 9999, "不能销毁主实例或无效编号")
        name = "Antigravity " + ordinal_name(index)
        require(app.name == name + ".app" and ".." not in app.parts, "应用名称或路径不符合实例规范")
        require(any(app == root / app.name and root.is_dir() and not root.is_symlink() for root in self.roots),
                "应用不在允许的安装目录")
        self._ordinary(app, True)
        require(app.is_dir(), "实例应用不存在")
        info_path = app / "Contents/Info.plist"
        require(info_path.is_file() and not info_path.is_symlink(), "实例应用身份文件异常")
        info = plistlib.loads(info_path.read_bytes())
        bundle = "local.antigravity." + (LEGACY[index] if index in LEGACY else f"instance{index}")
        require(info.get("CFBundleIdentifier") == bundle and info.get("CFBundleDisplayName") == name,
                "应用身份与所选实例不一致")
        scheme = "antigravity-" + (LEGACY[index] if index in LEGACY else str(index))
        schemes = [value for item in info.get("CFBundleURLTypes", []) for value in item.get("CFBundleURLSchemes", [])]
        require(scheme in schemes, "实例登录回调与身份不一致")
        key = self._key(app)
        profile = self.home / f".gemini-{index - 1}"
        window = self.home / "Library/Application Support" / name
        logs = self.home / "Library/Logs" / name
        credential = self.home / ".gemini" / key
        manifest = self.support / f"instance-{index}.json"
        for path in (profile, window, logs):
            self._ordinary(path, True)
        for path in (credential, manifest):
            self._ordinary(path, False)
        require(profile.is_dir(), "独立账号数据目录缺失，请先手动检查")
        if manifest.exists():
            record = json.loads(manifest.read_text())
            require(record.get("index") == index and record.get("name") == name and
                    record.get("app") == str(app) and record.get("profile") == str(profile),
                    "实例清单与磁盘路径不一致")
        else:
            require(index in LEGACY, "新实例缺少管理清单，停止销毁")
        for root in self.roots:
            if not root.is_dir():
                continue
            for other in root.glob("Antigravity*.app"):
                if other == app or not other.is_dir() or other.is_symlink():
                    continue
                server = other / "Contents/Resources/bin/language_server"
                if server.is_file() and not server.is_symlink():
                    require(key.encode() not in server.read_bytes(), "登录文件仍被其他实例引用，停止销毁")
        paths = [app, profile, window, logs, credential, manifest]
        require(not any(line.strip().startswith(str(app) + "/Contents/") for line in self.process_list()),
                "实例仍在运行；请先保存工作并退出该实例")
        return name, [path for path in paths if path.exists()]

    def destroy(self, index, app):
        app = pathlib.Path(app)
        with operation_lock(self.support):
            name, paths = self._inspect(index, app)
            stage = pathlib.Path(tempfile.mkdtemp(prefix=f"destroy-instance-{index}-", dir=self.support))
            moved = []
            try:
                require(all(path.stat().st_dev == stage.stat().st_dev for path in paths),
                        "实例文件与暂存目录不在同一磁盘，停止销毁")
                for position, path in enumerate(paths):
                    target = stage / str(position)
                    os.replace(path, target)
                    moved.append((path, target))
            except Exception as error:
                try:
                    for original, target in reversed(moved):
                        os.replace(target, original)
                    stage.rmdir()
                except Exception as rollback_error:
                    raise RuntimeError(f"销毁中断且回滚失败；数据暂存于 {stage}：{rollback_error}") from error
                raise
            try:
                shutil.rmtree(stage)
            except Exception as error:
                raise RuntimeError(f"删除未完成；请检查暂存目录 {stage}：{error}") from error
            return name, len(paths)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--index", type=int, required=True)
    parser.add_argument("--app", type=pathlib.Path, required=True)
    args = parser.parse_args()
    try:
        name, count = InstanceDestroyer().destroy(args.index, args.app)
        print(f"已永久销毁 {name}（{count} 个独立项目）。已有升级备份保留。")
    except Exception as error:
        print(f"销毁失败：{error}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
