# WorkBuddy 自动签到 · 新电脑部署指南

> 把这份文件发给任何一台装了 WorkBuddy 的新电脑，配合下面「一条命令」，10 分钟内完成整套自动签到部署。

## 这是什么

部署完成后，这台电脑会拥有：

- **本机自动签到**：每天定时签到 + 成长中心领能量，另有 6 个班次轮询补签（漏了哪班补哪班，关机错过开机自动补跑）
- **云端兜底**：电脑不开机也没关系，GitHub Actions 每天北京时间 05:43 / 12:43 两次云签到
- **凭据自动续期**：每天 14:30 自动把最新登录态同步到 GitHub，云端永远用新凭据，免维护
- **飞书播报**（可选）：每一班签到结果都推一张卡片到飞书群，成功失败都能看见

隐私说明：你的登录凭据只存在**你自己的 GitHub 私有仓库** Secret 里，脚本代码全部可审计，明文凭据只在内存和临时文件中存在几秒。

## 准备清单（3 样，缺 1 不可的只有前两样）

| # | 需要什么 | 说明 |
|---|---------|------|
| 1 | WorkBuddy 桌面端已登录 | 用你自己的账号登录即可，**必须先登录** |
| 2 | GitHub 账号（免费） | 用于建你的私有仓库和跑云端兜底 |
| 3 | 飞书群机器人 webhook（可选） | 想收签到卡片就配；不配也能正常签到 |

> 飞书机器人怎么建：飞书群 → 设置 → 群机器人 → 添加「自定义机器人」→ 复制 Webhook 地址（安全设置选「自定义关键词」，填 `签到`）。

## 一条命令

把下面这段**原样复制**给这台电脑上的 WorkBuddy（对话输入框直接粘贴发送）：

```text
帮我部署 WorkBuddy 自动签到，严格按以下步骤执行：
1. 检查 gh CLI：没装就 winget install GitHub.cli；然后运行 gh auth login，带我完成浏览器授权（用我自己的 GitHub 账号，登录需要我本人操作，提醒我）
2. gh repo clone yang-212/workbuddy-signin-kit 到我的用户目录
3. 打开 Kit 目录里的 README.md，找到「Agent 执行清单」，从第 3 步开始严格照做；每一步做完向我确认再进行下一步
4. 全部完成后汇报：3 个计划任务、仓库 Secret 状态、一次真实签到（python signin.py auto）的结果
```

> 授权那一步需要本人在浏览器输入配对码，AI 替不了，其余全自动。

---

## Agent 执行清单（给 AI 助手照着做，普通用户不用看）

前置：已在 `gh auth login` 完成授权、Kit 仓库已克隆到 `$KIT`（下同）。逐步执行，**每步向用户确认**。

### 第 1 步 · 环境自检

```powershell
# WorkBuddy 是否在运行/安装（没登录先让用户登录 WorkBuddy）
Get-Process WorkBuddy -ErrorAction SilentlyContinue | Select-Object -First 1 Path
# Python（没有 python 就 winget install Python.Python.3.12）
python --version
# gh 授权状态
gh auth status
```

任一失败：先修复再继续，不要跳步。

### 第 2 步 · 收集用户参数（问用户，给默认值）

| 参数 | 问法 | 默认 |
|------|------|------|
| 飞书 webhook | 「有飞书机器人 webhook 吗？没有就跳过」 | 无 |
| 签到时间 | 「每天几点主签？」 | 09:30 |
| 补签班次 | 「补签班次默认 01/05/09/13/17/21 点，要改吗？」 | 默认六班 |

记下 `$feishu`（可为空）、`$signinTime`、`$pollTimes`。

### 第 3 步 · 创建用户自己的私有仓库

```powershell
$ghUser = gh api user --jq ".login"
$repo   = "$ghUser/workbuddy-auto-signin"
gh repo create $repo --private
# 已存在同名仓库会报错，确认是用户自己的仓库后可继续
```

### 第 4 步 · 推送代码到用户仓库

```powershell
cd $KIT
git remote set-url origin "https://github.com/$repo.git"
git add -A
git commit -m "init: workbuddy auto signin"
git push -u origin main
```

**若 push 报 404 / 权限错误**（token 缺 workflow scope，工作流文件推送被 GitHub 拒绝）：

```powershell
gh auth refresh -s workflow    # 带用户再授权一次，补上 workflow scope
git push -u origin main
```

然后（如用户提供了 webhook）：

```powershell
$feishu | gh secret set FEISHU_WEBHOOK --repo $repo
```

### 第 5 步 · 运行一键安装

```powershell
cd $KIT
powershell -ExecutionPolicy Bypass -File .\setup-windows.ps1 `
    -Repo $repo `
    -SigninTime $signinTime
# 若补签班次改过，追加：-PollTimes @("HH:00",...)
# 若第 4 步已推送成功，不要再传 -InitGithub；只有跳过了第 3/4 步时才加 -InitGithub（可配 -FeishuWebhook）
```

安装器会自动完成：探测 WorkBuddy.exe → 写 `WORKBUDDY_EXE` 环境变量 → 注册 3 个计划任务 → 首次同步凭据到 Secret `WORKBUDDY_AUTH_INFO` → 安装维护 Skill（之后用户说「签到状态」即可自助查询）。

### 第 6 步 · 验证并汇报

```powershell
python signin.py status      # 看当前签到状态
python signin.py auto        # 真实签一次（当天已签会显示 ALREADY，属正常）
Get-ScheduledTask -TaskName "WorkBuddy*" | Get-ScheduledTaskInfo
gh secret list --repo $repo  # 应能看到 WORKBUDDY_AUTH_INFO（配了飞书还有 FEISHU_WEBHOOK）
```

向用户汇报：3 个计划任务及下次运行时间、Secret 列表、签到结果（状态码含义：SUCCESS=成功 / CLAIMED=补签成功 / ALREADY=今天已签 / ERROR=失败）。

### 故障排查速查

| 现象 | 处理 |
|------|------|
| 签到 401 / 凭据失效 | `python refresh-secret.py`（手动续期一次） |
| git push 404 | `gh auth refresh -s workflow` 后重推 |
| WorkBuddy.exe 没找到 | 重跑 setup 加 `-WorkBuddyExe "完整路径"` |
| 看日志 | `Get-Content .\signin.log -Tail 20 -Encoding UTF8` |
| 深度体检 | `python signin.py doctor` |

### 改配置（装完之后）

所有可变项都在 `$KIT\config.json`（repo / Secret 名 / 签到时间 / 班次 / 续期时间）。
改完重跑一次 `setup-windows.ps1` 即生效（幂等，会覆盖重建计划任务）。

### 卸载

```powershell
Unregister-ScheduledTask -TaskName WorkBuddyAutoSignin -Confirm:$false
Unregister-ScheduledTask -TaskName WorkBuddyGrowthPoll -Confirm:$false
Unregister-ScheduledTask -TaskName WorkBuddyRefreshSecret -Confirm:$false
# 删除 $KIT 目录即可；GitHub 上的私有仓库可自行删除
```

---

## 致谢

签到接口逆向与核心脚本 [signin.py](signin.py) 来自开源项目 [88lin/workbuddy-auto-signin](https://github.com/88lin/workbuddy-auto-signin)（MIT License），本项目在其基础上增加了参数化安装、云端兜底工作流、凭据自动续期与飞书播报。
