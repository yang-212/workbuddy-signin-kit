# setup-windows.ps1 — WorkBuddy 自动签到 · 一键部署（参数化，支持新用户自建仓库）
#
# 两种用法：
#   A. 新用户全新部署（推荐配合公共 Kit 仓库 yang-212/workbuddy-signin-kit）：
#        powershell -ExecutionPolicy Bypass -File .\setup-windows.ps1 `
#            -Repo "你的GitHub用户名/workbuddy-auto-signin" -InitGithub `
#            [-FeishuWebhook "https://open.feishu.cn/open-apis/bot/v2/hook/xxx"]
#      -InitGithub 会：创建你的私有仓库 → 推送全部代码（含云端 workflow）→
#      可选写入飞书 webhook Secret。
#   B. 已有仓库的机器重装/改配置（读现有 config.json，不用传 -Repo）：
#        powershell -ExecutionPolicy Bypass -File .\setup-windows.ps1
#
# 全部参数（均可选，除 -Repo 外都有默认值）：
#   -Repo           你的私有仓库（owner/name）。缺省时尝试读 config.json，都没有则报错
#   -InitGithub     创建并初始化 -Repo 指向的私有仓库（已存在则跳过创建）
#   -FeishuWebhook  飞书群机器人 webhook（配合 -InitGithub 写入 Secret FEISHU_WEBHOOK）
#   -SecretName     凭据 Secret 名（默认 WORKBUDDY_AUTH_INFO）
#   -WorkBuddyExe   WorkBuddy.exe 完整路径（缺省自动探测：进程→常见路径→注册表）
#   -SigninTime     每日主签时间（默认 09:30）
#   -PollTimes      轮询补签班次数组（默认 01/05/09/13/17/21 六班）
#   -RefreshTime    凭据续期时间（默认 14:30）
#   -SkipSync       跳过首次凭据同步
#   -SkipSkill      跳过安装 WorkBuddy 维护 Skill
#
# 所有选择固化到仓库目录 config.json（refresh-secret.py 读同一份），
# 之后改班次/仓库直接改 config.json 再重跑本脚本即可（-Force 覆盖重建任务，幂等）。

param(
    [string]$Repo          = "",
    [switch]$InitGithub,
    [string]$FeishuWebhook = "",
    [string]$SecretName    = "WORKBUDDY_AUTH_INFO",
    [string]$WorkBuddyExe  = "",
    [string]$SigninTime    = "09:30",
    [string[]]$PollTimes   = @("01:00", "05:00", "09:00", "13:00", "17:00", "21:00"),
    [string]$RefreshTime   = "14:30",
    [switch]$SkipSync,
    [switch]$SkipSkill
)

$ErrorActionPreference = "Stop"

function Find-Pythonw {
    $c = (Get-Command pythonw -ErrorAction SilentlyContinue).Source
    if ($c -and (Test-Path $c)) { return $c }
    $py = (Get-Command python -ErrorAction SilentlyContinue).Source
    if ($py) {
        $c = Join-Path (Split-Path $py) "pythonw.exe"
        if (Test-Path $c) { return $c }
    }
    foreach ($pat in @(
        "C:\Python3*\pythonw.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python3*\pythonw.exe",
        "C:\Program Files\Python3*\pythonw.exe"
    )) {
        $hit = Get-ChildItem $pat -ErrorAction SilentlyContinue |
               Sort-Object FullName -Descending | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    $launcher = Join-Path $env:SystemRoot "py.exe"
    if (Test-Path $launcher) {
        try {
            $exe = (& $launcher -3 -c "import sys;print(sys.executable)" 2>$null | Select-Object -Last 1)
            if ($exe) {
                $c = Join-Path (Split-Path $exe.Trim()) "pythonw.exe"
                if (Test-Path $c) { return $c }
            }
        } catch { }
    }
    return $null
}

function Find-WorkBuddyExe {
    # 1) 运行中的进程（最可靠）
    try {
        $p = Get-Process -Name "WorkBuddy" -ErrorAction SilentlyContinue |
             Where-Object { $_.Path } | Select-Object -First 1
        if ($p -and (Test-Path $p.Path)) { return $p.Path }
    } catch { }

    # 2) 常见安装路径
    foreach ($cand in @(
        "$env:LOCALAPPDATA\Programs\WorkBuddy\WorkBuddy.exe",
        "D:\App\Tencent\WorkBuddy\WorkBuddy.exe",
        "C:\Program Files\Tencent\WorkBuddy\WorkBuddy.exe",
        "C:\Program Files (x86)\Tencent\WorkBuddy\WorkBuddy.exe",
        "D:\Program Files\Tencent\WorkBuddy\WorkBuddy.exe",
        "E:\App\Tencent\WorkBuddy\WorkBuddy.exe"
    )) {
        if (Test-Path $cand) { return $cand }
    }

    # 3) 注册表卸载项扫描
    foreach ($root in @(
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )) {
        $item = Get-ItemProperty $root -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -like "*WorkBuddy*" } |
                Where-Object { $_.InstallLocation } | Select-Object -First 1
        if ($item) {
            $cand = Join-Path $item.InstallLocation "WorkBuddy.exe"
            if (Test-Path $cand) { return $cand }
        }
    }
    return $null
}

Write-Host ""
Write-Host "WorkBuddy 自动签到 · 一键部署（参数化）" -ForegroundColor Cyan
Write-Host ("=" * 52) -ForegroundColor DarkGray

# --- 0. 解析仓库参数（参数 > config.json > 报错） ---
$here = $PSScriptRoot
if (-not $here) { $here = (Get-Location).Path }
$configPath = Join-Path $here "config.json"
if (-not $Repo) {
    try {
        $cfg = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($cfg.repo) { $Repo = $cfg.repo }
    } catch { }
}
if (-not $Repo) {
    Write-Host "未指定仓库且没有 config.json。" -ForegroundColor Red
    Write-Host ""
    Write-Host "新用户请带上 -Repo 和 -InitGithub，例如：" -ForegroundColor Yellow
    Write-Host '  .\setup-windows.ps1 -Repo "你的GitHub用户名/workbuddy-auto-signin" -InitGithub' -ForegroundColor Yellow
    Write-Host ""
    Write-Host "已有 config.json 的机器直接重跑本脚本（不带参数）即可。" -ForegroundColor DarkGray
    exit 1
}

# --- 1. 定位 WorkBuddy.exe 并写入用户环境变量 ---
Write-Host "[1/6] 定位 WorkBuddy.exe ..." -NoNewline
$wb = $WorkBuddyExe
if (-not $wb -or -not (Test-Path $wb)) {
    $wb = [Environment]::GetEnvironmentVariable("WORKBUDDY_EXE", "User")
}
if (-not $wb -or -not (Test-Path $wb)) { $wb = Find-WorkBuddyExe }
if (-not $wb -or -not (Test-Path $wb)) {
    Write-Host " 失败" -ForegroundColor Red
    Write-Host ""
    Write-Host "没找到 WorkBuddy.exe。请先安装并登录 WorkBuddy 桌面端，" -ForegroundColor Yellow
    Write-Host "然后重跑本脚本并手动指定：-WorkBuddyExe `"完整路径`"" -ForegroundColor Yellow
    exit 1
}
$wb = (Resolve-Path $wb).Path
[Environment]::SetEnvironmentVariable("WORKBUDDY_EXE", $wb, "User")
$env:WORKBUDDY_EXE = $wb
Write-Host " $wb" -ForegroundColor Green
Write-Host "      已写入用户环境变量 WORKBUDDY_EXE（计划任务解密凭据依赖它）" -ForegroundColor DarkGray

# --- 2. 定位 pythonw.exe ---
Write-Host "[2/6] 定位 pythonw.exe ..." -NoNewline
$pythonw = Find-Pythonw
if (-not $pythonw) {
    Write-Host " 失败" -ForegroundColor Red
    Write-Host ""
    Write-Host "没找到 pythonw.exe。请先安装 Python 3：https://www.python.org/downloads/" -ForegroundColor Yellow
    exit 1
}
Write-Host " $pythonw" -ForegroundColor Green

# --- 3. 定位仓库脚本 ---
Write-Host "[3/6] 定位签到脚本 ..." -NoNewline
$signin  = Join-Path $here "signin.py"
$refresh = Join-Path $here "refresh-secret.py"
if (-not (Test-Path $signin) -or -not (Test-Path $refresh)) {
    Write-Host " 失败" -ForegroundColor Red
    Write-Host ""
    Write-Host "当前目录缺 signin.py 或 refresh-secret.py。请先克隆 Kit 仓库：" -ForegroundColor Yellow
    Write-Host "  gh repo clone yang-212/workbuddy-signin-kit" -ForegroundColor Yellow
    exit 1
}
Write-Host " $here" -ForegroundColor Green

# --- 4. 检查 gh CLI；按需初始化用户自己的私有仓库 ---
Write-Host "[4/6] 检查 gh CLI ..." -NoNewline
$gh = (Get-Command gh -ErrorAction SilentlyContinue).Source
if (-not $gh) {
    Write-Host " 未安装" -ForegroundColor Red
    Write-Host ""
    Write-Host "需要 gh CLI（创建仓库 / 推 Secret 都靠它）：" -ForegroundColor Yellow
    Write-Host "  winget install GitHub.cli   然后运行  gh auth login" -ForegroundColor Yellow
    exit 1
}
$authOk = $false
try { gh auth status 2>$null | Out-Null; $authOk = ($LASTEXITCODE -eq 0) } catch { }
if (-not $authOk) {
    Write-Host " 已安装但未登录" -ForegroundColor Red
    Write-Host ""
    Write-Host "请先运行  gh auth login  完成浏览器授权后重跑本脚本。" -ForegroundColor Yellow
    exit 1
}
Write-Host " 已登录" -ForegroundColor Green

if ($InitGithub) {
    Write-Host "      初始化私有仓库 $Repo ..." -NoNewline
    # 创建（已存在则忽略报错继续）
    $null = & gh repo create $Repo --private 2>&1
    # 推送代码（含 .github/workflows，云端兜底靠它）
    Push-Location $here
    try {
        if (-not (Test-Path (Join-Path $here ".git"))) { git init | Out-Null }
        & git remote remove origin 2>$null
        & git remote add origin "https://github.com/$Repo.git"
        & git add -A
        $null = & git commit -m "init: workbuddy auto signin kit" 2>&1
        & git branch -M main 2>$null
        & git push -u origin main 2>&1 | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
        if ($LASTEXITCODE -ne 0) {
            throw "git push 失败（若提示 workflow 权限，运行 gh auth refresh -s workflow 后重试）"
        }
        if ($FeishuWebhook) {
            $FeishuWebhook | & gh secret set FEISHU_WEBHOOK --repo $Repo
            Write-Host "      已写入 Secret FEISHU_WEBHOOK" -ForegroundColor DarkGray
        } else {
            Write-Host "      （未提供 -FeishuWebhook，云端将只签到不推送；想加推送时：gh secret set FEISHU_WEBHOOK --repo $Repo）" -ForegroundColor DarkGray
        }
        Write-Host "      完成" -ForegroundColor Green
    } finally {
        Pop-Location
    }
}

# --- 5. 固化配置到 config.json ---
Write-Host "[5/6] 写入 config.json ..." -NoNewline
$config = [ordered]@{
    repo          = $Repo
    secret_name   = $SecretName
    workbuddy_exe = $wb
    signin_time   = $SigninTime
    poll_times    = $PollTimes
    refresh_time  = $RefreshTime
}
$config | ConvertTo-Json -Depth 3 | Set-Content -Path $configPath -Encoding UTF8
Write-Host " $configPath" -ForegroundColor Green

# --- 6. 创建计划任务（班次完全来自参数） ---
Write-Host "[6/6] 创建计划任务 ..." -NoNewline
try {
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive

    # 任务 1：每日主签
    $act1 = New-ScheduledTaskAction -Execute $pythonw -Argument "`"$signin`" silent"
    $tri1 = New-ScheduledTaskTrigger -Daily -At $SigninTime
    $set1 = New-ScheduledTaskSettingsSet -StartWhenAvailable `
            -DontStopIfGoingOnBatteries -AllowStartIfOnBatteries `
            -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    Register-ScheduledTask -TaskName "WorkBuddyAutoSignin" `
        -Action $act1 -Trigger $tri1 -Settings $set1 -Principal $principal `
        -Description "WorkBuddy daily auto signin (silent, zero token)" -Force | Out-Null

    # 任务 2：轮询补签（每班独立触发器，错过可在开机后补跑）
    if ($PollTimes.Count -gt 0) {
        $tri2 = @()
        foreach ($hh in $PollTimes) {
            $tri2 += New-ScheduledTaskTrigger -Daily -At $hh
        }
        $act2 = New-ScheduledTaskAction -Execute $pythonw -Argument "`"$signin`" silent-poll"
        $set2 = New-ScheduledTaskSettingsSet -StartWhenAvailable `
                -DontStopIfGoingOnBatteries -AllowStartIfOnBatteries `
                -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
        Register-ScheduledTask -TaskName "WorkBuddyGrowthPoll" `
            -Action $act2 -Trigger $tri2 -Settings $set2 -Principal $principal `
            -Description "WorkBuddy poll (catch-up signin + growth center)" -Force | Out-Null
    }

    # 任务 3：凭据每日续期 → GitHub Secret
    $act3 = New-ScheduledTaskAction -Execute $pythonw -Argument "`"$refresh`""
    $tri3 = New-ScheduledTaskTrigger -Daily -At $RefreshTime
    $set3 = New-ScheduledTaskSettingsSet -StartWhenAvailable `
            -DontStopIfGoingOnBatteries -AllowStartIfOnBatteries `
            -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    Register-ScheduledTask -TaskName "WorkBuddyRefreshSecret" `
        -Action $act3 -Trigger $tri3 -Settings $set3 -Principal $principal `
        -Description "WorkBuddy credential refresh -> GitHub secret ($Repo)" -Force | Out-Null
} catch {
    Write-Host " 失败" -ForegroundColor Red
    Write-Host ""
    Write-Host "错误信息：$($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
Write-Host " 完成（均可在任务计划程序中看到）" -ForegroundColor Green

# --- 首次凭据同步（把本机凭据推到用户自己的私有仓库 Secret） ---
if (-not $SkipSync) {
    Write-Host "首次同步凭据到 Secret $SecretName ..." -NoNewline
    $pythonExe = Join-Path (Split-Path $pythonw) "python.exe"
    $out = & $pythonExe $refresh 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host " 完成" -ForegroundColor Green
        $out | Where-Object { $_ -match "^\[" } | Select-Object -Last 1 | ForEach-Object {
            Write-Host "      $_" -ForegroundColor DarkGray
        }
    } else {
        Write-Host " 失败（不影响本机签到）" -ForegroundColor Yellow
        $out | Select-Object -Last 2 | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
        Write-Host "      稍后手动重跑：python refresh-secret.py" -ForegroundColor DarkGray
    }
} else {
    Write-Host "按参数跳过首次凭据同步" -ForegroundColor DarkGray
}

# 安装维护 Skill（装完后 WorkBuddy 能识别「签到状态 / doctor / 重装签到」等说法）
if (-not $SkipSkill) {
    $skillDir = Join-Path $env:USERPROFILE ".workbuddy\skills\workbuddy-signin"
    $skillSrc = Join-Path $here "skill\workbuddy-signin"
    if (Test-Path (Join-Path $skillSrc "SKILL.md")) {
        try {
            New-Item -ItemType Directory -Force -Path $skillDir | Out-Null
            Copy-Item (Join-Path $skillSrc "*") $skillDir -Force
            # Skill 里的占位信息按本次实际配置替换
            $skillFile = Join-Path $skillDir "SKILL.md"
            $skillText = [System.IO.File]::ReadAllText($skillFile, [System.Text.Encoding]::UTF8)
            $skillText = $skillText.Replace("{{REPO}}", $Repo).Replace("{{CONFIG}}", $configPath).Replace("{{DIR}}", $here)
            [System.IO.File]::WriteAllText($skillFile, $skillText, (New-Object System.Text.UTF8Encoding($false)))
            Write-Host "维护 Skill 已安装：$skillDir" -ForegroundColor DarkGray
        } catch { }
    }
}

# --- 收尾汇报 ---
Write-Host ""
Write-Host "部署完成：" -ForegroundColor Green
Write-Host ("  {0,-24} {1,-30} {2}" -f "WorkBuddyAutoSignin", "每天 $SigninTime", "签到 + 成长中心")
if ($PollTimes.Count -gt 0) {
    $pollTxt = ($PollTimes -join "/")
    Write-Host ("  {0,-24} {1,-30} {2}" -f "WorkBuddyGrowthPoll", $pollTxt, "补签 + 成长中心")
}
Write-Host ("  {0,-24} {1,-30} {2}" -f "WorkBuddyRefreshSecret", "每天 $RefreshTime", "凭据续期 → $Repo")
foreach ($name in @("WorkBuddyAutoSignin", "WorkBuddyGrowthPoll", "WorkBuddyRefreshSecret")) {
    try {
        $i = Get-ScheduledTaskInfo -TaskName $name
        Write-Host ("  {0,-24} 下次运行 {1}" -f $name, $i.NextRunTime) -ForegroundColor DarkGray
    } catch { }
}
Write-Host ""
Write-Host "配置：$configPath（改班次/仓库后重跑本脚本即可生效）" -ForegroundColor Cyan
Write-Host "日志：$(Join-Path $here 'signin.log') / refresh-secret.log" -ForegroundColor Cyan
Write-Host "验证：python signin.py status   或在 WorkBuddy 里说「签到状态」" -ForegroundColor DarkGray
Write-Host "卸载：" -ForegroundColor DarkGray
Write-Host '  Unregister-ScheduledTask -TaskName WorkBuddyAutoSignin -Confirm:$false' -ForegroundColor DarkGray
Write-Host '  Unregister-ScheduledTask -TaskName WorkBuddyGrowthPoll -Confirm:$false' -ForegroundColor DarkGray
Write-Host '  Unregister-ScheduledTask -TaskName WorkBuddyRefreshSecret -Confirm:$false' -ForegroundColor DarkGray
