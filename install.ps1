#Requires -Version 7.0
<#
.SYNOPSIS
    Watch-Sync 安裝與環境檢查部署腳本
.DESCRIPTION
    檢查 PowerShell 7、rclone 環境、設定檔 config.local.psd1、
    驗證過濾器規則與安全標記檔案，並於 Windows 工作排程器建立登入常駐工作。
.PARAMETER SkipTaskScheduler
    不自動註冊 Windows 工作排程器。
.PARAMETER CreateDesktopShortcut
    在桌面建立指向 start-watch-sync.vbs 的啟動捷徑。
.PARAMETER StartNow
    安裝檢查完成後立即啟動 Watch-Sync。
#>

[CmdletBinding()]
param(
    [switch]$SkipTaskScheduler,
    [switch]$CreateDesktopShortcut,
    [switch]$StartNow
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host "`n[+] $Message" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "  [OK] $Message" -ForegroundColor Green
}

function Write-WarnMsg {
    param([string]$Message)
    Write-Host "  [WARN] $Message" -ForegroundColor Yellow
}

function Write-ErrMsg {
    param([string]$Message)
    Write-Host "  [ERROR] $Message" -ForegroundColor Red
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "          Watch-Sync 安裝與環境部署精靈                  " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# 1. 檢查作業系統
Write-Step "檢查作業系統與 PowerShell 版本..."
if (-not $IsWindows) {
    Write-ErrMsg "此工具僅支援 Windows 作業系統。"
    exit 1
}

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-ErrMsg "需要 PowerShell 7 或以上版本。目前版本為 $($PSVersionTable.PSVersion)。"
    Write-Host "  請執行: winget install Microsoft.PowerShell" -ForegroundColor Yellow
    exit 1
}
Write-Success "PowerShell $($PSVersionTable.PSVersion) (Windows)"

# 2. 檢查 rclone
Write-Step "檢查 rclone.exe..."
try {
    $RcloneCmd = Get-Command rclone.exe -ErrorAction Stop
    $RcloneVersion = (rclone version --quiet | Select-Object -First 1)
    Write-Success "找到 rclone: $($RcloneCmd.Source) ($RcloneVersion)"
}
catch {
    Write-ErrMsg "未在系統 PATH 中找到 rclone.exe！"
    Write-Host "  建議使用 winget 安裝: winget install Rclone.Rclone" -ForegroundColor Yellow
    exit 1
}

# 3. 檢查必要檔案 (filters, icons, VERSION)
Write-Step "檢查專案核心檔案與圖示..."
$FiltersFile = Join-Path $PSScriptRoot "watch-sync.filters"
if (-not (Test-Path -LiteralPath $FiltersFile -PathType Leaf)) {
    Write-ErrMsg "缺少過濾器檔案: $FiltersFile"
    exit 1
}
Write-Success "過濾器規則: $FiltersFile"

$FiltersMd5File = "$FiltersFile.md5"
if (Test-Path -LiteralPath $FiltersMd5File -PathType Leaf) {
    Write-Success "本機過濾器 MD5: $(Split-Path $FiltersMd5File -Leaf) (由 rclone 本機維護)"
}
else {
    Write-WarnMsg "本機尚未建立過濾器 MD5 快取 (初次執行 --resync 時 rclone 會自動生成)"
}

$IconDir = Join-Path $PSScriptRoot "icons"
$StandbyIcon = Join-Path $IconDir "standby.ico"
$SyncingIcon = Join-Path $IconDir "syncing.ico"
$ErrorIcon   = Join-Path $IconDir "error.ico"

foreach ($ico in @($StandbyIcon, $SyncingIcon, $ErrorIcon)) {
    if (Test-Path -LiteralPath $ico -PathType Leaf) {
        Write-Success "找到圖示: $(Split-Path $ico -Leaf)"
    }
    else {
        Write-WarnMsg "缺少圖示: $(Split-Path $ico -Leaf) (將使用系統預設圖示替代)"
    }
}

# 4. 檢查本機設定檔 config.local.psd1
Write-Step "檢查本機設定檔 (config.local.psd1)..."
$ConfigFile = Join-Path $PSScriptRoot "config.local.psd1"
$ExampleConfigFile = Join-Path $PSScriptRoot "config.example.psd1"

if (-not (Test-Path -LiteralPath $ConfigFile -PathType Leaf)) {
    if (Test-Path -LiteralPath $ExampleConfigFile -PathType Leaf) {
        Copy-Item -LiteralPath $ExampleConfigFile -Destination $ConfigFile
        Write-WarnMsg "已自範本複製建立 config.local.psd1。"
        Write-Host "  請先以文字編輯器開啟並設定此電腦的同步目錄與 Remote：" -ForegroundColor Yellow
        Write-Host "  檔案路徑: $ConfigFile`n" -ForegroundColor Cyan
        Write-Host "  設定完成後，請重新執行 .\install.ps1 繼續完成安裝！" -ForegroundColor Cyan
        exit 0
    }
    else {
        Write-ErrMsg "缺少 config.example.psd1 範本！"
        exit 1
    }
}

try {
    $Config = Import-PowerShellDataFile -LiteralPath $ConfigFile
}
catch {
    Write-ErrMsg "config.local.psd1 解析失敗：$($_.Exception.Message)"
    exit 1
}

if (-not $Config.ContainsKey("Pairs") -or -not ($Config.Pairs -is [System.Collections.IDictionary])) {
    Write-ErrMsg "config.local.psd1 缺少 Pairs 字典區塊！"
    exit 1
}

# 5. 驗證配對與標記檔案
Write-Step "驗證同步配對 (Pairs)..."
$CheckFileName = ".rclone-bisync-check"
if ($Config.ContainsKey("Settings") -and ($Config.Settings -is [System.Collections.IDictionary])) {
    if ($Config.Settings.ContainsKey("CheckFileName")) {
        $CheckFileName = [string]$Config.Settings.CheckFileName
    }
}

$AvailableRemotes = @(rclone listremotes --quiet)

foreach ($PairKey in $Config.Pairs.Keys) {
    $Pair = $Config.Pairs[$PairKey]
    $LocalRaw = [string]$Pair.Local
    $RemoteRaw = [string]$Pair.Remote

    $LocalPath = [System.Environment]::ExpandEnvironmentVariables($LocalRaw)

    Write-Host "  -> 配對 [$PairKey]:" -ForegroundColor White
    Write-Host "     本地: $LocalPath" -ForegroundColor DarkGray
    Write-Host "     遠端: $RemoteRaw" -ForegroundColor DarkGray

    # 檢查本地目錄
    if (-not (Test-Path -LiteralPath $LocalPath -PathType Container)) {
        Write-WarnMsg "本地目錄尚未建立: $LocalPath"
    }
    else {
        # 檢查安全標記檔案
        $CheckFile = Join-Path $LocalPath $CheckFileName
        if (Test-Path -LiteralPath $CheckFile -PathType Leaf) {
            Write-Success "安全標記存在: $CheckFileName"
        }
        else {
            Write-WarnMsg "缺少安全標記檔案: $CheckFile (請確保本地與雲端目錄皆包含此檔案以防止誤刪)"
        }
    }

    # 檢查 Remote 名稱格式
    $RemoteRoot = ($RemoteRaw -split ":")[0] + ":"
    if ($AvailableRemotes -contains $RemoteRoot) {
        Write-Success "遠端 Remote 有效: $RemoteRoot"
    }
    else {
        Write-WarnMsg "在 rclone config 中找不到 Remote: $RemoteRoot (請執行 rclone config 進行設定)"
    }
}

# 6. 工作排程器 (Task Scheduler) 設定
if (-not $SkipTaskScheduler) {
    Write-Step "配置 Windows 工作排程器 (常駐背景啟動)..."
    $TaskName = "Watch-Sync-Tray"
    $PwshExe = (Get-Command pwsh.exe).Source
    $ScriptPath = Join-Path $PSScriptRoot "watch-sync-tray.ps1"

    $Action = New-ScheduledTaskAction `
        -Execute $PwshExe `
        -Argument "-NoLogo -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$ScriptPath`"" `
        -WorkingDirectory $PSScriptRoot

    $Trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME

    # 關鍵防坑設置：ExecutionTimeLimit = 0 (永不逾時終止)，電池不斷電
    $Settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -MultipleInstances IgnoreNew `
        -StartWhenAvailable

    try {
        Register-ScheduledTask `
            -TaskName $TaskName `
            -Action $Action `
            -Trigger $Trigger `
            -Settings $Settings `
            -Description "Watch-Sync background system tray watcher for rclone bisync" `
            -Force | Out-Null
        Write-Success "已註冊工作排程器工作: $TaskName (使用者登入時自動以無黑窗背景啟動)"
    }
    catch {
        Write-WarnMsg "註冊工作排程器需要適當權限。如果失敗，您亦可使用 start-watch-sync.vbs 手動啟動。錯誤訊息: $($_.Exception.Message)"
    }
}
else {
    Write-Step "跳過工作排程器註冊 (-SkipTaskScheduler)。"
}

# 7. 建立桌面捷徑 (選填)
if ($CreateDesktopShortcut) {
    Write-Step "在桌面建立捷徑..."
    try {
        $WshShell = New-Object -ComObject WScript.Shell
        $DesktopPath = [System.Environment]::GetFolderPath("Desktop")
        $ShortcutPath = Join-Path $DesktopPath "Watch-Sync.lnk"
        $VbsPath = Join-Path $PSScriptRoot "start-watch-sync.vbs"

        $Shortcut = $WshShell.CreateShortcut($ShortcutPath)
        $Shortcut.TargetPath = "wscript.exe"
        $Shortcut.Arguments = "`"$VbsPath`""
        $Shortcut.WorkingDirectory = $PSScriptRoot
        if (Test-Path -LiteralPath $StandbyIcon) {
            $Shortcut.IconLocation = "$StandbyIcon,0"
        }
        $Shortcut.Description = "啟動 Watch-Sync 雲端同步"
        $Shortcut.Save()
        Write-Success "已建立桌面捷徑: $ShortcutPath"
    }
    catch {
        Write-WarnMsg "建立桌面捷徑失敗: $($_.Exception.Message)"
    }
}

# 8. 檢查目前運行狀態
Write-Step "檢查執行狀態..."
$MutexName = "Local\RcloneSyncWatcher"
$TestMutex = [System.Threading.Mutex]::new($false, $MutexName)
$IsRunning = $false
try {
    if (-not $TestMutex.WaitOne(0, $false)) {
        $IsRunning = $true
    }
}
catch {
    $IsRunning = $true
}
finally {
    $TestMutex.Dispose()
}

if ($IsRunning) {
    Write-Success "Watch-Sync 目前正在運行中。"
    Write-Host "  若要套用最新設定與代碼，請於系統匣圖示右鍵點選「Restart」即可！" -ForegroundColor Green
}
else {
    Write-Host "  Watch-Sync 目前尚未啟動。" -ForegroundColor Yellow
    if ($StartNow) {
        Write-Step "正在啟動 Watch-Sync..."
        $VbsPath = Join-Path $PSScriptRoot "start-watch-sync.vbs"
        Start-Process "wscript.exe" -ArgumentList "`"$VbsPath`"" -WorkingDirectory $PSScriptRoot
        Write-Success "已透過 start-watch-sync.vbs 在背景啟動 Watch-Sync！"
    }
    else {
        Write-Host "  您可以點擊 start-watch-sync.vbs 手動啟動，或重新登入讓排程自動啟動。" -ForegroundColor Cyan
    }
}

Write-Host "`n==========================================================" -ForegroundColor Cyan
Write-Host "                     部署完成！                           " -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Cyan
