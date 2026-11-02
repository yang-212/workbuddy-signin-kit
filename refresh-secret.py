#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""定期把本机 WorkBuddy 明文凭据同步到 GitHub 仓库 Secret。

为什么需要它：
  GitHub Actions 云端兜底靠的是仓库 Secret `WORKBUDDY_AUTH_INFO`，而里面的
  accessToken 只有约 28 天有效期（refreshToken 约 30 天）。本机的 WorkBuddy
  客户端会自动刷新凭据，所以只要定期把「最新解出的明文」重新推一次到 Secret，
  云端就能一直有效，不需要人工干预。

做什么：
  1. 读取本机凭据 → 用 signin.py 的解密链路解出明文（借 WorkBuddy 的 Electron
     运行时当 Node 用，走 electron_browser_workbuddy_storage 原生绑定）
  2. 写入临时文件（在 %TEMP%，不在 git 仓库内）
  3. 调 gh CLI 把内容塞进仓库 Secret（gh 走 api.github.com，不受 github.com 抖动影响）
  4. 无论成败都删掉临时文件

用法：
    pythonw refresh-secret.py        # 计划任务用（零窗口）
    python refresh-secret.py         # 手动跑，日志同时写文件
"""

import os
import sys

# 计划任务用 pythonw 启动时 sys.stdout / sys.stderr 是 None，
# 任何 print 都会炸。先兜住再导入 signin（它内部也会往 stdout 写）。
if sys.stdout is None:
    sys.stdout = open(os.devnull, "w", encoding="utf-8")
if sys.stderr is None:
    sys.stderr = open(os.devnull, "w", encoding="utf-8")

import json          # noqa: E402
import shutil        # noqa: E402
import subprocess    # noqa: E402
import tempfile      # noqa: E402
import time          # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import signin        # noqa: E402

# ====== 配置（优先读同目录 config.json，由 setup-windows.ps1 生成） ======
CONFIG_FILE = os.path.join(HERE, "config.json")


def _load_config():
    """config.json 缺失或字段缺失时，回退到环境变量 / 默认值。"""
    cfg = {}
    try:
        with open(CONFIG_FILE, "r", encoding="utf-8-sig") as fh:
            cfg = json.load(fh) or {}
    except (OSError, ValueError):
        pass
    return cfg


_CFG = _load_config()

REPO = os.environ.get("WB_SIGNIN_REPO") or _CFG.get("repo") or "yang-212/workbuddy-auto-signin"
SECRET_NAME = os.environ.get("WB_SIGNIN_SECRET") or _CFG.get("secret_name") or "WORKBUDDY_AUTH_INFO"
# 本机必须显式指定运行时：注册表里可能没有 WorkBuddy 卸载项，
# 默认探测会命中旧版运行时并解密失败。优先级：config.json > 环境变量 > 常见路径探测。
if _CFG.get("workbuddy_exe") and os.path.isfile(_CFG["workbuddy_exe"]):
    DEFAULT_WORKBUDDY_EXE = _CFG["workbuddy_exe"]
else:
    DEFAULT_WORKBUDDY_EXE = r"D:\App\Tencent\WorkBuddy\WorkBuddy.exe"
GH_CANDIDATES = [
    os.path.expanduser(r"~\.local\bin\gh.exe"),
    r"C:\Program Files\GitHub CLI\gh.exe",
]
LOG_FILE = os.path.join(HERE, "refresh-secret.log")
# ==================


def log(message):
    line = "[%s] %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), message)
    try:
        with open(LOG_FILE, "a", encoding="utf-8") as fh:
            fh.write(line)
    except OSError:
        pass
    try:
        sys.stdout.write(line)
        sys.stdout.flush()
    except Exception:                                   # noqa: BLE001
        pass


def find_gh():
    for path in GH_CANDIDATES:
        if os.path.isfile(path):
            return path
    found = shutil.which("gh")
    if found:
        return found
    return None


def main():
    os.environ.setdefault("WORKBUDDY_EXE", DEFAULT_WORKBUDDY_EXE)

    gh = find_gh()
    if not gh:
        log("FAIL 找不到 gh.exe（已找过 %s 与 PATH）" % ", ".join(GH_CANDIDATES))
        return 2

    # --- 1. 定位并解密本机凭据 ---
    try:
        auth_file, _looked_in = signin.find_auth_file()
    except Exception as exc:                            # noqa: BLE001
        log("FAIL 探测凭据文件异常（%s: %s）" % (type(exc).__name__, exc))
        return 2

    if not auth_file or not os.path.exists(auth_file):
        log("FAIL 未找到 WorkBuddy 登录凭据，请先打开并登录 WorkBuddy 桌面端")
        return 2

    try:
        session = signin.load_session_retry(auth_file)
        kind = signin._token_format((session.get("auth") or {}).get("accessToken"))
        resolved = signin.resolve_session(session)
    except signin.AuthError as exc:
        # 凭据过期/需要重新登录，属于要人工介入的情况
        log("FAIL 凭据解析失败（AuthError）：%s" % (exc.output().get("report") if hasattr(exc, "output") else exc))
        return 1
    except Exception as exc:                            # noqa: BLE001
        log("FAIL 凭据解密失败（%s: %s）" % (type(exc).__name__, exc))
        return 2

    token = (resolved.get("auth") or {}).get("accessToken")
    if not isinstance(token, str) or not token or token.startswith("$wbEncrypted"):
        log("FAIL 解出的 accessToken 不是明文（kind=%s），中止以免把加密态写进 Secret" % kind)
        return 2

    expires_ms = (resolved.get("auth") or {}).get("expiresAt") or 0
    try:
        expires_txt = time.strftime("%Y-%m-%d %H:%M", time.localtime(int(expires_ms) / 1000))
    except (TypeError, ValueError, OSError):
        expires_txt = "未知"

    # --- 2. 写临时文件（%TEMP%，不在 git 仓库内）---
    tmp_path = None
    try:
        fd, tmp_path = tempfile.mkstemp(prefix="wb_cred_", suffix=".json")
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(resolved, fh, ensure_ascii=False, indent=2)

        # --- 3. 推送到仓库 Secret ---
        with open(tmp_path, "rb") as fh:
            proc = subprocess.run(
                [gh, "secret", "set", SECRET_NAME, "--repo", REPO],
                stdin=fh, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                timeout=120,
            )
        out = (proc.stdout or b"").decode("utf-8", "replace").strip()
        if proc.returncode != 0:
            log("FAIL gh secret set 失败（exit=%d）：%s" % (proc.returncode, out or "(无输出)"))
            return 1

        log("OK 已更新 Secret %s（repo=%s，token 有效期至 %s，明文长度 %d）"
            % (SECRET_NAME, REPO, expires_txt, len(token)))
        return 0
    except subprocess.TimeoutExpired:
        log("FAIL gh secret set 超时（120s），可能是网络问题")
        return 1
    except Exception as exc:                            # noqa: BLE001
        log("FAIL 同步过程异常（%s: %s）" % (type(exc).__name__, exc))
        return 2
    finally:
        # 明文只在临时文件里存在几秒，必须无条件删除
        if tmp_path and os.path.exists(tmp_path):
            try:
                os.remove(tmp_path)
            except OSError as exc:
                log("WARN 临时凭据文件删除失败：%s（请手动删除 %s）" % (exc, tmp_path))


if __name__ == "__main__":
    sys.exit(main())
