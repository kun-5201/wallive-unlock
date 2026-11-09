#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""打包「免广告 + 会员解锁」版交互壁纸 IPA。

流程:
1. 从官方企业分发 CDN 下载原版未加密 IPA(企业签,无 FairPlay)
2. 移除全部代码签名(安装时用全能签/esign 重签即可)
3. 把编译好的 WalliveUnlock.dylib 放进 App 的 Frameworks/,
   并给主程序 Mach-O 加一条 LC_LOAD_DYLIB,iOS 启动时自动加载插件
4. 在 App 包内内置插件配置(Walllive.app/WalliveUnlock/):
   伪造永久 VIP 会员 + ios_ads_enabled=false + 关闭悬浮日志按钮
5. 重新打包成未签名 IPA

用法: build_ipa.py <WalliveUnlock.dylib> <out.ipa>
"""
import json
import os
import re
import time
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import zipfile

import lief

# 官方企业分发的直链(未加密)。若官方更新了版本,从
# 官方企业分发的下载页。构建时动态解析:下载页 → manifest → IPA 直链,
# 官方更新版本后无需改代码。CDN 会拒绝无浏览器 UA 的请求，必须带头。
DOWNLOAD_PAGE_URL = "https://walllive.18ir.cn/"
BROWSER_UA = ("Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) "
             "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1")


_COOKIE_JAR = os.path.join(tempfile.gettempdir(), "wallive_cookies.txt")


def _curl(url, dest=None, referer=None, extra_headers=None):
    """统一用 curl 拉取(服务器对 urllib 的请求特征有区别,且必须带浏览器 UA + 会话 Cookie)"""
    # --http1.1: 服务器对 HTTP/2 会报 stream error (curl exit 16)
    cmd = ["curl", "-sS", "--http1.1", "--fail", "-L", "-m", "600",
           "-A", BROWSER_UA, "-c", _COOKIE_JAR, "-b", _COOKIE_JAR]
    if referer:
        cmd += ["-e", referer]
    if extra_headers:
        for h in extra_headers:
            cmd += ["-H", h]
    if dest:
        cmd += ["-o", dest]
    cmd.append(url)
    # 服务器偶发 502/限流,重试几次
    last_err = None
    for attempt in range(4):
        try:
            r = subprocess.run(cmd, check=True, capture_output=not dest)
            if not dest:
                return r.stdout
            return
        except subprocess.CalledProcessError as e:
            last_err = e
            if dest and os.path.exists(dest) and os.path.getsize(dest) < 10_000_000:
                os.remove(dest)
            time.sleep(6 * (attempt + 1))
    raise last_err


def download_official_ipa(dest):
    """下载页 → manifest → IPA 直链,跟随官方最新版本。"""
    print("      fetching download page ...")
    page = _curl(DOWNLOAD_PAGE_URL)
    m = re.search(r'data-manifest="([^"]+)"', page.decode("utf-8"))
    assert m, "manifest ticket not found on download page"
    manifest_url = m.group(1)
    if manifest_url.startswith("/"):
        manifest_url = DOWNLOAD_PAGE_URL.rstrip("/") + manifest_url

    print("      fetching manifest ...")
    manifest = _curl(manifest_url, referer=DOWNLOAD_PAGE_URL)
    m2 = re.search(r"<string>(https?[^<]*\.ipa[^<]*)</string>", manifest.decode("utf-8"))
    assert m2, "ipa url not found in manifest"
    ipa_url = m2.group(1)

    print("      downloading IPA ...")
    _curl(ipa_url, dest=dest, referer=DOWNLOAD_PAGE_URL)
    assert os.path.getsize(dest) > 10_000_000, "downloaded IPA too small"


DYLIB_INSTALL_PATH = "@executable_path/Frameworks/WalliveUnlock.dylib"

# ---- 内置到 App 包里的插件配置 ----
CONFIG_JSON = {
    "forgeAccess": True,      # 接管 /api/ios_access.php,返回本地伪造 VIP
    "forgeDownload": False,
    "autoRepair": True,
    "downloadTemplate": "",
    "downloadMap": {},
    "localFirst": True,
    "showLogButton": False,   # 不显示悬浮日志按钮
}
ACCESS_JSON = {
    "_v": 6,
    "ok": True,
    "server_time": "{{NOW_ISO}}",
    "account": {"enabled": True, "bound": True, "online_allowed": True},
    "policy": {
        "daily_limit": 9999, "weekly_limit": 9999, "reward_ad_count": 5,
        "reset_timezone": "Asia/Shanghai", "reset_weekday": 3,
        "membership_enabled": True,
        "ios_ads_enabled": False,   # 服务端层面关广告
    },
    "plans": [
        {"id": "monthly", "name": "月卡", "price_cents": 888, "duration_unit": "month", "duration_count": 1, "enabled": True},
        {"id": "yearly", "name": "年卡", "price_cents": 1088, "duration_unit": "year", "duration_count": 1, "enabled": True},
        {"id": "lifetime", "name": "永久会员", "price_cents": 1288, "duration_unit": "permanent", "duration_count": 0, "enabled": True},
    ],
    "membership": {"status": "vip", "is_permanent": True, "vip_expires_at": "2099-12-31 23:59:59"},
    "quota": {
        "daily_used": 0, "daily_reserved": 0, "daily_remaining": 9999,
        "daily_next_reset": "2099-01-01T00:00:00+08:00",
        "used": 0, "reserved": 0, "remaining": 9999,
        "next_reset": "2099-01-01T00:00:00+08:00",
        "completed_ids": [], "pending_ids": [],
    },
    "checkout_available": True,
}
DOWNLOAD_JSON = {
    "ok": True, "token": "", "error": "", "down_url": "{{DOWN_URL}}",
    "quota": {
        "daily_remaining": 9999, "used": 0, "reserved": 0, "remaining": 9999,
        "next_reset": "", "daily_next_reset": "", "completed_ids": [], "pending_ids": [],
    },
}


def strip_signature(path):
    """移除单个 Mach-O 的代码签名(codesign 优先,lief 兜底)。"""
    try:
        subprocess.run(
            ["xcrun", "codesign", "--remove-signature", path],
            check=True, capture_output=True,
        )
        return
    except Exception:
        pass
    try:
        b = lief.parse(path)
        removed = False
        for lc in list(b.commands):
            if lc.command == lief.MachO.LoadCommand.TYPE.CODE_SIGNATURE:
                b.remove_command(lc)
                removed = True
        if removed:
            b.write(path)
    except Exception:
        pass


def is_macho(path):
    try:
        with open(path, "rb") as f:
            magic = f.read(16)
    except OSError:
        return False
    if len(magic) < 4:
        return False
    m = int.from_bytes(magic[:4], "big")
    fm = int.from_bytes(magic[:4], "little")
    return m in (0xfeedface, 0xfeedfacf) or fm in (0xfeedface, 0xfeedfacf)


def clean_dylib(dylib_path, out_path):
    """去掉 tweak 构建产物里对越狱库(CydiaSubstrate/ElleKit)的依赖。"""
    b = lief.parse(dylib_path)
    bad = []
    for lc in list(b.commands):
        if lc.command in (lief.MachO.LoadCommand.TYPE.LOAD_DYLIB,
                          lief.MachO.LoadCommand.TYPE.LOAD_WEAK_DYLIB,
                          lief.MachO.LoadCommand.TYPE.REEXPORT_DYLIB):
            name = str(lc.name) if hasattr(lc, "name") else ""
            low = name.lower()
            if "substrate" in low or "ellekit" in low or "cydia" in low:
                bad.append(lc)
    for lc in bad:
        b.remove_command(lc)
        print(f"  removed tweak dependency: {lc.name}")
    b.write(out_path)


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)
    dylib_path, out_ipa = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])

    work = tempfile.mkdtemp(prefix="wallive_")
    print("[1/6] downloading official IPA ...")
    official = os.path.join(work, "official.ipa")
    download_official_ipa(official)
    print(f"      {os.path.getsize(official) / 1e6:.1f} MB")

    print("[2/6] extracting ...")
    with zipfile.ZipFile(official) as z:
        z.extractall(work)
    payload = os.path.join(work, "Payload")
    apps = [d for d in os.listdir(payload) if d.endswith(".app")]
    assert len(apps) == 1, apps
    app_dir = os.path.join(payload, apps[0])
    print(f"      app: {apps[0]}")

    print("[3/6] stripping all code signatures ...")
    for root, dirs, files in os.walk(app_dir):
        if "_CodeSignature" in dirs:
            shutil.rmtree(os.path.join(root, "_CodeSignature"))
            dirs.remove("_CodeSignature")
        for f in files:
            p = os.path.join(root, f)
            if is_macho(p):
                strip_signature(p)

    print("[4/6] injecting WalliveUnlock.dylib ...")
    fw_dir = os.path.join(app_dir, "Frameworks")
    os.makedirs(fw_dir, exist_ok=True)
    dylib_out = os.path.join(fw_dir, "WalliveUnlock.dylib")
    clean_dylib(dylib_path, dylib_out)

    exe_name = None
    with open(os.path.join(app_dir, "Info.plist"), "rb") as f:
        exe_name = None
    # 直接从二进制找主程序:Info.plist 是二进制 plist,用 strings 兜底不可靠,
    # 这里按 Theos 惯例:主程序 = .app 里最大的 Mach-O
    candidates = []
    for f in os.listdir(app_dir):
        p = os.path.join(app_dir, f)
        if os.path.isfile(p) and is_macho(p):
            candidates.append((os.path.getsize(p), p, f))
    candidates.sort(reverse=True)
    assert candidates, "no main binary found"
    _, exe_path, exe_name = candidates[0]
    print(f"      main binary: {exe_name}")

    b = lief.parse(exe_path)
    b.add_library(DYLIB_INSTALL_PATH)
    b.write(exe_path)
    # 校验
    b2 = lief.parse(exe_path)
    names = [str(lc.name) for lc in b2.libraries]
    assert DYLIB_INSTALL_PATH in names, names
    print(f"      LC_LOAD_DYLIB added: {DYLIB_INSTALL_PATH}")

    print("[5/6] writing built-in config ...")
    cfg_dir = os.path.join(app_dir, "WalliveUnlock")
    os.makedirs(cfg_dir, exist_ok=True)
    for name, obj in (
        ("config.json", CONFIG_JSON),
        ("access.json", ACCESS_JSON),
        ("download.json", DOWNLOAD_JSON),
    ):
        with open(os.path.join(cfg_dir, name), "w", encoding="utf-8") as f:
            json.dump(obj, f, ensure_ascii=False, indent=2)

    print("[6/6] packaging IPA ...")
    if os.path.exists(out_ipa):
        os.remove(out_ipa)
    with zipfile.ZipFile(out_ipa, "w", zipfile.ZIP_DEFLATED) as z:
        for root, dirs, files in os.walk(payload):
            for f in files:
                p = os.path.join(root, f)
                z.write(p, os.path.relpath(p, work))
    print(f"      done: {out_ipa} ({os.path.getsize(out_ipa) / 1e6:.1f} MB)")


if __name__ == "__main__":
    main()
