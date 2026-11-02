---
name: workbuddy-signin
description: WorkBuddy 自动签到体系维护。当用户提到「签到状态」「签到失败」「签到 doctor」「重装签到」「改签到班次」「凭据续期」「签到日志」或询问本机/GitHub 双端签到体系时使用。
---

# WorkBuddy 自动签到维护

本机已部署 WorkBuddy 自动签到体系（由 setup-windows.ps1 一键安装）。
所有可变项集中在 `{{CONFIG}}`，改配置后重跑 setup-windows.ps1 即可生效，不要改代码。

## 体系结构

- 本机主签：计划任务 `WorkBuddyAutoSignin`，每天按 config.json 的 `signin_time` 运行 `signin.py silent`
- 轮询补签：`WorkBuddyGrowthPoll`，按 `poll_times` 各班运行 `signin.py silent-poll`（先查状态、未签才签）
- 凭据续期：`WorkBuddyRefreshSecret`，每天 `refresh_time` 运行 `refresh-secret.py`，解密本机凭据 → 更新仓库 Secret
- 云端兜底：GitHub Actions 按仓库 workflow 的 cron 跑签到，凭据来自 Secret `WORKBUDDY_AUTH_INFO`
- 飞书播报：GitHub Actions 内置，卡片推每班结果（成功/失败都推）
- 关键环境变量：`WORKBUDDY_EXE` 指向 WorkBuddy.exe（解密依赖 Electron 原生绑定，不能命中旧版运行时）

## 仓库目录

脚本目录（即本 Skill 所属仓库克隆位置）下有：
- `signin.py` — 主脚本（status / auto / doctor / export 子命令）
- `refresh-secret.py` — 凭据续期（读 config.json）
- `setup-windows.ps1` — 一键安装/重装（参数化：-Repo -SigninTime -PollTimes -RefreshTime 等）
- `config.json` — 所有配置的唯一来源

## 常用操作

查状态（先说结论再贴细节）：
```
python "{{DIR}}\signin.py" status
```

体检（凭据/网络/接口全链路）：
```
python "{{DIR}}\signin.py" doctor
```

手动补签一次：
```
python "{{DIR}}\signin.py" auto
```

手动同步凭据到 Secret：
```
python "{{DIR}}\refresh-secret.py"
```

改班次 / 换仓库 / 换 Secret 名：编辑 `{{CONFIG}}` 后重跑
```
powershell -ExecutionPolicy Bypass -File "{{DIR}}\setup-windows.ps1"
```
（重跑会按 config.json 覆盖重建计划任务，幂等安全）

看日志：
```
Get-Content "{{DIR}}\signin.log" -Tail 20 -Encoding UTF8
Get-Content "{{DIR}}\refresh-secret.log" -Tail 10 -Encoding UTF8
```
（PowerShell 5.1 读 UTF-8 必须带 -Encoding UTF8，否则中文乱码）

查计划任务下次运行时间：
```
Get-ScheduledTask -TaskName "WorkBuddy*" | Get-ScheduledTaskInfo
```

## 故障排查要点

1. 签到失败先跑 `doctor`，再看 `signin.log` 末尾；401 = 凭据失效 → 立即手动跑 refresh-secret.py
2. `silent` / `silent-poll` 用 pythonw 启动时 stdout 为 None，脚本内部已兜底，报错时改用 `python` 手动跑复现
3. gh 推 Secret 走 api.github.com（稳定）；git push 走 github.com（可能超时）——同步配置优先用 API
4. 多台电脑共用一个仓库 Secret：最后续期的机器生效，属正常现象
5. 状态码含义：SUCCESS=签到成功；CLAIMED=实际签上（补跑场景）；ALREADY=已签过幂等跳过；GROWTH=成长中心完成；ERROR=失败
