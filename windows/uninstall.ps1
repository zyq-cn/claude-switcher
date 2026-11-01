# Claude 切换器 Windows 版 - 卸载器
# 用法:右键「使用 PowerShell 运行」,或
#   uninstall.ps1                 交互式,保留账号快照
#   uninstall.ps1 -Yes            免交互(仍需 -PurgeData 才删账号快照)
#   uninstall.ps1 -PurgeData      连账号快照一起删除,需按提示输入 DELETE
#   uninstall.ps1 -KeepSystem     不还原时区/地区格式/IPv6
#   uninstall.ps1 -KeepRules      不清理 Clash Verge 的 Script.js 托管规则块
#   uninstall.ps1 -DryRun         只打印将要执行的动作
param(
    [switch]$PurgeData,
    [switch]$KeepSystem,
    [switch]$KeepRules,
    [switch]$Yes,
    [switch]$DryRun
)

$ErrorActionPreference = 'SilentlyContinue'
$BASE = Join-Path $env:USERPROFILE '.claude-switcher'
$TASK = 'ClaudeBodyguard'
$DESKTOP = [Environment]::GetFolderPath('Desktop')
if (-not $DESKTOP) { $DESKTOP = Join-Path $env:USERPROFILE 'Desktop' }
$LNK = Join-Path $DESKTOP 'Claude切换器.lnk'
$CLASH_DIR = @(
    "$env:APPDATA\io.github.clash-verge-rev.clash-verge-rev",
    "$env:LOCALAPPDATA\io.github.clash-verge-rev.clash-verge-rev"
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

function Write-Step([string]$Text) { Write-Host "      $Text" -ForegroundColor DarkGray }

function Invoke-Do([string]$Label, [scriptblock]$Action) {
    if ($DryRun) {
        Write-Host "[DRY] $Label" -ForegroundColor DarkYellow
        return
    }
    try {
        & $Action
        Write-Host "[OK]  $Label" -ForegroundColor Green
    } catch {
        Write-Host "[WARN] $Label 未完成: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Get-DirSizeMB([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    $sum = (Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum
    if (-not $sum) { return 0 }
    return [math]::Round($sum / 1MB, 1)
}

Write-Host "=============================="
Write-Host "  Claude 账号切换器 - Windows 卸载"
Write-Host "=============================="
Write-Host ""

$hasTask = [bool](Get-ScheduledTask -TaskName $TASK -ErrorAction SilentlyContinue)
if (-not (Test-Path -LiteralPath $BASE) -and -not $hasTask) {
    Write-Host "未检测到安装痕迹: $BASE 与计划任务 $TASK 都不存在。" -ForegroundColor Yellow
    if (-not $Yes) { Read-Host "按回车退出" | Out-Null }
    exit 0
}

$dataSize = Get-DirSizeMB $BASE
$plan = @(
    "停止并注销计划任务 $TASK",
    "结束界面与保镖进程",
    "删除桌面快捷方式 Claude切换器.lnk"
)
if (-not $KeepRules) { $plan += "清理 Clash Verge Script.js 中的托管规则块(先备份)" }
if (-not $KeepSystem) { $plan += "按安装时记录还原时区/地区格式/IPv6(需一次管理员授权)" }
if ($PurgeData) { $plan += "删除数据目录 $BASE ($dataSize MB,含账号登录态)" }
else { $plan += "保留数据目录 $BASE ($dataSize MB)" }

Write-Host "将执行:" -ForegroundColor Cyan
$plan | ForEach-Object { Write-Host "  - $_" }
Write-Host ""
Write-Host "卸载不会删除 %APPDATA%\Claude(Claude 自身数据),也不会退出你的 Claude 账号。" -ForegroundColor DarkGray
Write-Host ""
if (-not $Yes -and -not $DryRun) {
    $ans = Read-Host "继续? (y/N)"
    if ($ans -ne 'y' -and $ans -ne 'Y') {
        Write-Host "已取消,未做任何修改。" -ForegroundColor Yellow
        exit 1
    }
    Write-Host ""
}

# ---- 1. 结束界面与保镖进程(按命令行匹配,不误杀其他 PowerShell) ----
Invoke-Do "结束界面与保镖进程" {
    $targets = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'claude-bodyguard\.ps1|SwitcherUI\.ps1' }
    foreach ($t in $targets) { Stop-Process -Id $t.ProcessId -Force -ErrorAction SilentlyContinue }
    if ($targets) { Write-Step "已结束 $($targets.Count) 个进程" }
}

# ---- 2. 注销计划任务 ----
Invoke-Do "注销计划任务 $TASK" {
    if (Get-ScheduledTask -TaskName $TASK -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $TASK -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TASK -Confirm:$false -ErrorAction Stop
    } else {
        Write-Step "计划任务不存在,跳过"
    }
}

# ---- 3. 桌面快捷方式 ----
Invoke-Do "删除桌面快捷方式" {
    if (Test-Path -LiteralPath $LNK) {
        Remove-Item -LiteralPath $LNK -Force -ErrorAction Stop
    } else {
        Write-Step "快捷方式不存在,跳过"
    }
}

# ---- 4. Clash Verge 托管规则 ----
$scriptJs = ''
if ($CLASH_DIR) { $scriptJs = Join-Path $CLASH_DIR 'profiles\Script.js' }
if (-not $KeepRules) {
    if ($scriptJs -and (Test-Path -LiteralPath $scriptJs)) {
        $jsText = [System.IO.File]::ReadAllText($scriptJs)
        if ($jsText -match '// >>> claude-switcher managed rules >>>') {
            Invoke-Do "清理 Clash Verge 托管规则" {
                $bak = "$scriptJs.bak.uninstall.$((Get-Date).ToString('yyyyMMddHHmmss'))"
                Copy-Item -LiteralPath $scriptJs -Destination $bak -Force -ErrorAction Stop
                $stripped = [regex]::Replace($jsText,
                    '(?s)\r?\n?// >>> claude-switcher managed rules >>>.*?// <<< claude-switcher managed rules <<<', '')
                [System.IO.File]::WriteAllText($scriptJs, $stripped, (New-Object System.Text.UTF8Encoding $false))
                Write-Step "备份: $bak"
            }
            Write-Host "      重启 Clash Verge 后该规则才真正失效" -ForegroundColor DarkGray
        } else {
            Write-Host "[OK]  Script.js 中没有本项目规则,跳过" -ForegroundColor Green
        }
    } else {
        Write-Host "[OK]  未发现 Clash Verge 规则文件,跳过" -ForegroundColor Green
    }
}

# ---- 5. 还原安装时改动的系统设置 ----
$adminLines = @()
if (-not $KeepSystem) {
    $origPath = Join-Path $BASE 'system-originals.json'
    $orig = $null
    if (Test-Path -LiteralPath $origPath) {
        try { $orig = Get-Content -LiteralPath $origPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $orig = $null }
    }
    if ($orig) {
        if ($orig.timeZone) { $adminLines += "Set-TimeZone -Id '$($orig.timeZone)' -ErrorAction SilentlyContinue" }
        if ($orig.culture) { $adminLines += "Set-Culture -CultureInfo '$($orig.culture)' -ErrorAction SilentlyContinue" }
        $adapters = @($orig.ipv6Adapters)
        if ($adapters.Count -gt 0) {
            $list = ($adapters | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ','
            $adminLines += "Get-NetAdapterBinding -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue | Where-Object { `$_.Name -in @($list) } | Enable-NetAdapterBinding -Confirm:`$false"
        }
        Write-Host "[OK]  找到安装时的系统设置记录(时区=$($orig.timeZone) 地区=$($orig.culture) IPv6=$($adapters.Count) 个网卡)" -ForegroundColor Green
    } else {
        Write-Host "[WARN] 没有安装时的系统设置记录(旧版安装器),以下项目需要手动改回:" -ForegroundColor Yellow
        Write-Host "       时区: 当前 $((Get-TimeZone).Id) → 按你所在地区自行选择" -ForegroundColor DarkGray
        Write-Host "       地区格式: 当前 $([System.Globalization.CultureInfo]::CurrentCulture.Name) → 设置 → 时间和语言 → 语言和区域" -ForegroundColor DarkGray
        Write-Host "       IPv6: Enable-NetAdapterBinding -ComponentID ms_tcpip6" -ForegroundColor DarkGray
    }
}

if ($adminLines.Count -gt 0) {
    if ($DryRun) {
        Write-Host "[DRY] 需管理员执行的还原命令:" -ForegroundColor DarkYellow
        $adminLines | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
    } else {
        Write-Host "还原系统设置(时区/地区格式/IPv6),请在弹窗中允许管理员权限..." -ForegroundColor Cyan
        $tmp = "$env:TEMP\claude-uninstall-$([guid]::NewGuid().Guid).ps1"
        ($adminLines -join "`r`n") | Out-File -Encoding utf8 $tmp
        try {
            Start-Process powershell -Verb RunAs -Wait -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$tmp`""
            Write-Host "[OK]  系统设置已还原" -ForegroundColor Green
        } catch {
            Write-Host "[WARN] 管理员授权被取消,系统设置未还原(可手动改回时区/地区格式,并重新启用 IPv6)" -ForegroundColor Yellow
        }
        Remove-Item -LiteralPath $tmp -Force
    }
}

# ---- 6. 数据目录 ----
if ($PurgeData) {
    Write-Host ""
    Write-Host "要删除的目录含各账号唯一的登录态,删除后无法找回:" -ForegroundColor Red
    Write-Host "  $BASE ($dataSize MB)" -ForegroundColor Red
    if ($DryRun) {
        Write-Host "[DRY] 试运行不会删除该目录" -ForegroundColor DarkYellow
    } else {
        $confirm = [bool]$Yes
        if (-not $Yes) {
            $typed = Read-Host "确认删除请输入 DELETE(其他任意输入跳过)"
            if ($typed -ceq 'DELETE') { $confirm = $true }
        }
        if ($confirm) {
            Invoke-Do "删除数据目录 $BASE" { Remove-Item -LiteralPath $BASE -Recurse -Force -ErrorAction Stop }
        } else {
            Write-Host "[WARN] 未确认,数据保留在 $BASE" -ForegroundColor Yellow
        }
    }
} else {
    Write-Host ""
    Write-Host "[OK]  账号快照与设置已保留: $BASE ($dataSize MB)" -ForegroundColor Green
    Write-Host "      彻底删除: uninstall.ps1 -PurgeData,或 Remove-Item -Recurse -Force '$BASE'" -ForegroundColor DarkGray
}

Write-Host ""
if ($DryRun) {
    Write-Host "试运行结束,未做任何修改。" -ForegroundColor DarkYellow
} else {
    Write-Host "卸载完成。Claude 已不再受 Kill-Switch 保护,需要时重新运行 install.ps1 安装。" -ForegroundColor Cyan
}
if (-not $Yes -and -not $DryRun) { Read-Host "按回车关闭" | Out-Null }
