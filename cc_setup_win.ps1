$ErrorActionPreference = "Stop"

$RepoUrl = "https://github.com/NanmiCoder/cc-haha"
$RepoUrlFast = "https://ghfast.top/https://github.com/NanmiCoder/cc-haha"

$EnvUrl = "https://gist.githubusercontent.com/huluxiaohuowa/804df4c68c28c0841150801e170d2449/raw/gistfile1.txt"
$EnvUrlFast = "https://ghfast.top/https://gist.githubusercontent.com/huluxiaohuowa/804df4c68c28c0841150801e170d2449/raw/gistfile1.txt"

$GhfastPrefix = if ($env:GHFAST_PREFIX) { $env:GHFAST_PREFIX.TrimEnd("/") + "/" } else { "https://ghfast.top/" }
$RtkInstallUrls = @(
    "https://raw.githubusercontent.com/rtk-ai/rtk/master/install.sh",
    "https://raw.githubusercontent.com/rtk-ai/rtk/main/install.sh"
)
$RtkDir = Join-Path $HOME ".local\rtk"
$RtkBinDir = Join-Path $RtkDir "bin"

$DefaultDir = Join-Path $HOME "cc-haha"

function Log {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Green
}

function Warn {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Die {
    param([string]$Message)
    Write-Host "[ERR] $Message" -ForegroundColor Red
    exit 1
}

function Test-Cmd {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Normalize-PathText {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }
    return $Path.Trim().TrimEnd([char]'\', [char]'/')
}

function Convert-ToGitBashPath {
    param([string]$WindowsPath)

    $full = [System.IO.Path]::GetFullPath($WindowsPath)
    $drive = $full.Substring(0, 1).ToLower()
    $rest = $full.Substring(2).Replace("\", "/")
    return "/$drive$rest"
}

function Find-GitBash {
    $gitCmd = Get-Command git.exe -ErrorAction SilentlyContinue

    if ($gitCmd) {
        $gitDir = Split-Path -Parent $gitCmd.Source

        $bashSameDir = Join-Path $gitDir "bash.exe"
        if (Test-Path $bashSameDir) {
            return $bashSameDir
        }

        $gitRoot = Split-Path -Parent $gitDir
        $bashFromRoot = Join-Path $gitRoot "bin\bash.exe"
        if (Test-Path $bashFromRoot) {
            return $bashFromRoot
        }
    }

    $bashCmd = Get-Command bash.exe -ErrorAction SilentlyContinue
    if ($bashCmd) {
        return $bashCmd.Source
    }

    $candidates = @(
        "C:\dev\apps\git\bin\bash.exe",
        "C:\Program Files\Git\bin\bash.exe",
        "C:\Program Files (x86)\Git\bin\bash.exe"
    )

    foreach ($c in $candidates) {
        if (Test-Path $c) {
            return $c
        }
    }

    return $null
}

function Download-NonEmpty {
    param(
        [string]$Primary,
        [string]$Fallback,
        [string]$Output
    )

    if (Test-Path $Output) {
        Remove-Item -Force $Output
    }

    try {
        Invoke-WebRequest -Uri $Primary -OutFile $Output -UseBasicParsing -TimeoutSec 60
    } catch {
        Warn "主地址下载失败，尝试备用地址：$Fallback"
    }

    if ((Test-Path $Output) -and ((Get-Item $Output).Length -gt 0)) {
        return
    }

    if (Test-Path $Output) {
        Remove-Item -Force $Output
    }

    Invoke-WebRequest -Uri $Fallback -OutFile $Output -UseBasicParsing -TimeoutSec 60

    if (!(Test-Path $Output) -or ((Get-Item $Output).Length -le 0)) {
        Die "下载失败，主地址和备用地址都不可用。"
    }
}

function Download-RtkInstall {
    param([string]$Output)

    foreach ($url in $RtkInstallUrls) {
        $fastUrl = $GhfastPrefix + $url

        if (Test-Path $Output) {
            Remove-Item -Force $Output
        }

        try {
            Invoke-WebRequest -Uri $url -OutFile $Output -UseBasicParsing -TimeoutSec 60
        } catch {
            Warn "RTK install.sh 直连失败，尝试 ghfast：$fastUrl"
        }

        if ((Test-Path $Output) -and ((Get-Item $Output).Length -gt 0)) {
            return
        }

        if (Test-Path $Output) {
            Remove-Item -Force $Output
        }

        try {
            Invoke-WebRequest -Uri $fastUrl -OutFile $Output -UseBasicParsing -TimeoutSec 60
        } catch {
            Warn "RTK install.sh ghfast 下载失败，尝试下一个分支。"
        }

        if ((Test-Path $Output) -and ((Get-Item $Output).Length -gt 0)) {
            return
        }
    }

    Die "RTK install.sh 下载失败。"
}

function Remove-UserPath {
    param([string]$Dir)

    $current = [Environment]::GetEnvironmentVariable("Path", "User")
    if ([string]::IsNullOrWhiteSpace($current)) {
        return
    }

    $targetNorm = Normalize-PathText $Dir
    $parts = New-Object System.Collections.Generic.List[string]

    foreach ($item in ($current -split ";")) {
        if ([string]::IsNullOrWhiteSpace($item)) {
            continue
        }

        if ((Normalize-PathText $item) -ine $targetNorm) {
            [void]$parts.Add($item)
        }
    }

    [Environment]::SetEnvironmentVariable("Path", ($parts -join ";"), "User")
}

function Add-UserPathFirst {
    param([string]$Dir)

    $current = [Environment]::GetEnvironmentVariable("Path", "User")
    if ([string]::IsNullOrWhiteSpace($current)) {
        $current = ""
    }

    $targetNorm = Normalize-PathText $Dir
    $parts = New-Object System.Collections.Generic.List[string]

    foreach ($item in ($current -split ";")) {
        if ([string]::IsNullOrWhiteSpace($item)) {
            continue
        }

        if ((Normalize-PathText $item) -ine $targetNorm) {
            [void]$parts.Add($item)
        }
    }

    $newPath = $Dir
    if ($parts.Count -gt 0) {
        $newPath = "$Dir;" + ($parts -join ";")
    }

    [Environment]::SetEnvironmentVariable("Path", $newPath, "User")

    $envParts = New-Object System.Collections.Generic.List[string]
    foreach ($item in ($env:Path -split ";")) {
        if ([string]::IsNullOrWhiteSpace($item)) {
            continue
        }

        if ((Normalize-PathText $item) -ine $targetNorm) {
            [void]$envParts.Add($item)
        }
    }

    $env:Path = "$Dir;" + ($envParts -join ";")
}

function Install-BasicTools-IfNeeded {
    if (!(Test-Cmd "git")) {
        if (Test-Cmd "winget") {
            Log "未检测到 git，尝试通过 winget 安装 Git..."
            winget install --id Git.Git -e --source winget
        } else {
            Die "未检测到 git，也未检测到 winget。请先安装 Git for Windows。"
        }
    }

    if (!(Test-Cmd "curl")) {
        Warn "未检测到 curl。Windows 11 通常内置 curl；如后续下载失败，请检查系统环境。"
    }
}

function Install-Bun-IfNeeded {
    if (Test-Cmd "bun") {
        Log "bun 已存在：$(bun --version)"
        return
    }

    Log "未检测到 bun，开始安装 bun..."
    powershell -NoProfile -ExecutionPolicy Bypass -Command "irm bun.sh/install.ps1 | iex"

    $bunBin = Join-Path $HOME ".bun\bin"
    Add-UserPathFirst $bunBin

    if (!(Test-Cmd "bun")) {
        Die "bun 安装后仍不可用。请重新打开 PowerShell，或检查 $bunBin 是否在 PATH 中。"
    }

    Log "bun 安装完成：$(bun --version)"
}

function Configure-Bun-Mirror {
    $bunfig = Join-Path $HOME ".bunfig.toml"

    if (!(Test-Path $bunfig)) {
        New-Item -ItemType File -Path $bunfig -Force | Out-Null
    }

    $text = ""
    try {
        $text = Get-Content $bunfig -Raw -ErrorAction SilentlyContinue
    } catch {
        $text = ""
    }

    if ($text -notmatch 'registry\s*=\s*"https://registry\.npmmirror\.com"') {
        Add-Content -Path $bunfig -Value @"

[install]
registry = "https://registry.npmmirror.com"
"@
    }

    Log "已配置 bun registry。"
}

function Clone-Or-Update-Repo {
    param([string]$Target)

    if (Test-Path (Join-Path $Target ".git")) {
        Log "目标目录已存在，执行 git pull：$Target"
        try {
            git -C $Target pull --ff-only
        } catch {
            Warn "git pull 失败，继续使用现有目录。"
        }
        return
    }

    if (Test-Path $Target) {
        Die "目标路径已存在但不是 git 仓库：$Target"
    }

    Log "开始克隆 cc-haha 到：$Target"

    try {
        git clone $RepoUrl $Target
        return
    } catch {
        Warn "GitHub 直连失败，尝试 ghfast：$RepoUrlFast"
    }

    git clone $RepoUrlFast $Target
}

function Replace-EnvFile {
    param([string]$Target)

    $tmp = [System.IO.Path]::GetTempFileName()

    try {
        Log "下载 .env 配置文件..."
        Download-NonEmpty -Primary $EnvUrl -Fallback $EnvUrlFast -Output $tmp

        $envFile = Join-Path $Target ".env"

        if (Test-Path $envFile) {
            $ts = Get-Date -Format "yyyyMMdd_HHmmss"
            Copy-Item $envFile "$envFile.bak.$ts" -Force
            Warn "原 .env 已备份：$envFile.bak.$ts"
        }

        Move-Item $tmp $envFile -Force
        Log ".env 已写入：$envFile"
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Install-Deps {
    param([string]$Target)

    Push-Location $Target
    try {
        if (!(Test-Path "package.json")) {
            Die "未找到 package.json，目录不是 cc-haha 仓库：$Target"
        }

        Log "执行 bun install..."
        bun install
    } finally {
        Pop-Location
    }
}

function Write-OnboardingConfig {
    # repaired config marker CLAUDE_CODE_ATTRIBUTION_HEADERS
    $p = Join-Path $HOME ".claude.json"
    $data = [ordered]@{}

    if (Test-Path $p) {
        try {
            $json = Get-Content $p -Raw | ConvertFrom-Json
            foreach ($prop in $json.PSObject.Properties) {
                $data[$prop.Name] = $prop.Value
            }
        } catch {
            $data = [ordered]@{}
        }
    }

    $data["hasCompletedOnboarding"] = $true
    $data["hasAcceptedTerms"] = $true
    $data["hasSeenIdeIntegrationNudge"] = $true
    $data["hasCompletedProjectOnboarding"] = $true
    $data["disableAllTelemetry"] = $true

    $data | ConvertTo-Json -Depth 10 | Set-Content -Path $p -Encoding UTF8
    Log "已写入 $p"
}


function Ensure-Rtk {
    New-Item -ItemType Directory -Path $RtkBinDir -Force | Out-Null
    Add-UserPathFirst $RtkBinDir

    $rtkExe = Join-Path $RtkBinDir "rtk.exe"
    $ok = $false
    if (Test-Path $rtkExe) {
        try {
            & $rtkExe --version *> $null
            if ($LASTEXITCODE -eq 0) { $ok = $true }
        } catch { $ok = $false }
    }

    $cmd = Get-Command rtk.exe -ErrorAction SilentlyContinue
    if (-not $ok -and $cmd) {
        try {
            & $cmd.Source --version *> $null
            if ($LASTEXITCODE -eq 0) {
                Copy-Item $cmd.Source $rtkExe -Force
                $ok = $true
            }
        } catch { $ok = $false }
    }

    if (-not $ok) {
        Log "安装/修复 RTK：$rtkExe"
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("rtk-install-" + [guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            $install = Join-Path $tmp "install.sh"
            Download-RtkInstall $install
            if (!(Test-Path $install) -or ((Get-Item $install).Length -le 0)) { Die "RTK install.sh 下载失败。" }
            $txt = Get-Content $install -Raw
            $txt = $txt.Replace('https://github.com', ($GhfastPrefix + 'https://github.com'))
            $txt = $txt.Replace('https://raw.githubusercontent.com', ($GhfastPrefix + 'https://raw.githubusercontent.com'))
            Set-Content -Path $install -Value $txt -Encoding UTF8

            $bash = Find-GitBash
            if (-not $bash -or !(Test-Path $bash)) { Die "找不到 Git Bash，无法执行 RTK install.sh。" }
            $rtkBashBin = Convert-ToGitBashPath $RtkBinDir
            $installBash = Convert-ToGitBashPath $install
            & $bash -lc "mkdir -p '$rtkBashBin' && RTK_INSTALL_DIR='$rtkBashBin' RTK_BIN_DIR='$rtkBashBin' bash '$installBash'"
            if ($LASTEXITCODE -ne 0) { Warn "RTK install.sh 执行失败，尝试从 release 直接下载。" }
        } finally {
            Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $cmd = Get-Command rtk.exe -ErrorAction SilentlyContinue
    if ($cmd -and (!(Test-Path $rtkExe))) { Copy-Item $cmd.Source $rtkExe -Force -ErrorAction SilentlyContinue }
    if (!(Test-Path $rtkExe)) {
        Warn "未找到 $rtkExe；如果 RTK installer 安装到了其他目录，请确认 rtk.exe 在 PATH 中。"
    }

    $rtkCmd = Get-Command rtk.exe -ErrorAction SilentlyContinue
    if (-not $rtkCmd) { $rtkCmd = Get-Command rtk -ErrorAction SilentlyContinue }
    if (-not $rtkCmd) { Die "RTK 安装后仍不可用。" }

    try { & $rtkCmd.Source --version | Out-Host } catch { Warn "rtk --version 执行异常。" }
    try { "y" | & $rtkCmd.Source init -g | Out-Host } catch { Warn "rtk init -g 执行失败，但 rtk 已安装。" }
}

function Write-ClaudeCommands {
    param([string]$Target)

    $binPath = Join-Path $Target "bin"
    New-Item -ItemType Directory -Path $binPath -Force | Out-Null

    $entry = Join-Path $binPath "claude-haha"
    if (!(Test-Path $entry)) {
        Die "找不到原仓库入口：$entry"
    }

    $bash = Find-GitBash
    if (-not $bash -or !(Test-Path $bash)) {
        Die "找不到 Git Bash。请确认 git.exe 同目录下有 bash.exe，或 bash.exe 在 PATH 中。"
    }

    $installBashRoot = Convert-ToGitBashPath $Target
    $entryBashPath = "$installBashRoot/bin/claude-haha"

    Remove-Item (Join-Path $binPath "claude") -Force -ErrorAction SilentlyContinue

    Set-Content -Path (Join-Path $binPath "claude.ps1") -Encoding UTF8 -Value @"
`$ErrorActionPreference = "Stop"

`$bash = "$bash"
`$entryBashPath = "$entryBashPath"

function Convert-ToGitBashPathLocal {
    param([string]`$WindowsPath)

    `$full = [System.IO.Path]::GetFullPath(`$WindowsPath)
    `$drive = `$full.Substring(0, 1).ToLower()
    `$rest = `$full.Substring(2).Replace("\", "/")
    return "/`$drive`$rest"
}

function Quote-BashArg {
    param([string]`$Value)

    if (`$null -eq `$Value) {
        return "''"
    }

    return "'" + (`$Value -replace "'", "'\''") + "'"
}

`$caller = Convert-ToGitBashPathLocal (Get-Location).Path

`$quotedArgs = New-Object System.Collections.Generic.List[string]
foreach (`$a in `$args) {
    [void]`$quotedArgs.Add((Quote-BashArg `$a))
}

`$argText = `$quotedArgs -join " "

`$cmd = "cd " + (Quote-BashArg `$caller) + " && bash " + (Quote-BashArg `$entryBashPath) + " " + `$argText

& `$bash -lc `$cmd
exit `$LASTEXITCODE
"@

    Set-Content -Path (Join-Path $binPath "claude.cmd") -Encoding ASCII -Value @"
@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0claude.ps1" %*
"@

    Set-Content -Path (Join-Path $binPath "claude-env.cmd") -Encoding ASCII -Value @"
@echo off
setlocal
set "ENV_FILE=$Target\.env"
where code >nul 2>nul
if %errorlevel%==0 (
  code "%ENV_FILE%"
) else (
  notepad "%ENV_FILE%"
)
"@

    Set-Content -Path (Join-Path $binPath "claude-update.cmd") -Encoding ASCII -Value @"
@echo off
setlocal
"$bash" -lc "cd '$installBashRoot' && git pull --ff-only && bun install && rm -f ./bin/claude"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Remove-Item -LiteralPath '$binPath\claude' -Force -ErrorAction SilentlyContinue"
powershell -NoProfile -ExecutionPolicy Bypass -Command "`$env:GHFAST_PREFIX='${env:GHFAST_PREFIX}'; `$p=Join-Path "$HOME" ".local\rtk\bin"; [Environment]::SetEnvironmentVariable("Path", `$p+";"+[Environment]::GetEnvironmentVariable("Path","User"), "User")"
echo updated
"@

    Set-Content -Path (Join-Path $binPath "claude-uninstall.ps1") -Encoding UTF8 -Value @"
`$ErrorActionPreference = "SilentlyContinue"

`$installDir = "$Target"
`$binDir = "$binPath"

Set-Location `$env:USERPROFILE

`$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if (`$userPath) {
    `$parts = New-Object System.Collections.Generic.List[string]

    foreach (`$item in (`$userPath -split ";")) {
        if ([string]::IsNullOrWhiteSpace(`$item)) {
            continue
        }

        if (`$item.Trim().TrimEnd([char]'\', [char]'/') -ine `$binDir.Trim().TrimEnd([char]'\', [char]'/')) {
            [void]`$parts.Add(`$item)
        }
    }

    [Environment]::SetEnvironmentVariable("Path", (`$parts -join ";"), "User")
}

Remove-Item -LiteralPath `$installDir -Recurse -Force
Write-Host "done"
"@

    Set-Content -Path (Join-Path $binPath "claude-uninstall.cmd") -Encoding ASCII -Value @"
@echo off
setlocal
echo Removing $Target
cd /d "%USERPROFILE%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0claude-uninstall.ps1"
"@

    Log "已生成命令：$binPath\claude.cmd"
    Log "已生成 PowerShell 启动器：$binPath\claude.ps1"
    Log "已生成卸载器：$binPath\claude-uninstall.cmd"
    Log "Git Bash：$bash"
    Log "cc-haha 入口：$entryBashPath"
    Log "调用 claude 时会保留当前目录。"
}

function Main {
    Write-Host "请输入 cc-haha 创建位置，直接回车默认：$DefaultDir"
    $installDir = Read-Host ">"

    if ([string]::IsNullOrWhiteSpace($installDir)) {
        $installDir = $DefaultDir
    }

    $installDir = $installDir.Replace("~", $HOME)
    $installDir = [System.IO.Path]::GetFullPath($installDir)

    Log "安装目录：$installDir"

    Install-BasicTools-IfNeeded
    Install-Bun-IfNeeded
    Configure-Bun-Mirror

    Clone-Or-Update-Repo $installDir
    Replace-EnvFile $installDir
    Install-Deps $installDir
    Write-OnboardingConfig
    Write-ClaudeCommands $installDir

    $binPath = Join-Path $installDir "bin"
    Add-UserPathFirst $binPath
    Ensure-Rtk

    Write-Host ""
    Log "安装完成。"
    Write-Host ""
    Write-Host "当前窗口已更新 PATH。测试命令："
    Write-Host "  where.exe claude"
    Write-Host "  type `"$binPath\claude.cmd`""
    Write-Host "  type `"$binPath\claude.ps1`""
    Write-Host "  claude"
    Write-Host "  claude-env"
    Write-Host "  claude-update"
    Write-Host "  claude-uninstall"
    Write-Host ""
    Warn "Windows 下使用 claude，不要使用 claude-haha。原仓库 bin\claude-haha 是 bash 脚本。"
    Warn "如果 where.exe claude 仍显示旧路径，请重新打开 PowerShell。"
}

Main
@huluxiaohuowa
Comment

# added marker CLAUDE_CODE_ATTRIBUTION_HEADERS
