#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""多通道签到结果推送（GitHub Actions 用）。

设计动机：workflow 文件更新需要 token 具备 workflow scope，很难自动化；
把推送逻辑放在普通脚本里，workflow 只留一行 `python notify.py`，
以后增删通道只改本文件，经 Contents API 即可更新，不再碰 workflow。

四通道自适应——配了哪个 Secret 就走哪个通道，可同时配多个：
  FEISHU_WEBHOOK      飞书群机器人（交互卡片）
  WECOM_WEBHOOK       企业微信群机器人（markdown 消息）
  SERVERCHAN_SENDKEY  Server酱（推到个人微信，免费版 5 条/天，本任务一天 2 条够用）
  WXTEST_APPID + WXTEST_SECRET + WXTEST_OPENID + WXTEST_TEMPLATE_ID
                      微信公众平台测试号（推到个人微信，免费无限制）

输入：汇总步骤写入 GITHUB_ENV 的 SIGNIN_OK / SIGNIN_RESULT / REPORT /
      TOTAL_CREDITS / STREAK_DAYS / CREDIT，以及 RUN_* 事件上下文。
输出：永远 exit 0（推送失败只发 ::warning::，不把成功的签到染红）。
"""

import json
import os
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone


def warn(message):
    print("::warning::%s" % message)


def main():
    ok = os.environ.get("SIGNIN_OK") == "true"
    result = os.environ.get("SIGNIN_RESULT", "UNKNOWN")
    report = os.environ.get("REPORT", "")
    credit = os.environ.get("CREDIT", "").strip()
    total = os.environ.get("TOTAL_CREDITS", "").strip()
    streak = os.environ.get("STREAK_DAYS", "").strip()
    event = os.environ.get("EVENT_NAME", "")
    cron = os.environ.get("SCHEDULE_CRON", "").strip()
    run_id = os.environ.get("RUN_ID", "")

    # ---------- 心跳行：计划班次 vs 实际执行，GitHub 排队延迟一目了然 ----------
    CRON_BJ = {"43 21 * * *": "05:43", "43 4 * * *": "12:43"}
    beat = "手动触发" if event != "schedule" else "计划班次 %s" % (CRON_BJ.get(cron, cron or "?"))
    if event == "schedule" and cron in CRON_BJ and os.environ.get("RUN_STARTED"):
        try:
            start = datetime.fromisoformat(os.environ["RUN_STARTED"].replace("Z", "+00:00"))
            bj = start.astimezone(timezone(timedelta(hours=8)))
            hh, mm = map(int, CRON_BJ[cron].split(":"))
            cand = [(bj - timedelta(days=d)).replace(hour=hh, minute=mm, second=0, microsecond=0)
                    for d in (0, 1)]
            planned = max(c for c in cand if c <= bj)
            mins = int((bj - planned).total_seconds() // 60)
            beat = "计划 %s → 实际 %s（排队延迟 %d 小时 %d 分）" % (
                CRON_BJ[cron], bj.strftime("%H:%M"), mins // 60, mins % 60)
        except Exception:                                   # noqa: BLE001
            pass

    RESULT_SHORT = {
        "CLAIMED": "已领取", "ALREADY": "已签过·幂等跳过",
        "SUCCESS": "成功", "GROWTH": "成长完成",
    }
    title = "✅ WorkBuddy 签到正常" if ok else "❌ WorkBuddy 签到异常"
    if ok:
        sign = ("领取 + %s 积分" % credit) if (result == "CLAIMED" and credit) else "已签过 ✓"
    else:
        sign = result
    note = "🕐 %s ｜ 云端兜底 ｜ 状态 %s · %s ｜ run %s" % (
        beat, result, RESULT_SHORT.get(result, "未知"), run_id)

    # ---------- 统计三行（markdown 通道共用） ----------
    def stat_lines(color=True):
        def paint(txt, c):
            return '<font color="%s">%s</font>' % (c, txt) if color else txt
        return "\n".join([
            "今日签到：**%s**" % paint(sign, "info" if ok else "warning"),
            "累积获得：**%s**" % (total or "—"),
            "连续签到：**%s 天**" % (streak or "—"),
        ])

    sent = 0

    # ================= 通道 1：飞书（交互卡片） =================
    feishu_hook = os.environ.get("FEISHU_WEBHOOK", "").strip()
    if feishu_hook:
        try:
            def col(text):
                return {"tag": "column", "width": "weighted", "weight": 1,
                        "elements": [{"tag": "div",
                                      "text": {"tag": "lark_md", "content": text}}]}
            stat = {
                "tag": "column_set", "flex_mode": "trisect",
                "background_style": "grey", "horizontal_spacing": "default",
                "columns": [
                    col("今日签到\n**%s**" % sign),
                    col("累积获得\n**%s**" % (total or "—")),
                    col(("连续签到\n**%s 天**" % streak) if (ok and streak) else "连续签到\n**—**"),
                ],
            }
            payload = {
                "msg_type": "interactive",
                "card": {
                    "config": {"wide_screen_mode": True},
                    "header": {
                        "template": "green" if ok else "red",
                        "title": {"tag": "plain_text", "content": title},
                    },
                    "elements": [
                        stat,
                        {"tag": "hr"},
                        {"tag": "div", "text": {"tag": "lark_md", "content": report}},
                        {"tag": "hr"},
                        {"tag": "note", "elements": [{"tag": "plain_text", "content": note}]},
                    ],
                },
            }
            req = urllib.request.Request(
                feishu_hook, data=json.dumps(payload).encode("utf-8"),
                headers={"Content-Type": "application/json"}, method="POST")
            with urllib.request.urlopen(req, timeout=20) as resp:
                print("feishu http", resp.status)
                sent += 1
        except Exception as exc:                            # noqa: BLE001
            warn("飞书推送失败：%s" % exc)

    # ================= 通道 2：企业微信群机器人（markdown） =================
    wecom_hook = os.environ.get("WECOM_WEBHOOK", "").strip()
    if wecom_hook:
        try:
            md = "%s\n%s\n> %s\n%s" % (title, stat_lines(), report.replace("\n", " "), note)
            payload = {"msgtype": "markdown", "markdown": {"content": md}}
            req = urllib.request.Request(
                wecom_hook, data=json.dumps(payload).encode("utf-8"),
                headers={"Content-Type": "application/json"}, method="POST")
            with urllib.request.urlopen(req, timeout=20) as resp:
                body = json.loads(resp.read().decode("utf-8", "replace"))
                print("wecom http", resp.status, body.get("errmsg", ""))
                sent += 1
        except Exception as exc:                            # noqa: BLE001
            warn("企业微信推送失败：%s" % exc)

    # ================= 通道 3：Server酱（个人微信） =================
    sendkey = os.environ.get("SERVERCHAN_SENDKEY", "").strip()
    if sendkey:
        try:
            desp = "%s\n\n%s\n\n> %s\n\n%s" % (stat_lines(color=False), report, report, note)
            data = urllib.parse.urlencode({"title": title, "desp": desp}).encode("utf-8")
            req = urllib.request.Request(
                "https://sctapi.ftqq.com/%s.send" % sendkey, data=data, method="POST")
            with urllib.request.urlopen(req, timeout=20) as resp:
                body = json.loads(resp.read().decode("utf-8", "replace"))
                print("serverchan http", resp.status, body.get("message", ""))
                sent += 1
        except Exception as exc:                            # noqa: BLE001
            warn("Server酱推送失败：%s" % exc)

    # ================= 通道 4：微信测试号（个人微信，免费无限制） =================
    # 准备：公众平台测试号（mp.weixin.qq.com）扫码开通 → 拿 appID/appSecret
    #       → 个人微信扫码关注测试号拿 openid → 新增测试模板拿 template_id
    # 模板内容示例（字段名可自定义，与下面的 data key 对应即可）：
    #   结果：{{result.DATA}}
    #   积分：{{credit.DATA}}
    #   累积：{{total.DATA}}　连签：{{streak.DATA}} 天
    #   {{report.DATA}}
    #   {{beat.DATA}}
    wx_appid = os.environ.get("WXTEST_APPID", "").strip()
    wx_secret = os.environ.get("WXTEST_SECRET", "").strip()
    wx_openid = os.environ.get("WXTEST_OPENID", "").strip()
    wx_tpl = os.environ.get("WXTEST_TEMPLATE_ID", "").strip()
    if wx_appid:
        if wx_secret and wx_openid and wx_tpl:
            try:
                tok_url = ("https://api.weixin.qq.com/cgi-bin/token?grant_type=client_credential"
                           "&appid=%s&secret=%s" % (wx_appid, wx_secret))
                with urllib.request.urlopen(tok_url, timeout=20) as resp:
                    tok = json.loads(resp.read().decode("utf-8", "replace"))
                if tok.get("access_token"):
                    payload = {
                        "touser": wx_openid,
                        "template_id": wx_tpl,
                        "data": {
                            "result": {"value": ("%s（%s）" % (sign, RESULT_SHORT.get(result, "")))[:40]},
                            "credit": {"value": (credit or "—")[:40]},
                            "total": {"value": ("%s　连签 %s 天" % (total or "—", streak or "—"))[:40]},
                            "report": {"value": report[:100]},
                            "beat": {"value": note[:60]},
                        },
                    }
                    req = urllib.request.Request(
                        "https://api.weixin.qq.com/cgi-bin/message/template/send?access_token=%s"
                        % tok["access_token"],
                        data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
                        headers={"Content-Type": "application/json"}, method="POST")
                    with urllib.request.urlopen(req, timeout=20) as resp:
                        body = json.loads(resp.read().decode("utf-8", "replace"))
                        print("wxtest http", resp.status,
                              "errcode", body.get("errcode"), body.get("errmsg", ""))
                        sent += 1
                else:
                    warn("微信测试号 access_token 获取失败：%s" % tok.get("errmsg", tok))
            except Exception as exc:                        # noqa: BLE001
                warn("微信测试号推送异常：%s" % exc)
        else:
            warn("WXTEST_APPID 已配置，但缺少 WXTEST_SECRET / WXTEST_OPENID / "
                 "WXTEST_TEMPLATE_ID 之一，跳过测试号推送")

    if sent == 0 and not any(os.environ.get(k, "").strip() for k in (
            "FEISHU_WEBHOOK", "WECOM_WEBHOOK", "SERVERCHAN_SENDKEY", "WXTEST_APPID")):
        print("未配置任何推送通道 Secret，跳过推送（可选：FEISHU_WEBHOOK / "
              "WECOM_WEBHOOK / SERVERCHAN_SENDKEY / WXTEST_*）")
    else:
        print("推送完成，成功通道数：%d" % sent)
    return 0


if __name__ == "__main__":
    sys_exit = main()
    raise SystemExit(sys_exit)
