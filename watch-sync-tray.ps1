<#
.SYNOPSIS
    Watch-Sync: Background bi-directional file synchronization with system tray UI.
.DESCRIPTION
    A lightweight background daemon combining PowerShell 7, FileSystemWatcher,
    and rclone bisync. Features local change debouncing, idle detection,
    sleep/resume detection, safety markers, and a Windows notification area icon.
#>

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Native non-zero exit codes are handled explicitly below.
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

# ----------------------------
# Version and logging
# ----------------------------

$VersionFile = Join-Path $PSScriptRoot "VERSION"
$AppVersion = if (Test-Path -LiteralPath $VersionFile -PathType Leaf) {
    (Get-Content -LiteralPath $VersionFile -Raw).Trim()
}
else {
    "0.2.0"
}

$LogDir = Join-Path $env:LOCALAPPDATA "rclone\watch-sync"
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

function Get-LogFile {
    Join-Path $LogDir ("watch-sync-{0:yyyy-MM}.log" -f (Get-Date))
}

function Write-Log {
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet("INFO", "WARN", "ERROR")]
        [string]$Level = "INFO"
    )

    $Line = "{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}" -f (Get-Date), $Level, $Message
    Add-Content -LiteralPath (Get-LogFile) -Value $Line -Encoding UTF8
    Write-Host $Line
}

function Show-FatalStartupError {
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [string]$Title = "Watch-Sync 啟動失敗"
    )

    Write-Log $Message "ERROR"
    if ($IsWindows) {
        try {
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
            [System.Windows.Forms.MessageBox]::Show(
                $Message,
                $Title,
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
        }
        catch {}
    }
}

try {
    $RcloneExe = (Get-Command rclone.exe -ErrorAction Stop).Source
}
catch {
    Show-FatalStartupError "在系統 PATH 中找不到 rclone.exe！`n`n請先安裝 rclone 並加入系統 PATH。"
    exit 1
}

# ----------------------------
# Bisync filters and icons
# ----------------------------

$FiltersFile = Join-Path $PSScriptRoot "watch-sync.filters"
if (-not (Test-Path -LiteralPath $FiltersFile -PathType Leaf)) {
    Show-FatalStartupError "缺少 Bisync 過濾器檔案：`n$FiltersFile"
    exit 1
}

$IconDir = Join-Path $PSScriptRoot "icons"
$StandbyIconPath = Join-Path $IconDir "standby.ico"
$SyncingIconPath = Join-Path $IconDir "syncing.ico"
$ErrorIconPath   = Join-Path $IconDir "error.ico"

# ----------------------------
# Configuration defaults and loading
# ----------------------------

# Wait until local filesystem activity has been quiet for this long.
$QuietSeconds = 30

# Sync all pairs when the user first becomes idle for this long.
$IdleMinutes = 10

# While the machine remains idle, check the remote again at this interval.
# Set to 0 to disable repeated checks during one long idle period.
$IdleRepeatMinutes = 60

# A long pause in the watcher loop is treated as sleep/resume or suspension.
$ResumeGapSeconds = 90
$ResumeDelaySeconds = 10

$StartupDelaySeconds = 3
$RetryDelaySeconds = 120
$MaxAutoRetries = 3

# Conservative defaults for background Google Drive bisync.
$Transfers = 4
$Checkers  = 8

# Keep this file present at the root of every synchronized pair on both sides.
$CheckFileName = ".rclone-bisync-check"

# Ignore these names in FileSystemWatcher so Windows metadata alone does not
# trigger a sync. They are also excluded by watch-sync.filters.
$WatcherIgnoreNames = @(
    "Thumbs.db",
    "desktop.ini"
)

# Show a Windows notification-area icon when running interactively.
# Launch with pwsh.exe -STA -WindowStyle Hidden to get a tray-only UI.
$EnableTrayIcon = $true
$ShowTrayErrorNotifications = $true

# Load local machine configuration
$ConfigFile = Join-Path $PSScriptRoot "config.local.psd1"
if (-not (Test-Path -LiteralPath $ConfigFile -PathType Leaf)) {
    Show-FatalStartupError "找不到本機設定檔：`n$ConfigFile`n`n請先複製 config.example.psd1 為 config.local.psd1 並填妥同步目錄設定。"
    exit 1
}

try {
    $LocalConfig = Import-PowerShellDataFile -LiteralPath $ConfigFile
}
catch {
    Show-FatalStartupError "解析本機設定檔失敗：`n$ConfigFile`n`n錯誤訊息：$($_.Exception.Message)"
    exit 1
}

if (-not $LocalConfig.ContainsKey("Pairs") -or -not ($LocalConfig.Pairs -is [System.Collections.IDictionary])) {
    Show-FatalStartupError "設定檔格式錯誤：必須包含 Pairs 字典區塊。"
    exit 1
}

$Pairs = [ordered]@{}
foreach ($PairKey in $LocalConfig.Pairs.Keys) {
    $PairData = $LocalConfig.Pairs[$PairKey]
    if (-not $PairData.ContainsKey("Local") -or -not $PairData.ContainsKey("Remote")) {
        Show-FatalStartupError "配對 [$PairKey] 設定不完整：必須包含 Local 與 Remote。"
        exit 1
    }

    $RawLocal = [string]$PairData.Local
    $RawRemote = [string]$PairData.Remote
    $ExpandedLocal = [System.Environment]::ExpandEnvironmentVariables($RawLocal)

    $Pairs[$PairKey] = [ordered]@{
        Local  = $ExpandedLocal
        Remote = $RawRemote
    }
}

if ($LocalConfig.ContainsKey("Settings") -and ($LocalConfig.Settings -is [System.Collections.IDictionary])) {
    $S = $LocalConfig.Settings
    if ($S.ContainsKey("QuietSeconds")) { $QuietSeconds = [int]$S.QuietSeconds }
    if ($S.ContainsKey("IdleMinutes")) { $IdleMinutes = [int]$S.IdleMinutes }
    if ($S.ContainsKey("IdleRepeatMinutes")) { $IdleRepeatMinutes = [int]$S.IdleRepeatMinutes }
    if ($S.ContainsKey("ResumeGapSeconds")) { $ResumeGapSeconds = [int]$S.ResumeGapSeconds }
    if ($S.ContainsKey("ResumeDelaySeconds")) { $ResumeDelaySeconds = [int]$S.ResumeDelaySeconds }
    if ($S.ContainsKey("StartupDelaySeconds")) { $StartupDelaySeconds = [int]$S.StartupDelaySeconds }
    if ($S.ContainsKey("RetryDelaySeconds")) { $RetryDelaySeconds = [int]$S.RetryDelaySeconds }
    if ($S.ContainsKey("MaxAutoRetries")) { $MaxAutoRetries = [int]$S.MaxAutoRetries }
    if ($S.ContainsKey("Transfers")) { $Transfers = [int]$S.Transfers }
    if ($S.ContainsKey("Checkers")) { $Checkers = [int]$S.Checkers }
    if ($S.ContainsKey("CheckFileName")) { $CheckFileName = [string]$S.CheckFileName }
    if ($S.ContainsKey("EnableTrayIcon")) { $EnableTrayIcon = [bool]$S.EnableTrayIcon }
    if ($S.ContainsKey("ShowTrayErrorNotifications")) { $ShowTrayErrorNotifications = [bool]$S.ShowTrayErrorNotifications }
}

# ----------------------------
# System tray UI
# ----------------------------

$script:TrayIcon = $null
$script:TrayStatusItem = $null
$script:TrayMenu = $null
$script:StandbyIcon = $null
$script:SyncingIcon = $null
$script:ErrorIcon   = $null
$script:ManualSyncRequested = $false
$script:RestartRequested = $false
$script:ExitRequested = $false
$script:ServiceReady = $false
$script:ResumeSyncDueAt = $null
$script:ActiveSyncJobs = [System.Collections.Generic.List[object]]::new()

function Get-StateIcon {
    param(
        [Parameter(Mandatory)]
        [ValidateSet("Normal", "Syncing", "Warning")]
        [string]$State
    )

    switch ($State) {
        "Syncing" {
            if ($null -ne $script:SyncingIcon) { return $script:SyncingIcon }
            if (Test-Path -LiteralPath $SyncingIconPath -PathType Leaf) {
                try {
                    $script:SyncingIcon = [System.Drawing.Icon]::new($SyncingIconPath)
                    return $script:SyncingIcon
                }
                catch {
                    Write-Log "Failed to load syncing icon: $($_.Exception.Message)" "WARN"
                }
            }
            return [System.Drawing.SystemIcons]::Information
        }
        "Warning" {
            if ($null -ne $script:ErrorIcon) { return $script:ErrorIcon }
            if (Test-Path -LiteralPath $ErrorIconPath -PathType Leaf) {
                try {
                    $script:ErrorIcon = [System.Drawing.Icon]::new($ErrorIconPath)
                    return $script:ErrorIcon
                }
                catch {
                    Write-Log "Failed to load error icon: $($_.Exception.Message)" "WARN"
                }
            }
            return [System.Drawing.SystemIcons]::Warning
        }
        default {
            if ($null -ne $script:StandbyIcon) { return $script:StandbyIcon }
            if (Test-Path -LiteralPath $StandbyIconPath -PathType Leaf) {
                try {
                    $script:StandbyIcon = [System.Drawing.Icon]::new($StandbyIconPath)
                    return $script:StandbyIcon
                }
                catch {
                    Write-Log "Failed to load standby icon: $($_.Exception.Message)" "WARN"
                }
            }
            try {
                $script:StandbyIcon = [System.Drawing.Icon]::ExtractAssociatedIcon($RcloneExe)
                if ($null -ne $script:StandbyIcon) { return $script:StandbyIcon }
            }
            catch {}
            return [System.Drawing.SystemIcons]::Application
        }
    }
}

function Set-TrayStatus {
    param(
        [Parameter(Mandatory)]
        [string]$Status,

        [ValidateSet("Normal", "Syncing", "Warning")]
        [string]$State = "Normal"
    )

    if ($null -eq $script:TrayIcon) {
        return
    }

    if ($null -ne $script:TrayStatusItem) {
        $script:TrayStatusItem.Text = "Status: $Status"
    }

    # NotifyIcon.Text has a small platform-dependent length limit.
    $ToolTip = "rclone Sync - $Status"
    if ($ToolTip.Length -gt 63) {
        $ToolTip = $ToolTip.Substring(0, 63)
    }
    $script:TrayIcon.Text = $ToolTip
    $script:TrayIcon.Icon = Get-StateIcon -State $State
}

function Refresh-TrayStatus {
    if ($null -eq $script:TrayIcon) {
        return
    }

    $StateVariable = Get-Variable -Name State -Scope Script -ErrorAction SilentlyContinue
    if ($null -eq $StateVariable) {
        Set-TrayStatus -Status "Starting"
        return
    }


    $PairState = $StateVariable.Value
    $BlockedNames = @()
    $RetryPausedNames = @()
    $RetryPendingNames = @()
    $SyncingNames = @()

    foreach ($Name in $Pairs.Keys) {
        $Entry = $PairState[$Name]
        if ($null -eq $Entry) {
            continue
        }

        if ($Entry.Blocked) {
            $BlockedNames += $Name
        }
        elseif ($Entry.RetryPaused) {
            $RetryPausedNames += $Name
        }
        elseif ($null -ne $Entry.RetryAt) {
            $Remaining = [math]::Max(0, [int][math]::Ceiling(($Entry.RetryAt - (Get-Date)).TotalSeconds))
            $RetryPendingNames += "$Name (${Remaining}s)"
        }
        elseif ($Entry.InProgress) {
            $SyncingNames += $Name
        }
    }

    # A warning on any pair must not be overwritten by a later successful pair.
    if ($BlockedNames.Count -gt 0) {
        Set-TrayStatus -Status ("Blocked: " + ($BlockedNames -join ", ")) -State "Warning"
        return
    }

    if ($RetryPausedNames.Count -gt 0) {
        Set-TrayStatus -Status ("Retry paused: " + ($RetryPausedNames -join ", ")) -State "Warning"
        return
    }

    if ($RetryPendingNames.Count -gt 0) {
        Set-TrayStatus -Status ("Retry pending: " + ($RetryPendingNames -join ", ")) -State "Warning"
        return
    }

    if ($SyncingNames.Count -gt 0) {
        if ($script:ExitRequested) {
            Set-TrayStatus -Status "Exit after current sync" -State "Syncing"
        }
        else {
            Set-TrayStatus -Status ("Syncing " + ($SyncingNames -join ", ")) -State "Syncing"
        }
        return
    }

    if ($script:ExitRequested) {
        Set-TrayStatus -Status "Exiting"
        return
    }

    if (-not $script:ServiceReady) {
        Set-TrayStatus -Status "Starting"
        return
    }

    Set-TrayStatus -Status "Watching"
}

function Show-TrayError {
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    if (-not $ShowTrayErrorNotifications -or $null -eq $script:TrayIcon) {
        return
    }

    $script:TrayIcon.BalloonTipTitle = "rclone Sync"
    $script:TrayIcon.BalloonTipText = $Message
    $script:TrayIcon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Warning
    $script:TrayIcon.ShowBalloonTip(5000)
}

function Initialize-TrayIcon {
    if (-not $EnableTrayIcon -or -not $IsWindows) {
        return
    }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $Menu = [System.Windows.Forms.ContextMenuStrip]::new()

    $VersionItem = [System.Windows.Forms.ToolStripMenuItem]::new("Watch-Sync v$AppVersion")
    $VersionItem.Enabled = $false
    [void]$Menu.Items.Add($VersionItem)

    [void]$Menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())

    $StatusItem = [System.Windows.Forms.ToolStripMenuItem]::new("Status: Starting")
    $StatusItem.Enabled = $false
    [void]$Menu.Items.Add($StatusItem)

    [void]$Menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())

    $SyncItem = [System.Windows.Forms.ToolStripMenuItem]::new("Sync all now")
    $SyncItem.add_Click({
        $script:ManualSyncRequested = $true
    })
    [void]$Menu.Items.Add($SyncItem)

    $LogItem = [System.Windows.Forms.ToolStripMenuItem]::new("Open log folder")
    $LogItem.add_Click({
        Start-Process -FilePath "explorer.exe" -ArgumentList $LogDir
    })
    [void]$Menu.Items.Add($LogItem)

    $RestartItem = [System.Windows.Forms.ToolStripMenuItem]::new("Restart")
    $RestartItem.add_Click({
        $script:RestartRequested = $true
        $script:ExitRequested = $true
        Refresh-TrayStatus
    })
    [void]$Menu.Items.Add($RestartItem)

    [void]$Menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())

    $ExitItem = [System.Windows.Forms.ToolStripMenuItem]::new("Exit")
    $ExitItem.add_Click({
        $script:ExitRequested = $true
        Refresh-TrayStatus
    })
    [void]$Menu.Items.Add($ExitItem)

    $Icon = [System.Windows.Forms.NotifyIcon]::new()
    $Icon.Icon = Get-StateIcon -State "Normal"
    $Icon.Text = "rclone Sync"
    $Icon.ContextMenuStrip = $Menu
    $Icon.Visible = $true
    $Icon.add_DoubleClick({
        Start-Process -FilePath "explorer.exe" -ArgumentList $LogDir
    })

    $script:TrayMenu = $Menu
    $script:TrayStatusItem = $StatusItem
    $script:TrayIcon = $Icon
    Refresh-TrayStatus
}

function Dispose-TrayIcon {
    if ($null -ne $script:TrayIcon) {
        try {
            $script:TrayIcon.Visible = $false
            $script:TrayIcon.Dispose()
        }
        catch {
        }
        $script:TrayIcon = $null
    }

    if ($null -ne $script:TrayMenu) {
        try {
            $script:TrayMenu.Dispose()
        }
        catch {
        }
        $script:TrayMenu = $null
    }

    foreach ($ico in @($script:StandbyIcon, $script:SyncingIcon, $script:ErrorIcon)) {
        if ($null -ne $ico -and
            $ico -ne [System.Drawing.SystemIcons]::Application -and
            $ico -ne [System.Drawing.SystemIcons]::Information -and
            $ico -ne [System.Drawing.SystemIcons]::Warning) {
            try {
                $ico.Dispose()
            }
            catch {
            }
        }
    }
    $script:StandbyIcon = $null
    $script:SyncingIcon = $null
    $script:ErrorIcon   = $null
}

# ----------------------------
# Prevent duplicate watcher instances
# ----------------------------

$MutexName = "Local\RcloneSyncWatcher"
$Mutex = [System.Threading.Mutex]::new($false, $MutexName)
$HaveMutex = $false

try {
    try {
        $HaveMutex = $Mutex.WaitOne(0, $false)
    }
    catch [System.Threading.AbandonedMutexException] {
        $HaveMutex = $true
    }

    if (-not $HaveMutex) {
        Write-Log "Another watcher instance is already running."
        if ($IsWindows) {
            try {
                Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
                [System.Windows.Forms.MessageBox]::Show(
                    "Watch-Sync 目前已經在背景執行中！`n`n狀態：正常同步監聽中`n位置：螢幕右下角系統匣（請檢查 ^ 展開圖示）",
                    "Watch-Sync",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Information
                ) | Out-Null
            }
            catch {}
        }
        exit 0
    }

    try {
        Initialize-TrayIcon
    }
    catch {
        Write-Log "Could not initialize system tray icon: $($_.Exception.Message). Continuing without tray UI." "WARN"
    }

    # ----------------------------
    # Windows idle-time helper
    # ----------------------------

    if (-not ("RcloneWatcherNativeMethods" -as [type])) {
        Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class RcloneWatcherNativeMethods
{
    [StructLayout(LayoutKind.Sequential)]
    private struct LASTINPUTINFO
    {
        public uint cbSize;
        public uint dwTime;
    }

    [DllImport("user32.dll")]
    private static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);

    public static TimeSpan GetIdleTime()
    {
        LASTINPUTINFO info = new LASTINPUTINFO();
        info.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));

        if (!GetLastInputInfo(ref info))
            return TimeSpan.Zero;

        uint now = unchecked((uint)Environment.TickCount);
        uint idleMilliseconds = unchecked(now - info.dwTime);
        return TimeSpan.FromMilliseconds(idleMilliseconds);
    }
}
"@
    }

    # ----------------------------
    # Runtime state
    # ----------------------------

    $State = @{}

    foreach ($Name in $Pairs.Keys) {
        $State[$Name] = [pscustomobject]@{
            Dirty       = $false
            LastChange  = [datetime]::MinValue
            RetryAt     = $null
            RetryCount  = 0
            RetryPaused = $false
            Blocked     = $false
            BlockReason = $null
            InProgress  = $false
        }
    }

    $script:LastLoopHeartbeat = Get-Date

    function Set-LoopHeartbeat {
        $script:LastLoopHeartbeat = Get-Date
    }

    function Test-IgnoredWatcherPath {
        param(
            [AllowNull()]
            [string]$FullPath
        )

        if ([string]::IsNullOrWhiteSpace($FullPath)) {
            return $false
        }

        $Leaf = Split-Path -Path $FullPath -Leaf
        foreach ($IgnoredName in $WatcherIgnoreNames) {
            if ($Leaf.Equals($IgnoredName, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        }

        return $false
    }

    function Process-WatcherEvents {
        # Fast check: skip pipeline overhead if no events in queue
        if ($ExecutionContext.Events.ReceivedEvents.Count -eq 0) {
            return
        }

        # Drain only our FileSystemWatcher events. This is deliberately non-blocking
        # so the WinForms message pump stays responsive.
        $Events = @(
            Get-Event | Where-Object {
                $_.SourceIdentifier -like "RcloneWatch|*"
            }
        )

        foreach ($Event in $Events) {
            try {
                $Parts = $Event.SourceIdentifier -split "\|", 3

                if ($Parts.Count -ne 3 -or $Parts[0] -ne "RcloneWatch") {
                    continue
                }

                $Name = $Parts[1]
                $EventName = $Parts[2]

                if (-not $State.ContainsKey($Name)) {
                    continue
                }

                if ($EventName -eq "Error") {
                    $State[$Name].Dirty = $true
                    $State[$Name].LastChange = $Event.TimeGenerated
                    $State[$Name].RetryCount = 0
                    $State[$Name].RetryPaused = $false
                    Write-Log "[$Name] FileSystemWatcher reported an error or buffer overflow; a full bisync will be triggered after the quiet period." "WARN"
                    continue
                }

                $FullPath = $null
                if ($null -ne $Event.SourceEventArgs) {
                    $FullPath = $Event.SourceEventArgs.FullPath
                }

                if (-not (Test-IgnoredWatcherPath -FullPath $FullPath)) {
                    $State[$Name].Dirty = $true
                    $State[$Name].LastChange = $Event.TimeGenerated
                    $State[$Name].RetryCount = 0
                    $State[$Name].RetryPaused = $false
                }
            }
            finally {
                Remove-Event -EventIdentifier $Event.EventIdentifier -ErrorAction SilentlyContinue
            }
        }
    }

    function Pump-Application {
        if ($null -ne $script:TrayIcon) {
            [System.Windows.Forms.Application]::DoEvents()
        }

        Process-WatcherEvents

        $Now = Get-Date
        $LoopGapSeconds = ($Now - $script:LastLoopHeartbeat).TotalSeconds
        $script:LastLoopHeartbeat = $Now

        # When the OS suspends this process, the 75-100 ms pump interval becomes a
        # large gap. Schedule a resume sync instead of starting one recursively
        # from inside a currently running rclone operation.
        if (
            $script:ServiceReady -and
            $LoopGapSeconds -ge $ResumeGapSeconds
        ) {
            Write-Log ("Detected a {0:N0}-second watcher pause; scheduling a resume sync." -f $LoopGapSeconds)
            $script:ResumeSyncDueAt = $Now.AddSeconds($ResumeDelaySeconds)
        }

        Refresh-TrayStatus
    }

    function Wait-Responsive {
        param(
            [Parameter(Mandatory)]
            [double]$Seconds
        )

        $Until = (Get-Date).AddSeconds($Seconds)
        while ((Get-Date) -lt $Until -and -not $script:ExitRequested) {
            Pump-Application
            [System.Threading.Thread]::Sleep(120)
        }
    }

    function Start-PairSyncProcess {
        param(
            [Parameter(Mandatory)]
            [string]$Name,

            [Parameter(Mandatory)]
            [string]$Reason
        )


        if ($State[$Name].Blocked) {
            Refresh-TrayStatus
            return $null
        }

        if ($State[$Name].InProgress) {
            return $null
        }

        $Pair = $Pairs[$Name]
        $LocalPath = [string]$Pair.Local
        $RemotePath = [string]$Pair.Remote

        if (-not (Test-Path -LiteralPath $LocalPath -PathType Container)) {
            Write-Log "[$Name] Local path is unavailable: $LocalPath" "ERROR"
            $State[$Name].RetryAt = (Get-Date).AddSeconds($RetryDelaySeconds)
            $State[$Name].RetryPaused = $false
            Refresh-TrayStatus
            return $null
        }

        $CheckPath = Join-Path $LocalPath $CheckFileName
        if (-not (Test-Path -LiteralPath $CheckPath -PathType Leaf)) {
            $State[$Name].Blocked = $true
            $State[$Name].BlockReason = "local safety marker missing"
            $State[$Name].RetryAt = $null
            $State[$Name].RetryPaused = $false
            Write-Log "[$Name] Safety marker is missing: $CheckPath. Pair blocked until fixed and the watcher is restarted." "ERROR"
            Refresh-TrayStatus
            Show-TrayError -Message "$Name is blocked because its local safety marker is missing."
            return $null
        }

        # Clear the current dirty flag before starting. Events generated while
        # rclone is running are still drained by Pump-Application and deliberately
        # trigger one follow-up sync.
        $State[$Name].Dirty = $false
        $State[$Name].RetryAt = $null
        $State[$Name].RetryPaused = $false
        $State[$Name].InProgress = $true

        Write-Log "[$Name] bisync started ($Reason): $LocalPath <-> $RemotePath"

        $Arguments = @(
            "bisync"
            $LocalPath
            $RemotePath
            "--transfers", "$Transfers"
            "--checkers", "$Checkers"
            "--filters-file", $FiltersFile
            "--resilient"
            "--recover"
            "--max-lock", "5m"
            "--check-access"
            "--check-filename", $CheckFileName
            "--retries", "3"
            "--retries-sleep", "10s"
            "--log-file", (Get-LogFile)
            "--log-level", "INFO"
        )

        try {
            $StartInfo = [System.Diagnostics.ProcessStartInfo]::new()
            $StartInfo.FileName = $RcloneExe
            $StartInfo.UseShellExecute = $false
            $StartInfo.CreateNoWindow = $true

            foreach ($Argument in $Arguments) {
                [void]$StartInfo.ArgumentList.Add([string]$Argument)
            }

            $Process = [System.Diagnostics.Process]::new()
            $Process.StartInfo = $StartInfo

            if (-not $Process.Start()) {
                throw "Could not start rclone.exe"
            }

            $Job = [pscustomobject]@{
                Name    = $Name
                Reason  = $Reason
                Process = $Process
            }

            $script:ActiveSyncJobs.Add($Job)
            return $Job
        }
        catch {
            $State[$Name].InProgress = $false
            Write-Log "[$Name] rclone process launch error: $($_.Exception.Message)" "ERROR"
            $State[$Name].RetryCount++

            if ($State[$Name].RetryCount -le $MaxAutoRetries) {
                $State[$Name].RetryAt = (Get-Date).AddSeconds($RetryDelaySeconds)
                $State[$Name].RetryPaused = $false
            }
            else {
                $State[$Name].RetryPaused = $true
            }

            Refresh-TrayStatus
            return $null
        }
    }

    function Complete-PairSyncProcess {
        param(
            [Parameter(Mandatory)]
            [pscustomobject]$Job
        )

        $Name = $Job.Name
        $Reason = $Job.Reason
        $Process = $Job.Process

        try {
            $ExitCode = $Process.ExitCode
        }
        catch {
            $ExitCode = 1
        }
        finally {
            [void]$script:ActiveSyncJobs.Remove($Job)
            $Process.Dispose()
        }

        $State[$Name].InProgress = $false
        Set-LoopHeartbeat

        if ($ExitCode -eq 0) {
            $State[$Name].RetryCount = 0
            $State[$Name].RetryAt = $null
            $State[$Name].RetryPaused = $false
            Write-Log "[$Name] bisync completed successfully ($Reason)."
            Refresh-TrayStatus
            return $true
        }

        # rclone bisync exit 2 is a usage/configuration error. Exit 7 is a
        # critical abort that normally requires manual inspection/resync.
        # Do not create an endless retry loop for either case.
        if ($ExitCode -eq 2 -or $ExitCode -eq 7) {
            $State[$Name].Blocked = $true
            $State[$Name].BlockReason = "rclone exit code $ExitCode"
            $State[$Name].RetryAt = $null
            $State[$Name].RetryPaused = $false
            Write-Log "[$Name] bisync stopped with exit code $ExitCode ($Reason). Pair blocked; inspect the log and perform any required manual --resync/--force action before restarting the watcher." "ERROR"
            Refresh-TrayStatus
            Show-TrayError -Message "$Name was blocked by bisync (exit $ExitCode). Open the log for details."
            return $false
        }

        $State[$Name].RetryCount++

        if ($State[$Name].RetryCount -le $MaxAutoRetries) {
            $State[$Name].RetryAt = (Get-Date).AddSeconds($RetryDelaySeconds)
            $State[$Name].RetryPaused = $false
            Write-Log "[$Name] bisync failed with exit code $ExitCode ($Reason). Retry $($State[$Name].RetryCount)/$MaxAutoRetries scheduled in $RetryDelaySeconds seconds." "ERROR"
        }
        else {
            $State[$Name].RetryAt = $null
            $State[$Name].RetryCount = 0
            $State[$Name].RetryPaused = $true
            Write-Log "[$Name] bisync failed repeatedly. Automatic retries paused until the next local-change, idle, resume, manual, or startup trigger." "ERROR"
            Show-TrayError -Message "$Name failed repeatedly. Automatic retries are paused until the next trigger."
        }

        Refresh-TrayStatus
        return $false
    }

    function Invoke-PairSync {
        param(
            [Parameter(Mandatory)]
            [string]$Name,

            [Parameter(Mandatory)]
            [string]$Reason
        )

        $Job = Start-PairSyncProcess -Name $Name -Reason $Reason
        if ($null -eq $Job) {
            return $false
        }

        Refresh-TrayStatus

        while (-not $Job.Process.WaitForExit(120)) {
            Pump-Application
        }

        $Job.Process.WaitForExit()
        Pump-Application

        return (Complete-PairSyncProcess -Job $Job)
    }

    function Invoke-AllSync {
        param(
            [Parameter(Mandatory)]
            [string]$Reason
        )

        $Jobs = [System.Collections.Generic.List[object]]::new()

        foreach ($Name in $Pairs.Keys) {
            if ($script:ExitRequested) {
                break
            }

            $Job = Start-PairSyncProcess -Name $Name -Reason $Reason
            if ($null -ne $Job) {
                $Jobs.Add($Job)
            }
        }

        Refresh-TrayStatus

        while ($Jobs.Count -gt 0) {
            Pump-Application

            for ($i = $Jobs.Count - 1; $i -ge 0; $i--) {
                $Job = $Jobs[$i]
                if ($Job.Process.WaitForExit(0)) {
                    $Job.Process.WaitForExit()
                    Pump-Application
                    Complete-PairSyncProcess -Job $Job | Out-Null
                    $Jobs.RemoveAt($i)
                }
            }

            if ($Jobs.Count -gt 0) {
                [System.Threading.Thread]::Sleep(120)
            }
        }

        Set-LoopHeartbeat
        Refresh-TrayStatus
    }

    # ----------------------------
    # Validate configuration
    # ----------------------------

    foreach ($Name in $Pairs.Keys) {
        $LocalPath = [string]$Pairs[$Name].Local

        if (-not (Test-Path -LiteralPath $LocalPath -PathType Container)) {
            Write-Log "[$Name] Local directory does not exist: $LocalPath" "ERROR"
        }
    }

    # ----------------------------
    # FileSystemWatcher setup
    # ----------------------------

    $Watchers = @()

    foreach ($Name in $Pairs.Keys) {
        $LocalPath = [string]$Pairs[$Name].Local

        if (-not (Test-Path -LiteralPath $LocalPath -PathType Container)) {
            continue
        }

        $Watcher = [System.IO.FileSystemWatcher]::new($LocalPath)
        $Watcher.IncludeSubdirectories = $true
        $Watcher.InternalBufferSize = 65536
        $Watcher.NotifyFilter = (
            [System.IO.NotifyFilters]::FileName -bor
            [System.IO.NotifyFilters]::DirectoryName -bor
            [System.IO.NotifyFilters]::LastWrite -bor
            [System.IO.NotifyFilters]::Size
        )

        foreach ($EventName in @("Changed", "Created", "Deleted", "Renamed", "Error")) {
            $SourceId = "RcloneWatch|$Name|$EventName"

            Register-ObjectEvent `
                -InputObject $Watcher `
                -EventName $EventName `
                -SourceIdentifier $SourceId | Out-Null
        }

        $Watcher.EnableRaisingEvents = $true
        $Watchers += $Watcher
        Write-Log "[$Name] Watching $LocalPath"
    }

    # ----------------------------
    # Startup sync
    # ----------------------------

    if ($StartupDelaySeconds -gt 0) {
        Write-Log "Waiting $StartupDelaySeconds seconds before startup sync."
        Wait-Responsive -Seconds $StartupDelaySeconds
    }

    $script:ServiceReady = $true

    if (-not $script:ExitRequested) {
        Invoke-AllSync -Reason "startup"
    }

    Set-LoopHeartbeat

    $CurrentIdle = [RcloneWatcherNativeMethods]::GetIdleTime()
    if ($CurrentIdle.TotalMinutes -ge $IdleMinutes) {
        $LastIdleSyncAt = Get-Date
    }
    else {
        $LastIdleSyncAt = $null
    }

    Write-Log "Watcher ready. Local changes sync after $QuietSeconds quiet seconds; all pairs sync at $IdleMinutes minutes idle, every $IdleRepeatMinutes minutes during prolonged idle, and after sleep/resume detection."
    Refresh-TrayStatus

    # ----------------------------
    # Main loop
    # ----------------------------

    while (-not $script:ExitRequested) {
        Pump-Application

        if ($script:ExitRequested) {
            break
        }

        if ($script:ManualSyncRequested) {
            $script:ManualSyncRequested = $false
            Invoke-AllSync -Reason "manual tray"

            if ($script:ExitRequested) {
                break
            }
        }

        $Now = Get-Date

        # A resume sync is scheduled by Pump-Application when it observes a long
        # message-pump gap. The delay lets Wi-Fi/VPN/network state recover without
        # freezing the tray UI.
        if (
            $null -ne $script:ResumeSyncDueAt -and
            $Now -ge $script:ResumeSyncDueAt
        ) {
            $script:ResumeSyncDueAt = $null
            Invoke-AllSync -Reason "resume/long pause"

            $CurrentIdle = [RcloneWatcherNativeMethods]::GetIdleTime()
            if ($CurrentIdle.TotalMinutes -ge $IdleMinutes) {
                $LastIdleSyncAt = Get-Date
            }
            else {
                $LastIdleSyncAt = $null
            }

            if ($script:ExitRequested) {
                break
            }
        }

        $Now = Get-Date

        # Retry only after an actual failed sync. This is not routine polling.
        foreach ($Name in $Pairs.Keys) {
            if ($script:ExitRequested) {
                break
            }

            if ($State[$Name].Blocked) {
                continue
            }

            $RetryAt = $State[$Name].RetryAt
            if ($null -ne $RetryAt -and $Now -ge $RetryAt) {
                Invoke-PairSync -Name $Name -Reason "retry" | Out-Null
                $Now = Get-Date
            }
        }

        if ($script:ExitRequested) {
            break
        }

        # Debounced local-change sync.
        foreach ($Name in $Pairs.Keys) {
            if ($script:ExitRequested) {
                break
            }

            if ($State[$Name].Blocked) {
                continue
            }

            if (
                $State[$Name].Dirty -and
                $null -eq $State[$Name].RetryAt -and
                (($Now - $State[$Name].LastChange).TotalSeconds -ge $QuietSeconds)
            ) {
                Invoke-PairSync -Name $Name -Reason "local change" | Out-Null
                $Now = Get-Date
            }
        }

        if ($script:ExitRequested) {
            break
        }

        # Sync once when entering idle, then periodically only while still idle.
        $IdleTime = [RcloneWatcherNativeMethods]::GetIdleTime()
        $Now = Get-Date

        if ($IdleTime.TotalMinutes -ge $IdleMinutes) {
            $ShouldIdleSync = $false
            $IdleReason = "idle"

            if ($null -eq $LastIdleSyncAt) {
                $ShouldIdleSync = $true
            }
            elseif (
                $IdleRepeatMinutes -gt 0 -and
                (($Now - $LastIdleSyncAt).TotalMinutes -ge $IdleRepeatMinutes)
            ) {
                $ShouldIdleSync = $true
                $IdleReason = "prolonged idle"
            }

            if ($ShouldIdleSync) {
                Write-Log ("User idle for {0:N1} minutes; syncing all pairs." -f $IdleTime.TotalMinutes)
                Invoke-AllSync -Reason $IdleReason
                $LastIdleSyncAt = Get-Date
            }
        }
        else {
            # User activity rearms the next idle episode.
            $LastIdleSyncAt = $null
        }

        Refresh-TrayStatus

        # Keep the notification-area UI responsive without busy-spinning.
        [System.Threading.Thread]::Sleep(120)
    }

    if ($script:ExitRequested) {
        Write-Log "Exit requested from system tray."
    }
}
finally {
    Dispose-TrayIcon

    if ($null -ne $script:ActiveSyncJobs) {
        foreach ($Job in @($script:ActiveSyncJobs)) {
            try {
                if (-not $Job.Process.HasExited) {
                    $Job.Process.Kill()
                }
                $Job.Process.Dispose()
            }
            catch {
            }
        }
        $script:ActiveSyncJobs.Clear()
    }

    Get-Event | Where-Object {
        $_.SourceIdentifier -like "RcloneWatch|*"
    } | Remove-Event -ErrorAction SilentlyContinue

    Get-EventSubscriber | Where-Object {
        $_.SourceIdentifier -like "RcloneWatch|*"
    } | Unregister-Event -Force -ErrorAction SilentlyContinue

    if (Get-Variable -Name Watchers -ErrorAction SilentlyContinue) {
        foreach ($Watcher in $Watchers) {
            try {
                $Watcher.EnableRaisingEvents = $false
                $Watcher.Dispose()
            }
            catch {
            }
        }
    }

    if ($HaveMutex) {
        try {
            $Mutex.ReleaseMutex()
        }
        catch {
        }
    }

    $Mutex.Dispose()

    if ($script:RestartRequested) {
        Write-Log "Restart requested; launching new watcher instance."
        $VbsPath = Join-Path $PSScriptRoot "start-watch-sync.vbs"
        if (Test-Path -LiteralPath $VbsPath -PathType Leaf) {
            Start-Process "wscript.exe" -ArgumentList "`"$VbsPath`"" -WorkingDirectory $PSScriptRoot
        }
        else {
            $SelfScript = Join-Path $PSScriptRoot "watch-sync-tray.ps1"
            Start-Process "pwsh.exe" -ArgumentList "-NoLogo -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$SelfScript`"" -WorkingDirectory $PSScriptRoot
        }
    }
}
