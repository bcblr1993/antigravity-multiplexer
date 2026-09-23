#!/usr/bin/env python3
"""Create one local, version-pinned Antigravity instance from the installed original."""
import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
import pathlib
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
import uuid

KNOWN = {
    "2.16.0": {
        "asar": "053e8dce84698f8dc295ba7caa9d1e3879e49da3f63a9b54159eef43d607e24e",
        "language_server": "43e9b0842df235fb269c85e7e31ad768dd44a3885f30630d9d9f208a1776a273",
        "keyring_bypass_offset": 0x1c40960,
    },
    "2.15.1": {
        "asar": "0f81685e9836ddf5a382869bea348385650cfe1bfeecbd2e2d902a571ce57261",
        "language_server": "46a296d040163fd311948fbcb3ff0c9fb4ebf153083b4c17a89039e64fe85354",
        "keyring_bypass_offset": 0x1c014e0,
    }
}
APP_SUPPORT = pathlib.Path.home() / "Library/Application Support/Antigravity Multiplexer"


@contextmanager
def operation_lock(support=APP_SUPPORT):
    """Serialize clone creation and upgrades across manager windows/processes."""
    support.mkdir(parents=True, mode=0o700, exist_ok=True)
    with open(support / "operation.lock", "a+") as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise RuntimeError("已有实例创建或升级正在执行，请等待完成后重试") from error
        try:
            yield
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


def digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as stream:
        for block in iter(lambda: stream.read(4 * 1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True)


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def replace_once(data, old, new, label):
    require(data.count(old) == 1, f"源版本结构不匹配：{label}")
    return data.replace(old, new)


def patch_asar(source, target, name, data_dir, scheme):
    original = source.read_bytes()
    lengths = struct.unpack_from("<4I", original, 0)
    header = json.loads(original[16:16 + lengths[3]])
    base = 8 + lengths[1]
    changed = []
    parts = []
    offset = 0

    def patch(path, content):
        if path == "dist/paths.js":
            require(content.count("'.gemini'") == 5, "源版本路径结构不匹配")
            content = content.replace("'.gemini'", repr(data_dir))
        elif path == "dist/main.js":
            anchor = "const gotTheLock = electron_1.app.requestSingleInstanceLock();"
            setup = (
                f"electron_1.app.setName({json.dumps(name)});\n"
                f"electron_1.app.setPath('userData', require('path').join(electron_1.app.getPath('appData'), {json.dumps(name)}));\n"
                f"electron_1.app.setAppLogsPath(require('path').join(require('os').homedir(), 'Library', 'Logs', {json.dumps(name)}));\n"
            )
            content = replace_once(content, anchor, setup + anchor, "single-instance setup")
            content = replace_once(content, "await (0, ideInstall_1.maybeShowIdeInstallWizard)(storageManager);",
                                   "// Skip migration into this fresh profile.", "migration")
        elif path == "dist/languageServer.js":
            content = replace_once(content, "'--standalone',",
                                   f"'--standalone',\n            '--gemini_dir',\n            path_1.default.join(require('os').homedir(), {json.dumps(data_dir)}),",
                                   "gemini argument")
            anchor = "const env = { ...process.env, ...(0, shell_env_1.shellEnvSync)() };"
            content = replace_once(content, anchor,
                                   anchor + f"\n        env['ANTIGRAVITY_AUTH_SUCCESS_APP'] = {json.dumps(scheme)};",
                                   "OAuth callback setting")
        elif path == "dist/updater.js":
            content = replace_once(content, "function initAutoUpdater(isHeadless, settingsService) {",
                                   "function initAutoUpdater(isHeadless, settingsService) {\n    return; // Update through the manager after compatibility checks.",
                                   "updater")
        return content

    def walk(node, prefix=""):
        nonlocal offset
        for filename, entry in node.get("files", {}).items():
            path = f"{prefix}/{filename}".lstrip("/")
            if "files" in entry:
                walk(entry, path)
            elif "offset" in entry and not entry.get("unpacked"):
                content = original[base + int(entry["offset"]):base + int(entry["offset"]) + entry["size"]]
                require(len(content) == entry["size"], f"ASAR 文件损坏：{path}")
                if path in {"dist/paths.js", "dist/main.js", "dist/languageServer.js", "dist/updater.js"}:
                    modified = patch(path, content.decode("utf-8")).encode("utf-8")
                    require(modified != content, f"未适配：{path}")
                    content = modified
                    changed.append(path)
                    block_size = entry.get("integrity", {}).get("blockSize", 4194304)
                    entry["integrity"] = {
                        "algorithm": "SHA256", "hash": hashlib.sha256(content).hexdigest(),
                        "blockSize": block_size,
                        "blocks": [hashlib.sha256(content[i:i + block_size]).hexdigest()
                                   for i in range(0, len(content), block_size)],
                    }
                entry["offset"] = str(offset)
                entry["size"] = len(content)
                parts.append(content)
                offset += len(content)
    walk(header)
    require(set(changed) == {"dist/paths.js", "dist/main.js", "dist/languageServer.js", "dist/updater.js"},
            "应用结构与适配器不一致")
    header_json = json.dumps(header, separators=(",", ":"), ensure_ascii=False).encode()
    payload = struct.pack("<I", len(header_json)) + header_json
    payload += b"\0" * (-len(payload) % 4)
    packed = struct.pack("<I", len(payload)) + payload
    target.write_bytes(struct.pack("<II", 4, len(packed)) + packed + b"".join(parts))
    return hashlib.sha256(header_json).hexdigest()


def sign_bundle(app, name, bundle_id, work):
    framework = app / "Contents/Frameworks"
    for helper in framework.glob("*.app"):
        plist_path = helper / "Contents/Info.plist"
        info = plistlib.loads(plist_path.read_bytes())
        require(info["CFBundleIdentifier"].startswith("com.google.antigravity"), "Helper 身份不符合预期")
        info["CFBundleIdentifier"] = info["CFBundleIdentifier"].replace("com.google.antigravity", bundle_id)
        info["CFBundleDisplayName"] = helper.stem.replace("Antigravity", name)
        plist_path.write_bytes(plistlib.dumps(info))
        entitlements = {"com.apple.security.cs.allow-jit": True}
        if "(Plugin)" in helper.name:
            entitlements.update({"com.apple.security.cs.allow-unsigned-executable-memory": True,
                                 "com.apple.security.cs.disable-library-validation": True})
        ent_path = work / f"{helper.stem}.plist"
        ent_path.write_bytes(plistlib.dumps(entitlements))
        run("codesign", "--force", "--sign", "-", "--entitlements", str(ent_path), str(helper))
    main_ent = {"com.apple.security.automation.apple-events": True,
                "com.apple.security.cs.allow-jit": True,
                "com.apple.security.device.audio-input": True,
                "com.apple.security.device.camera": True}
    ent_path = work / "main-entitlements.plist"
    ent_path.write_bytes(plistlib.dumps(main_ent))
    run("codesign", "--force", "--sign", "-", str(app / "Contents/Resources/bin/language_server"))
    run("codesign", "--force", "--sign", "-", "--entitlements", str(ent_path), str(app))
    run("codesign", "--verify", "--deep", "--strict", str(app))


def ordinal_name(number):
    units = {1: "First", 2: "Second", 3: "Third", 4: "Fourth", 5: "Fifth", 6: "Sixth",
             7: "Seventh", 8: "Eighth", 9: "Ninth", 10: "Tenth", 11: "Eleventh",
             12: "Twelfth", 13: "Thirteenth", 14: "Fourteenth", 15: "Fifteenth",
             16: "Sixteenth", 17: "Seventeenth", 18: "Eighteenth", 19: "Nineteenth"}
    tens = {20: "Twenty", 30: "Thirty", 40: "Forty", 50: "Fifty", 60: "Sixty",
            70: "Seventy", 80: "Eighty", 90: "Ninety"}
    if number in units:
        return units[number]
    if number < 100:
        decade, remainder = divmod(number, 10)
        return (tens[decade * 10] + " " + units[remainder]) if remainder else {20: "Twentieth", 30: "Thirtieth", 40: "Fortieth", 50: "Fiftieth", 60: "Sixtieth", 70: "Seventieth", 80: "Eightieth", 90: "Ninetieth"}[number]
    if number < 1000:
        hundreds, remainder = divmod(number, 100)
        cardinal = ["", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine"][hundreds]
        return cardinal + " Hundred" + (" " + ordinal_name(remainder) if remainder else "th")
    thousands, remainder = divmod(number, 1000)
    cardinal = ["", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine"][thousands]
    return cardinal + " Thousand" + (" " + ordinal_name(remainder) if remainder else "th")


def create(index, source, destination):
    require(sys.platform == "darwin" and os.uname().machine == "arm64", "仅支持 Apple Silicon Mac")
    require(8 <= index <= 9999, "目前支持第 8 至 9999 个实例")
    name = f"Antigravity {ordinal_name(index)}"
    scheme = f"antigravity-{index}"
    data_dir = f".gemini-{index - 1}"
    bundle_id = f"local.antigravity.instance{index}"
    key_name = f"ag{index:04d}-standalone-oauth-token".encode()
    require(len(key_name) == len(b"jetski-standalone-oauth-token"), "凭据标识长度不匹配")
    app = destination / f"{name}.app"
    profile = pathlib.Path.home() / data_dir
    require(source.is_dir() and destination.is_dir(), "来源应用或目标目录不存在")
    require(not app.exists() and not profile.exists(), "目标应用或数据目录已经存在")
    info = plistlib.loads((source / "Contents/Info.plist").read_bytes())
    version = info.get("CFBundleShortVersionString")
    require(info.get("CFBundleIdentifier") == "com.google.antigravity", "请选择未修改的官方 Antigravity.app")
    require(version in KNOWN, f"Antigravity {version} 尚未适配；请先验证新版本")
    signature = run("codesign", "-dv", "--verbose=4", str(source)).stderr
    require("TeamIdentifier=EQHXZ8M8AV" in signature and "Format=app bundle with Mach-O thin (arm64)" in signature,
            "来源应用不是已知的 Google Apple Silicon 签名")
    run("codesign", "--verify", "--deep", "--strict", str(source))
    source_asar = source / "Contents/Resources/app.asar"
    source_server = source / "Contents/Resources/bin/language_server"
    expected = KNOWN[version]
    require(digest(source_asar) == expected["asar"] and digest(source_server) == expected["language_server"],
            "官方程序文件哈希变化，停止适配以保护现有实例")
    old_url = b"https://antigravity.google/auth-success?app=%s"
    new_url = f"{scheme}://oauth-success?app=%s".encode()
    require(len(new_url) <= len(old_url), "实例编号过长，回调地址无法适配")
    new_url += b"&" + b"x" * (len(old_url) - len(new_url) - 1)
    print(f"正在创建 {name} · {version}", flush=True)
    with tempfile.TemporaryDirectory(prefix="antigravity-build-", dir=destination) as temp_dir:
        stage = pathlib.Path(temp_dir) / f"{name}.app"
        work = pathlib.Path(temp_dir) / "signing"
        work.mkdir()
        run("ditto", str(source), str(stage))
        print("已复制官方应用；正在隔离配置", flush=True)
        asar_hash = patch_asar(source_asar, stage / "Contents/Resources/app.asar", name, data_dir, scheme)
        plist_path = stage / "Contents/Info.plist"
        app_info = plistlib.loads(plist_path.read_bytes())
        app_info["CFBundleIdentifier"] = bundle_id
        app_info["CFBundleName"] = "Antigravity"
        app_info["CFBundleDisplayName"] = name
        for item in app_info.get("CFBundleURLTypes", []):
            item["CFBundleURLSchemes"] = [scheme]
        app_info["ElectronAsarIntegrity"]["Resources/app.asar"]["hash"] = asar_hash
        app_info["NSAppleEventsUsageDescription"] = f"{name} 需要控制其他应用来执行你发起的自动化任务。"
        plist_path.write_bytes(plistlib.dumps(app_info))
        server_path = stage / "Contents/Resources/bin/language_server"
        server = bytearray(server_path.read_bytes())
        position = expected["keyring_bypass_offset"]
        require(server[position:position + 12] == bytes.fromhex("900b40f9f1c301d13f0210eb"),
                "此版本凭据存储位置与已验证适配器不符")
        server[position:position + 16] = struct.pack("<4I", 0xd2800020, 0xaa1f03e1, 0xaa1f03e2, 0xd65f03c0)
        server = replace_once(server, b"jetski-standalone-oauth-token", key_name, "credential namespace")
        server = replace_once(server, old_url, new_url, "OAuth callback URL")
        server_path.write_bytes(server)
        print("隔离完成；正在签名并验证", flush=True)
        sign_bundle(stage, name, bundle_id, work)
        require(digest(source_asar) == expected["asar"] and digest(source_server) == expected["language_server"],
                "创建期间官方应用发生变化")
        profile.mkdir(mode=0o700)
        stage.rename(app)
    run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
        "-f", str(app))
    APP_SUPPORT.mkdir(parents=True, exist_ok=True)
    manifest = APP_SUPPORT / f"instance-{index}.json"
    manifest.write_text(json.dumps({"index": index, "name": name, "app": str(app), "profile": str(profile),
                                    "version": version, "scheme": scheme, "source_asar_sha256": expected["asar"],
                                    "login_verified": False}, ensure_ascii=False, indent=2))
    run("open", str(app))
    print(f"创建并启动成功：{app}", flush=True)
    print("请在新窗口完成 Google 登录；成功后用管理器标记已验证。", flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--index", type=int, required=True)
    parser.add_argument("--source", type=pathlib.Path, required=True)
    parser.add_argument("--destination", type=pathlib.Path, required=True)
    args = parser.parse_args()
    try:
        with operation_lock():
            create(args.index, args.source.resolve(), args.destination.resolve())
    except Exception as error:
        print(f"创建失败：{error}", file=sys.stderr, flush=True)
        sys.exit(1)

if __name__ == "__main__":
    main()
