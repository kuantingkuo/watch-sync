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

if ($IsWindows) {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
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
$ErrorIconPath = Join-Path $IconDir "error.ico"

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
$Checkers = 8

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

# ----------------------------
# Path normalization and sync pair helpers
# ----------------------------

function Normalize-LocalPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $Expanded = [System.Environment]::ExpandEnvironmentVariables($Path)
    try {
        $FullPath = [System.IO.Path]::GetFullPath($Expanded)
        $Root = [System.IO.Path]::GetPathRoot($FullPath)
        if ($FullPath.Length -gt $Root.Length) {
            $FullPath = $FullPath.TrimEnd('\', '/')
        }
        return $FullPath.ToLowerInvariant()
    }
    catch {
        return $Expanded.TrimEnd('\', '/').ToLowerInvariant()
    }
}

function Normalize-RemotePath {
    param(
        [Parameter(Mandatory)]
        [string]$Remote
    )

    $Trimmed = $Remote.Trim()
    $ColonIndex = $Trimmed.IndexOf(':')
    if ($ColonIndex -lt 0) {
        return $Trimmed.TrimEnd('/', '\').ToLowerInvariant()
    }

    $RemoteName = $Trimmed.Substring(0, $ColonIndex).Trim()
    $SubPath = $Trimmed.Substring($ColonIndex + 1).Trim().TrimStart('/', '\').TrimEnd('/', '\')
    $SubPath = $SubPath -replace '\\', '/'
    while ($SubPath -match '//') {
        $SubPath = $SubPath -replace '//', '/'
    }

    if ([string]::IsNullOrEmpty($SubPath)) {
        return "$($RemoteName):".ToLowerInvariant()
    }
    return "$($RemoteName):$SubPath".ToLowerInvariant()
}

function Join-RemotePath {
    param(
        [Parameter(Mandatory)]
        [string]$RemotePrefix,

        [AllowEmptyString()]
        [string]$SubPath = ""
    )

    $Prefix = $RemotePrefix.Trim()
    $ColonIndex = $Prefix.IndexOf(':')
    if ($ColonIndex -lt 0) {
        $RemoteName = $Prefix
        $RemoteSub = ""
    }
    else {
        $RemoteName = $Prefix.Substring(0, $ColonIndex).Trim()
        $RemoteSub = $Prefix.Substring($ColonIndex + 1).Trim().TrimStart('/', '\').TrimEnd('/', '\')
    }

    $Sub = if ($null -ne $SubPath) { $SubPath.Trim() } else { "" }
    $Sub = $Sub.TrimStart('/', '\').TrimEnd('/', '\') -replace '\\', '/'

    $CombinedSub = if ([string]::IsNullOrEmpty($RemoteSub)) {
        $Sub
    }
    elseif ([string]::IsNullOrEmpty($Sub)) {
        $RemoteSub
    }
    else {
        "$RemoteSub/$Sub"
    }

    while ($CombinedSub -match '//') {
        $CombinedSub = $CombinedSub -replace '//', '/'
    }

    if ([string]::IsNullOrEmpty($CombinedSub)) {
        return "$($RemoteName):"
    }
    return "$($RemoteName):$CombinedSub"
}

function Get-RemoteFilePath {
    param(
        [Parameter(Mandatory)]
        [string]$RemotePath,

        [Parameter(Mandatory)]
        [string]$FileName
    )

    return (Join-RemotePath -RemotePrefix $RemotePath -SubPath $FileName)
}

function Test-SyncPairConflict {
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$ExistingPairs,

        [Parameter(Mandatory)]
        [string]$CandidateName,

        [Parameter(Mandatory)]
        [string]$CandidateLocal,

        [Parameter(Mandatory)]
        [string]$CandidateRemote
    )

    foreach ($Name in $ExistingPairs.Keys) {
        if ($Name.Equals($CandidateName, [System.StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{
                HasConflict     = $true
                ConflictType    = "Name"
                ConflictingName = $Name
                Message         = "Pair name '$CandidateName' is already in use by pair '$Name'."
            }
        }
    }

    $NormalizedCandidateLocal = Normalize-LocalPath -Path $CandidateLocal
    foreach ($Name in $ExistingPairs.Keys) {
        $ExistingLocal = [string]$ExistingPairs[$Name].Local
        $NormalizedExisting = Normalize-LocalPath -Path $ExistingLocal
        if ($NormalizedCandidateLocal -eq $NormalizedExisting) {
            return [pscustomobject]@{
                HasConflict     = $true
                ConflictType    = "LocalPath"
                ConflictingName = $Name
                Message         = "Local folder '$CandidateLocal' is already configured by pair '$Name' ($ExistingLocal)."
            }
        }

        if ($NormalizedCandidateLocal.StartsWith($NormalizedExisting + "\", [System.StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{
                HasConflict     = $true
                ConflictType    = "LocalOverlap"
                ConflictingName = $Name
                Message         = "Local folder '$CandidateLocal' is inside existing pair '$Name' ($ExistingLocal). Nested folder synchronization is not allowed."
            }
        }

        if ($NormalizedExisting.StartsWith($NormalizedCandidateLocal + "\", [System.StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{
                HasConflict     = $true
                ConflictType    = "LocalOverlap"
                ConflictingName = $Name
                Message         = "Local folder '$CandidateLocal' contains existing pair '$Name' ($ExistingLocal). Nested folder synchronization is not allowed."
            }
        }
    }

    $NormalizedCandidateRemote = Normalize-RemotePath -Remote $CandidateRemote
    foreach ($Name in $ExistingPairs.Keys) {
        $ExistingRemote = [string]$ExistingPairs[$Name].Remote
        $NormalizedExisting = Normalize-RemotePath -Remote $ExistingRemote
        if ($NormalizedCandidateRemote -eq $NormalizedExisting) {
            return [pscustomobject]@{
                HasConflict     = $true
                ConflictType    = "RemotePath"
                ConflictingName = $Name
                Message         = "Remote path '$CandidateRemote' is already configured by pair '$Name' ($ExistingRemote)."
            }
        }

        $CandColon = $NormalizedCandidateRemote.IndexOf(':')
        $ExistColon = $NormalizedExisting.IndexOf(':')
        if ($CandColon -gt 0 -and $ExistColon -gt 0) {
            $CandRemoteName = $NormalizedCandidateRemote.Substring(0, $CandColon)
            $ExistRemoteName = $NormalizedExisting.Substring(0, $ExistColon)

            if ($CandRemoteName.Equals($ExistRemoteName, [System.StringComparison]::OrdinalIgnoreCase)) {
                $ExistPrefix = if ($NormalizedExisting.EndsWith(':')) { $NormalizedExisting } else { $NormalizedExisting + '/' }
                if ($NormalizedCandidateRemote.StartsWith($ExistPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                    return [pscustomobject]@{
                        HasConflict     = $true
                        ConflictType    = "RemoteOverlap"
                        ConflictingName = $Name
                        Message         = "Remote path '$CandidateRemote' is inside existing pair '$Name' ($ExistingRemote) on remote '$CandRemoteName'. Nested remote path synchronization is not allowed."
                    }
                }

                $CandPrefix = if ($NormalizedCandidateRemote.EndsWith(':')) { $NormalizedCandidateRemote } else { $NormalizedCandidateRemote + '/' }
                if ($NormalizedExisting.StartsWith($CandPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                    return [pscustomobject]@{
                        HasConflict     = $true
                        ConflictType    = "RemoteOverlap"
                        ConflictingName = $Name
                        Message         = "Remote path '$CandidateRemote' contains existing pair '$Name' ($ExistingRemote) on remote '$CandRemoteName'. Nested remote path synchronization is not allowed."
                    }
                }
            }
        }
    }

    return [pscustomobject]@{
        HasConflict     = $false
        ConflictType    = $null
        ConflictingName = $null
        Message         = $null
    }
}

$PairsJsonFile = Join-Path $PSScriptRoot "pairs.local.json"

function Get-TrayManagedPairs {
    param(
        [string]$Path = $PairsJsonFile
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [ordered]@{}
    }

    $RawJson = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($RawJson)) {
        return [ordered]@{}
    }

    $Parsed = ConvertFrom-Json -InputObject $RawJson -AsHashtable
    if ($null -eq $Parsed) {
        return [ordered]@{}
    }

    $Result = [ordered]@{}
    foreach ($Key in $Parsed.Keys) {
        $Val = $Parsed[$Key]
        if ($Val -is [System.Collections.IDictionary]) {
            if ($Val.Contains("Local") -and $Val.Contains("Remote")) {
                $Result[[string]$Key] = [ordered]@{
                    Local  = [string]$Val["Local"]
                    Remote = [string]$Val["Remote"]
                }
            }
        }
    }
    return $Result
}

function Save-TrayManagedPairs {
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$PairsDictionary,

        [string]$Path = $PairsJsonFile
    )

    $TempFile = "$Path.tmp.$([System.Guid]::NewGuid().ToString('N'))"
    try {
        if ($PairsDictionary.Count -eq 0) {
            $JsonContent = "{}`r`n"
        }
        else {
            $JsonContent = $PairsDictionary | ConvertTo-Json -Depth 5
        }

        [System.IO.File]::WriteAllText($TempFile, $JsonContent, [System.Text.Encoding]::UTF8)

        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            try {
                [System.IO.File]::Replace($TempFile, $Path, $null)
            }
            catch {
                Copy-Item -LiteralPath $TempFile -Destination $Path -Force
                Remove-Item -LiteralPath $TempFile -Force -ErrorAction SilentlyContinue
            }
        }
        else {
            Move-Item -LiteralPath $TempFile -Destination $Path -Force
        }
        Write-Log "Saved tray-managed pairs to $Path"
        return $true
    }
    catch {
        Write-Log "Failed to save tray-managed pairs to $($Path): $($_.Exception.Message)" "ERROR"
        if (Test-Path -LiteralPath $TempFile) {
            Remove-Item -LiteralPath $TempFile -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

$script:TrayPairsStatus = [ordered]@{}

function Merge-SyncPairs {
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$ManualPairs,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$TrayPairs
    )

    $Effective = [ordered]@{}
    $script:TrayPairsStatus = [ordered]@{}

    foreach ($Key in $ManualPairs.Keys) {
        $Pair = $ManualPairs[$Key]
        $Effective[$Key] = [ordered]@{
            Local  = [string]$Pair.Local
            Remote = [string]$Pair.Remote
            Source = "config.local.psd1"
        }
    }

    foreach ($Key in $TrayPairs.Keys) {
        $TrayPair = $TrayPairs[$Key]
        $TrayLocal = [string]$TrayPair.Local
        $ExpandedLocal = [System.Environment]::ExpandEnvironmentVariables($TrayLocal)
        $TrayRemote = [string]$TrayPair.Remote

        $Conflict = Test-SyncPairConflict -ExistingPairs $Effective -CandidateName $Key -CandidateLocal $ExpandedLocal -CandidateRemote $TrayRemote
        if ($Conflict.HasConflict) {
            Write-Log "Tray-managed pair [$Key] rejected due to conflict with [$($Conflict.ConflictingName)]: $($Conflict.Message)" "WARN"
            $script:TrayPairsStatus[$Key] = [ordered]@{
                IsActive = $false
                Local    = $ExpandedLocal
                Remote   = $TrayRemote
                Reason   = $Conflict.Message
            }
            continue
        }

        $Effective[$Key] = [ordered]@{
            Local  = $ExpandedLocal
            Remote = $TrayRemote
            Source = "Tray-managed"
        }
        $script:TrayPairsStatus[$Key] = [ordered]@{
            IsActive = $true
            Local    = $ExpandedLocal
            Remote   = $TrayRemote
            Reason   = $null
        }
        Write-Log "Loaded tray-managed pair: [$Key] $ExpandedLocal <-> $TrayRemote"
    }

    return $Effective
}

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

$ManualPairs = [ordered]@{}
foreach ($PairKey in $LocalConfig.Pairs.Keys) {
    $PairData = $LocalConfig.Pairs[$PairKey]
    if (-not $PairData.ContainsKey("Local") -or -not $PairData.ContainsKey("Remote")) {
        Show-FatalStartupError "配對 [$PairKey] 設定不完整：必須包含 Local 與 Remote。"
        exit 1
    }

    $RawLocal = [string]$PairData.Local
    $RawRemote = [string]$PairData.Remote
    $ExpandedLocal = [System.Environment]::ExpandEnvironmentVariables($RawLocal)

    $ManualPairs[$PairKey] = [ordered]@{
        Local  = $ExpandedLocal
        Remote = $RawRemote
        Source = "config.local.psd1"
    }
}

# Load tray-managed pairs from pairs.local.json if it exists
$TrayPairs = [ordered]@{}
if (Test-Path -LiteralPath $PairsJsonFile -PathType Leaf) {
    try {
        $TrayPairs = Get-TrayManagedPairs -Path $PairsJsonFile
    }
    catch {
        Write-Log "Failed to parse pairs.local.json: $($_.Exception.Message)" "ERROR"
        if ($IsWindows) {
            try {
                Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
                [System.Windows.Forms.MessageBox]::Show(
                    "無法讀取系統匣配對設定檔 (pairs.local.json)：`n$($_.Exception.Message)`n`n已跳過載入 pairs.local.json。既有的手動設定 (config.local.psd1) 仍會正常運作。",
                    "Watch-Sync 設定檔警告",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Warning
                ) | Out-Null
            }
            catch {}
        }
    }
}

$Pairs = Merge-SyncPairs -ManualPairs $ManualPairs -TrayPairs $TrayPairs

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
$script:ErrorIcon = $null
$script:ManualSyncRequested = $false
$script:AddPairRequested = $false
$script:ManagePairsRequested = $false
$script:AddDialogOutput = $null
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

    $AddItem = [System.Windows.Forms.ToolStripMenuItem]::new("Add sync folder...")
    $AddItem.add_Click({
            $script:AddPairRequested = $true
        })
    [void]$Menu.Items.Add($AddItem)

    $ManageItem = [System.Windows.Forms.ToolStripMenuItem]::new("Manage sync folders...")
    $ManageItem.add_Click({
            $script:ManagePairsRequested = $true
        })
    [void]$Menu.Items.Add($ManageItem)

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
    $script:ErrorIcon = $null
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

    function Get-CommonBisyncArguments {
        return @(
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
        )
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
        ) + (Get-CommonBisyncArguments) + @(
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
    # Tray sync pair management workflows
    # ----------------------------

    function Get-RcloneRemotes {
        try {
            $StartInfo = [System.Diagnostics.ProcessStartInfo]::new()
            $StartInfo.FileName = $RcloneExe
            $StartInfo.Arguments = "listremotes"
            $StartInfo.RedirectStandardOutput = $true
            $StartInfo.RedirectStandardError = $true
            $StartInfo.UseShellExecute = $false
            $StartInfo.CreateNoWindow = $true

            $Process = [System.Diagnostics.Process]::Start($StartInfo)
            $Stdout = $Process.StandardOutput.ReadToEnd()
            $Stderr = $Process.StandardError.ReadToEnd()
            $Process.WaitForExit()

            if ($Process.ExitCode -ne 0) {
                Write-Log "rclone listremotes failed (exit $($Process.ExitCode)): $Stderr" "ERROR"
                return @()
            }

            $Remotes = @($Stdout -split "[\r\n]+" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            return $Remotes
        }
        catch {
            Write-Log "Failed to query rclone remotes: $($_.Exception.Message)" "ERROR"
            return @()
        }
    }

    function Invoke-RcloneTouch {
        param(
            [Parameter(Mandatory)]
            [string]$Path
        )

        $StartInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $StartInfo.FileName = $RcloneExe
        $StartInfo.ArgumentList.Add("touch")
        $StartInfo.ArgumentList.Add($Path)
        $StartInfo.RedirectStandardOutput = $true
        $StartInfo.RedirectStandardError = $true
        $StartInfo.UseShellExecute = $false
        $StartInfo.CreateNoWindow = $true

        $Process = $null
        try {
            $Process = [System.Diagnostics.Process]::Start($StartInfo)
            if ($null -eq $Process) {
                return [pscustomobject]@{
                    ExitCode = -1
                    Output   = "Failed to start rclone process."
                }
            }

            $StdoutTask = $Process.StandardOutput.ReadToEndAsync()
            $StderrTask = $Process.StandardError.ReadToEndAsync()

            while (-not $Process.WaitForExit(100)) {
                Pump-Application
            }
            $Process.WaitForExit()

            $Stdout = $StdoutTask.GetAwaiter().GetResult()
            $Stderr = $StderrTask.GetAwaiter().GetResult()

            $Combined = if ([string]::IsNullOrWhiteSpace($Stderr)) {
                $Stdout
            }
            elseif ([string]::IsNullOrWhiteSpace($Stdout)) {
                $Stderr
            }
            else {
                "$Stderr`n$Stdout"
            }

            $ExitCode = $Process.ExitCode
            return [pscustomobject]@{
                ExitCode = $ExitCode
                Output   = if ($null -ne $Combined) { $Combined.Trim() } else { "" }
            }
        }
        catch {
            return [pscustomobject]@{
                ExitCode = -1
                Output   = $_.Exception.Message
            }
        }
        finally {
            if ($null -ne $Process) {
                $Process.Dispose()
            }
        }
    }

    function Invoke-BisyncInit {
        param(
            [Parameter(Mandatory)]
            [string]$LocalPath,

            [Parameter(Mandatory)]
            [string]$RemotePath,

            [Parameter(Mandatory)]
            [string]$ResyncMode,

            [switch]$DryRun
        )

        $InitLogFile = Join-Path $LogDir ("init-{0:yyyyMMdd-HHmmss}-{1}.log" -f (Get-Date), [System.Guid]::NewGuid().ToString("N").Substring(0, 8))

        $Arguments = @(
            "bisync",
            $LocalPath,
            $RemotePath,
            "--resync",
            "--resync-mode", $ResyncMode
        )

        if ($DryRun) {
            $Arguments += "--dry-run"
        }

        $Arguments += (Get-CommonBisyncArguments)
        $Arguments += @(
            "--log-file", $InitLogFile,
            "--log-level", "INFO"
        )

        $StartInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $StartInfo.FileName = $RcloneExe
        $StartInfo.UseShellExecute = $false
        $StartInfo.CreateNoWindow = $true
        foreach ($Arg in $Arguments) {
            [void]$StartInfo.ArgumentList.Add([string]$Arg)
        }

        $Process = [System.Diagnostics.Process]::new()
        $Process.StartInfo = $StartInfo

        try {
            if (-not $Process.Start()) {
                throw "Could not start rclone.exe"
            }

            while (-not $Process.WaitForExit(120)) {
                Pump-Application
            }
            $Process.WaitForExit()
            Pump-Application

            $ExitCode = $Process.ExitCode
            $LogContent = ""
            if (Test-Path -LiteralPath $InitLogFile -PathType Leaf) {
                $LogContent = [System.IO.File]::ReadAllText($InitLogFile, [System.Text.Encoding]::UTF8)
                if (-not [string]::IsNullOrWhiteSpace($LogContent)) {
                    Add-Content -LiteralPath (Get-LogFile) -Value $LogContent -Encoding UTF8
                }
                Remove-Item -LiteralPath $InitLogFile -Force -ErrorAction SilentlyContinue
            }

            return [pscustomobject]@{
                Success  = ($ExitCode -eq 0)
                ExitCode = $ExitCode
                Output   = $LogContent
            }
        }
        catch {
            Write-Log "Error running initial bisync: $($_.Exception.Message)" "ERROR"
            return [pscustomobject]@{
                Success  = $false
                ExitCode = -1
                Output   = $_.Exception.Message
            }
        }
        finally {
            $Process.Dispose()
        }
    }

    function Show-AddPairDialog {
        param(
            [Parameter(Mandatory)]
            [string]$LocalPath,

            [Parameter(Mandatory)]
            [string[]]$Remotes,

            [Parameter(Mandatory)]
            [System.Collections.IDictionary]$ExistingPairs
        )

        $DefaultPairName = Split-Path -Path $LocalPath -Leaf
        if ([string]::IsNullOrWhiteSpace($DefaultPairName)) {
            $DefaultPairName = $LocalPath -replace '[:\/\\]', ''
        }

        $Font = [System.Drawing.Font]::new("Segoe UI", 9)
        $Form = [System.Windows.Forms.Form]::new()
        $Form.Font = $Font
        $Form.Text = "Add Sync Folder - Watch-Sync"
        $Form.ClientSize = [System.Drawing.Size]::new(540, 395)
        $Form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
        $Form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
        $Form.MaximizeBox = $false
        $Form.MinimizeBox = $false
        $Form.TopMost = $true

        # Pair Name
        $LblPairName = [System.Windows.Forms.Label]::new()
        $LblPairName.Text = "Pair name:"
        $LblPairName.Location = [System.Drawing.Point]::new(20, 18)
        $LblPairName.AutoSize = $true
        $Form.Controls.Add($LblPairName)

        $TxtPairName = [System.Windows.Forms.TextBox]::new()
        $TxtPairName.Location = [System.Drawing.Point]::new(20, 38)
        $TxtPairName.Size = [System.Drawing.Size]::new(500, 24)
        $TxtPairName.Text = $DefaultPairName
        $Form.Controls.Add($TxtPairName)

        # Local Path
        $LblLocal = [System.Windows.Forms.Label]::new()
        $LblLocal.Text = "Local folder (Path1):"
        $LblLocal.Location = [System.Drawing.Point]::new(20, 72)
        $LblLocal.AutoSize = $true
        $Form.Controls.Add($LblLocal)

        $TxtLocal = [System.Windows.Forms.TextBox]::new()
        $TxtLocal.Location = [System.Drawing.Point]::new(20, 92)
        $TxtLocal.Size = [System.Drawing.Size]::new(500, 24)
        $TxtLocal.Text = $LocalPath
        $TxtLocal.ReadOnly = $true
        $TxtLocal.BackColor = [System.Drawing.SystemColors]::Control
        $Form.Controls.Add($TxtLocal)

        # Remote
        $LblRemote = [System.Windows.Forms.Label]::new()
        $LblRemote.Text = "Remote (Path2):"
        $LblRemote.Location = [System.Drawing.Point]::new(20, 126)
        $LblRemote.AutoSize = $true
        $Form.Controls.Add($LblRemote)

        $CboRemote = [System.Windows.Forms.ComboBox]::new()
        $CboRemote.Location = [System.Drawing.Point]::new(20, 146)
        $CboRemote.Size = [System.Drawing.Size]::new(180, 24)
        $CboRemote.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
        foreach ($r in $Remotes) {
            [void]$CboRemote.Items.Add($r)
        }
        if ($CboRemote.Items.Count -gt 0) {
            $CboRemote.SelectedIndex = 0
        }
        $Form.Controls.Add($CboRemote)

        $TxtRemoteSubDir = [System.Windows.Forms.TextBox]::new()
        $TxtRemoteSubDir.Location = [System.Drawing.Point]::new(210, 146)
        $TxtRemoteSubDir.Size = [System.Drawing.Size]::new(310, 24)
        $TxtRemoteSubDir.Text = $DefaultPairName
        $Form.Controls.Add($TxtRemoteSubDir)

        # Initial bisync direction
        $GrpInitial = [System.Windows.Forms.GroupBox]::new()
        $GrpInitial.Location = [System.Drawing.Point]::new(20, 185)
        $GrpInitial.Size = [System.Drawing.Size]::new(500, 135)
        $GrpInitial.Text = "Initial synchronization"

        $RdoPath1 = [System.Windows.Forms.RadioButton]::new()
        $RdoPath1.Location = [System.Drawing.Point]::new(15, 25)
        $RdoPath1.Size = [System.Drawing.Size]::new(460, 25)
        $RdoPath1.Text = "Local version wins (Path1 -> Path2, --resync-mode path1)"
        $RdoPath1.Checked = $true
        $GrpInitial.Controls.Add($RdoPath1)

        $RdoPath2 = [System.Windows.Forms.RadioButton]::new()
        $RdoPath2.Location = [System.Drawing.Point]::new(15, 58)
        $RdoPath2.Size = [System.Drawing.Size]::new(460, 25)
        $RdoPath2.Text = "Remote version wins (Path2 -> Path1, --resync-mode path2)"
        $GrpInitial.Controls.Add($RdoPath2)

        $RdoNewer = [System.Windows.Forms.RadioButton]::new()
        $RdoNewer.Location = [System.Drawing.Point]::new(15, 91)
        $RdoNewer.Size = [System.Drawing.Size]::new(460, 25)
        $RdoNewer.Text = "Newer version wins (--resync-mode newer)"
        $GrpInitial.Controls.Add($RdoNewer)

        $Form.Controls.Add($GrpInitial)

        # Buttons
        $BtnContinue = [System.Windows.Forms.Button]::new()
        $BtnContinue.Location = [System.Drawing.Point]::new(300, 340)
        $BtnContinue.Size = [System.Drawing.Size]::new(105, 32)
        $BtnContinue.Text = "Continue"
        $Form.Controls.Add($BtnContinue)

        $BtnCancel = [System.Windows.Forms.Button]::new()
        $BtnCancel.Location = [System.Drawing.Point]::new(415, 340)
        $BtnCancel.Size = [System.Drawing.Size]::new(105, 32)
        $BtnCancel.Text = "Cancel"
        $BtnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $Form.Controls.Add($BtnCancel)

        $Form.AcceptButton = $BtnContinue
        $Form.CancelButton = $BtnCancel

        $script:AddDialogOutput = $null

        $BtnContinue.add_Click({
                $EnteredName = $TxtPairName.Text.Trim()
                if ([string]::IsNullOrWhiteSpace($EnteredName)) {
                    [System.Windows.Forms.MessageBox]::Show(
                        "Pair name cannot be empty.",
                        "Watch-Sync",
                        [System.Windows.Forms.MessageBoxButtons]::OK,
                        [System.Windows.Forms.MessageBoxIcon]::Warning
                    ) | Out-Null
                    $TxtPairName.Focus()
                    return
                }

                if ($EnteredName -match '[\r\n\t\|\\\/:\*\?"<>@\$]') {
                    [System.Windows.Forms.MessageBox]::Show(
                        "Pair name contains invalid characters. Please use letters, numbers, spaces, dots, underscores, or dashes.",
                        "Watch-Sync",
                        [System.Windows.Forms.MessageBoxButtons]::OK,
                        [System.Windows.Forms.MessageBoxIcon]::Warning
                    ) | Out-Null
                    $TxtPairName.Focus()
                    return
                }

                $SelectedRemotePrefix = [string]$CboRemote.SelectedItem
                if ([string]::IsNullOrWhiteSpace($SelectedRemotePrefix)) {
                    [System.Windows.Forms.MessageBox]::Show(
                        "Please select an rclone remote.",
                        "Watch-Sync",
                        [System.Windows.Forms.MessageBoxButtons]::OK,
                        [System.Windows.Forms.MessageBoxIcon]::Warning
                    ) | Out-Null
                    $CboRemote.Focus()
                    return
                }

                $RemoteSub = $TxtRemoteSubDir.Text.Trim().TrimStart('/', '\').TrimEnd('/', '\')
                if ([string]::IsNullOrWhiteSpace($RemoteSub)) {
                    [System.Windows.Forms.MessageBox]::Show(
                        "Please specify a folder inside the selected remote.",
                        "Watch-Sync",
                        [System.Windows.Forms.MessageBoxButtons]::OK,
                        [System.Windows.Forms.MessageBoxIcon]::Warning
                    ) | Out-Null
                    $TxtRemoteSubDir.Focus()
                    return
                }

                $ConstructedRemote = Join-RemotePath -RemotePrefix $SelectedRemotePrefix -SubPath $RemoteSub

                $Conflict = Test-SyncPairConflict `
                    -ExistingPairs $ExistingPairs `
                    -CandidateName $EnteredName `
                    -CandidateLocal $LocalPath `
                    -CandidateRemote $ConstructedRemote

                if ($Conflict.HasConflict) {
                    [System.Windows.Forms.MessageBox]::Show(
                        $Conflict.Message,
                        "Conflict Detected - Watch-Sync",
                        [System.Windows.Forms.MessageBoxButtons]::OK,
                        [System.Windows.Forms.MessageBoxIcon]::Warning
                    ) | Out-Null
                    return
                }

                $SelectedResyncMode = "path1"
                $SelectedPrefLabel = "Local version wins"
                if ($RdoPath2.Checked) {
                    $SelectedResyncMode = "path2"
                    $SelectedPrefLabel = "Remote version wins"
                }
                elseif ($RdoNewer.Checked) {
                    $SelectedResyncMode = "newer"
                    $SelectedPrefLabel = "Newer version wins"
                }

                $script:AddDialogOutput = [pscustomobject]@{
                    PairName        = $EnteredName
                    LocalPath       = $LocalPath
                    RemotePath      = $ConstructedRemote
                    ResyncMode      = $SelectedResyncMode
                    PreferenceLabel = $SelectedPrefLabel
                }

                $Form.DialogResult = [System.Windows.Forms.DialogResult]::OK
                $Form.Close()
            })

        $ShowResult = $Form.ShowDialog()
        $Form.Dispose()

        if ($ShowResult -eq [System.Windows.Forms.DialogResult]::OK) {
            return $script:AddDialogOutput
        }
        return $null
    }

    function Show-InitConfirmDialog {
        param(
            [Parameter(Mandatory)]
            [string]$LocalPath,

            [Parameter(Mandatory)]
            [string]$RemotePath,

            [Parameter(Mandatory)]
            [string]$PreferenceLabel
        )

        $Font = [System.Drawing.Font]::new("Segoe UI", 9)
        $Form = [System.Windows.Forms.Form]::new()
        $Form.Font = $Font
        $Form.Text = "Confirm Initial Synchronization - Watch-Sync"
        $Form.ClientSize = [System.Drawing.Size]::new(520, 230)
        $Form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
        $Form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
        $Form.MaximizeBox = $false
        $Form.MinimizeBox = $false
        $Form.TopMost = $true

        $LblHeader = [System.Windows.Forms.Label]::new()
        $LblHeader.Text = "Initial synchronization check completed successfully."
        $LblHeader.Font = [System.Drawing.Font]::new("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
        $LblHeader.Location = [System.Drawing.Point]::new(20, 18)
        $LblHeader.Size = [System.Drawing.Size]::new(480, 24)
        $Form.Controls.Add($LblHeader)

        $TxtDetails = [System.Windows.Forms.TextBox]::new()
        $TxtDetails.Multiline = $true
        $TxtDetails.ReadOnly = $true
        $TxtDetails.Location = [System.Drawing.Point]::new(20, 48)
        $TxtDetails.Size = [System.Drawing.Size]::new(480, 105)
        $TxtDetails.Text = "Local:`t$LocalPath`r`nRemote:`t$RemotePath`r`nInitial conflict preference:`t$PreferenceLabel`r`n`r`nThe next step will initialize rclone bisync for this pair."
        $TxtDetails.BackColor = [System.Drawing.SystemColors]::Control
        $Form.Controls.Add($TxtDetails)

        $BtnStart = [System.Windows.Forms.Button]::new()
        $BtnStart.Location = [System.Drawing.Point]::new(225, 175)
        $BtnStart.Size = [System.Drawing.Size]::new(170, 32)
        $BtnStart.Text = "Start synchronization"
        $BtnStart.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $Form.Controls.Add($BtnStart)

        $BtnCancel = [System.Windows.Forms.Button]::new()
        $BtnCancel.Location = [System.Drawing.Point]::new(405, 175)
        $BtnCancel.Size = [System.Drawing.Size]::new(95, 32)
        $BtnCancel.Text = "Cancel"
        $BtnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $Form.Controls.Add($BtnCancel)

        $Form.AcceptButton = $BtnStart
        $Form.CancelButton = $BtnCancel

        $Result = $Form.ShowDialog()
        $Form.Dispose()
        return ($Result -eq [System.Windows.Forms.DialogResult]::OK)
    }

    function Invoke-AddSyncPairFlow {
        Write-Log "Add-pair requested from system tray."

        $Remotes = Get-RcloneRemotes
        if ($Remotes.Count -eq 0) {
            Write-Log "No rclone remotes found or listremotes failed." "ERROR"
            [System.Windows.Forms.MessageBox]::Show(
                "No configured rclone remotes found (or 'rclone listremotes' failed).`n`nPlease configure at least one remote using 'rclone config' in terminal first.",
                "Watch-Sync",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
            return
        }

        # Step 1: Select local folder
        $FolderDialog = [System.Windows.Forms.FolderBrowserDialog]::new()
        $FolderDialog.Description = "Select a local folder to synchronize with Watch-Sync"
        $FolderDialog.UseDescriptionForTitle = $true
        $FolderDialog.ShowNewFolderButton = $true

        $DialogResult = $FolderDialog.ShowDialog()
        $SelectedFolder = $FolderDialog.SelectedPath
        $FolderDialog.Dispose()

        if ($DialogResult -ne [System.Windows.Forms.DialogResult]::OK -or [string]::IsNullOrWhiteSpace($SelectedFolder)) {
            Write-Log "Add-pair canceled: folder selection canceled."
            return
        }

        if (-not (Test-Path -LiteralPath $SelectedFolder -PathType Container)) {
            Write-Log "Selected path is not a valid directory: $SelectedFolder" "ERROR"
            [System.Windows.Forms.MessageBox]::Show(
                "The selected path is not a valid directory:`n$SelectedFolder",
                "Watch-Sync",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
            return
        }

        Write-Log "Selected local directory: $SelectedFolder"

        # Check local folder conflicts and nesting early
        $NormLocal = Normalize-LocalPath -Path $SelectedFolder
        foreach ($Name in $Pairs.Keys) {
            $ExistNorm = Normalize-LocalPath -Path $Pairs[$Name].Local
            if ($NormLocal -eq $ExistNorm) {
                Write-Log "Selected directory is already configured in pair [$Name]: $SelectedFolder" "WARN"
                [System.Windows.Forms.MessageBox]::Show(
                    "The selected folder is already synchronized by pair '$Name':`n$SelectedFolder",
                    "Watch-Sync",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Warning
                ) | Out-Null
                return
            }

            if ($NormLocal.StartsWith($ExistNorm + "\", [System.StringComparison]::OrdinalIgnoreCase)) {
                Write-Log "Selected directory is inside pair [$Name]: $SelectedFolder" "WARN"
                [System.Windows.Forms.MessageBox]::Show(
                    "The selected folder is inside existing pair '$Name' ($($Pairs[$Name].Local)):`n$SelectedFolder`n`nParent-child nested folder synchronization is not allowed.",
                    "Watch-Sync",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Warning
                ) | Out-Null
                return
            }

            if ($ExistNorm.StartsWith($NormLocal + "\", [System.StringComparison]::OrdinalIgnoreCase)) {
                Write-Log "Selected directory contains pair [$Name]: $SelectedFolder" "WARN"
                [System.Windows.Forms.MessageBox]::Show(
                    "The selected folder contains existing pair '$Name' ($($Pairs[$Name].Local)):`n$SelectedFolder`n`nParent-child nested folder synchronization is not allowed.",
                    "Watch-Sync",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Warning
                ) | Out-Null
                return
            }
        }

        # Step 2: Configure pair
        $PairConfig = Show-AddPairDialog `
            -LocalPath $SelectedFolder `
            -Remotes $Remotes `
            -ExistingPairs $Pairs

        if ($null -eq $PairConfig) {
            Write-Log "Add-pair canceled: pair configuration dialog canceled."
            return
        }

        $PairName = $PairConfig.PairName
        $LocalPath = $PairConfig.LocalPath
        $RemotePath = $PairConfig.RemotePath
        $ResyncMode = $PairConfig.ResyncMode
        $PreferenceLabel = $PairConfig.PreferenceLabel

        Write-Log "Selected remote path: $RemotePath"
        Write-Log "Configuring pair [$PairName]: Local=$LocalPath, Remote=$RemotePath, Mode=$ResyncMode ($PreferenceLabel)"

        # Safety markers verification and creation
        $LocalMarker = Join-Path $LocalPath $CheckFileName
        try {
            if (-not (Test-Path -LiteralPath $LocalMarker -PathType Leaf)) {
                New-Item -ItemType File -Path $LocalMarker -Force | Out-Null
                Write-Log "Created local safety marker: $LocalMarker"
            }
        }
        catch {
            Write-Log "Failed to create local safety marker: $($_.Exception.Message)" "ERROR"
            [System.Windows.Forms.MessageBox]::Show(
                "Failed to create local safety marker file:`n$LocalMarker`n`nError: $($_.Exception.Message)",
                "Watch-Sync",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
            return
        }

        $RemoteMarker = Get-RemoteFilePath -RemotePath $RemotePath -FileName $CheckFileName
        Write-Log "Ensuring remote safety marker exists: $RemoteMarker"
        $TouchResult = Invoke-RcloneTouch -Path $RemoteMarker
        if ($TouchResult.ExitCode -ne 0) {
            Write-Log "Failed to create remote safety marker ($RemoteMarker): $($TouchResult.Output)" "ERROR"
            $ErrorHeading = if ($TouchResult.ExitCode -eq -1) { "Execution error:" } else { "rclone error (exit code $($TouchResult.ExitCode)):" }
            [System.Windows.Forms.MessageBox]::Show(
                "Failed to create remote safety marker:`n$RemoteMarker`n`n$ErrorHeading`n$($TouchResult.Output)",
                "Watch-Sync",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
            return
        }

        # Phase 1: Dry run
        Write-Log "[$PairName] Initial bisync dry run started: $LocalPath <-> $RemotePath (--resync-mode $ResyncMode)"
        Set-TrayStatus -Status "Dry run $PairName" -State "Syncing"

        $DryRunResult = Invoke-BisyncInit `
            -LocalPath $LocalPath `
            -RemotePath $RemotePath `
            -ResyncMode $ResyncMode `
            -DryRun

        Refresh-TrayStatus

        if (-not $DryRunResult.Success) {
            Write-Log "[$PairName] Initial bisync dry run failed (exit code $($DryRunResult.ExitCode))." "ERROR"
            $Details = if (-not [string]::IsNullOrWhiteSpace($DryRunResult.Output)) {
                $DryRunResult.Output.Trim()
            }
            else {
                "Unknown rclone error. Check logs for details."
            }

            [System.Windows.Forms.MessageBox]::Show(
                "Initial synchronization dry run failed (exit code $($DryRunResult.ExitCode)).`n`nDetails:`n$Details`n`nThe pair will not be added to configuration.",
                "Watch-Sync - Dry Run Failed",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
            return
        }

        Write-Log "[$PairName] Initial bisync dry run succeeded."

        # Confirmation before real initialization
        $Confirmed = Show-InitConfirmDialog `
            -LocalPath $LocalPath `
            -RemotePath $RemotePath `
            -PreferenceLabel $PreferenceLabel

        if (-not $Confirmed) {
            Write-Log "[$PairName] Initial synchronization canceled by user after dry run."
            return
        }

        # Phase 2: Real initial bisync
        Write-Log "[$PairName] Initial bisync started: $LocalPath <-> $RemotePath (--resync-mode $ResyncMode)"
        Set-TrayStatus -Status "Initializing $PairName" -State "Syncing"

        $InitResult = Invoke-BisyncInit `
            -LocalPath $LocalPath `
            -RemotePath $RemotePath `
            -ResyncMode $ResyncMode

        Refresh-TrayStatus

        if (-not $InitResult.Success) {
            Write-Log "[$PairName] Initial bisync failed (exit code $($InitResult.ExitCode))." "ERROR"
            $Details = if (-not [string]::IsNullOrWhiteSpace($InitResult.Output)) {
                $InitResult.Output.Trim()
            }
            else {
                "Unknown rclone error. Check logs for details."
            }

            [System.Windows.Forms.MessageBox]::Show(
                "Initial synchronization failed (exit code $($InitResult.ExitCode)).`n`nDetails:`n$Details`n`nThe pair was not saved. Please inspect the log file for more information.",
                "Watch-Sync - Initialization Failed",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
            return
        }

        Write-Log "[$PairName] Initial bisync succeeded."

        # Save to pairs.local.json
        try {
            $CurrentTrayPairs = Get-TrayManagedPairs
            $CurrentTrayPairs[$PairName] = [ordered]@{
                Local  = $LocalPath
                Remote = $RemotePath
            }
            Save-TrayManagedPairs -PairsDictionary $CurrentTrayPairs
            Write-Log "[$PairName] Pair saved to pairs.local.json."
        }
        catch {
            Write-Log "[$PairName] Failed to save pair to pairs.local.json: $($_.Exception.Message)" "ERROR"
            [System.Windows.Forms.MessageBox]::Show(
                "Initial synchronization succeeded, but saving to pairs.local.json failed:`n$($_.Exception.Message)",
                "Watch-Sync - Save Error",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
            return
        }

        [System.Windows.Forms.MessageBox]::Show(
            "Sync pair '$PairName' has been added successfully!`n`nWatch-Sync will now restart to begin monitoring this folder.",
            "Watch-Sync",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null

        Write-Log "Restart requested after adding pair '$PairName'."
        $script:RestartRequested = $true
        $script:ExitRequested = $true
        Refresh-TrayStatus
    }

    function Show-ManagePairsDialog {
        $Font = [System.Drawing.Font]::new("Segoe UI", 9)
        $Form = [System.Windows.Forms.Form]::new()
        $Form.Font = $Font
        $Form.Text = "Manage Sync Folders - Watch-Sync"
        $Form.ClientSize = [System.Drawing.Size]::new(725, 405)
        $Form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
        $Form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
        $Form.MaximizeBox = $false
        $Form.MinimizeBox = $false
        $Form.TopMost = $true

        $ListView = [System.Windows.Forms.ListView]::new()
        $ListView.Location = [System.Drawing.Point]::new(20, 20)
        $ListView.Size = [System.Drawing.Size]::new(685, 270)
        $ListView.View = [System.Windows.Forms.View]::Details
        $ListView.FullRowSelect = $true
        $ListView.MultiSelect = $false
        $ListView.GridLines = $true
        $ListView.HideSelection = $false
        $ListView.Columns.Add("Pair name", 130) | Out-Null
        $ListView.Columns.Add("Local path", 230) | Out-Null
        $ListView.Columns.Add("Remote path", 165) | Out-Null
        $ListView.Columns.Add("Source", 160) | Out-Null

        foreach ($Name in $Pairs.Keys) {
            $Pair = $Pairs[$Name]
            $Item = [System.Windows.Forms.ListViewItem]::new($Name)
            $Item.SubItems.Add([string]$Pair.Local) | Out-Null
            $Item.SubItems.Add([string]$Pair.Remote) | Out-Null
            $SourceStr = if ($Pair.Contains("Source")) { [string]$Pair.Source } else { "config.local.psd1" }
            $Item.SubItems.Add($SourceStr) | Out-Null
            $Item.Tag = $SourceStr
            [void]$ListView.Items.Add($Item)
        }

        # Also display any tray-managed pairs from pairs.local.json that had conflicts and were disabled
        if ($null -ne $script:TrayPairsStatus) {
            foreach ($Key in $script:TrayPairsStatus.Keys) {
                $TStatus = $script:TrayPairsStatus[$Key]
                if (-not $TStatus.IsActive) {
                    $Item = [System.Windows.Forms.ListViewItem]::new($Key)
                    $Item.SubItems.Add([string]$TStatus.Local) | Out-Null
                    $Item.SubItems.Add([string]$TStatus.Remote) | Out-Null
                    $Item.SubItems.Add("Conflict / disabled") | Out-Null
                    $Item.Tag = "Tray-managed"
                    $Item.ForeColor = [System.Drawing.Color]::Firebrick
                    [void]$ListView.Items.Add($Item)
                }
            }
        }

        $Form.Controls.Add($ListView)

        $LblHint = [System.Windows.Forms.Label]::new()
        $LblHint.Location = [System.Drawing.Point]::new(20, 305)
        $LblHint.Size = [System.Drawing.Size]::new(685, 40)
        $LblHint.Text = "Pairs configured in config.local.psd1 are read-only here.`r`nRemoving a tray-managed pair stops synchronization without deleting any local or remote files."
        $LblHint.ForeColor = [System.Drawing.Color]::DimGray
        $Form.Controls.Add($LblHint)

        $BtnRemove = [System.Windows.Forms.Button]::new()
        $BtnRemove.Location = [System.Drawing.Point]::new(330, 355)
        $BtnRemove.Size = [System.Drawing.Size]::new(210, 32)
        $BtnRemove.Text = "Remove from Watch-Sync"
        $BtnRemove.Enabled = $false
        $Form.Controls.Add($BtnRemove)

        $BtnClose = [System.Windows.Forms.Button]::new()
        $BtnClose.Location = [System.Drawing.Point]::new(555, 355)
        $BtnClose.Size = [System.Drawing.Size]::new(150, 32)
        $BtnClose.Text = "Close"
        $BtnClose.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $Form.Controls.Add($BtnClose)

        $Form.CancelButton = $BtnClose

        $ListView.add_SelectedIndexChanged({
            if ($ListView.SelectedItems.Count -gt 0) {
                $Selected = $ListView.SelectedItems[0]
                $BtnRemove.Enabled = ($Selected.Tag -eq "Tray-managed")
                if ($Selected.SubItems[3].Text -eq "Conflict / disabled") {
                    $PairName = $Selected.Text
                    if ($null -ne $script:TrayPairsStatus -and $script:TrayPairsStatus.Contains($PairName)) {
                        $LblHint.Text = "Conflict: " + $script:TrayPairsStatus[$PairName].Reason
                        $LblHint.ForeColor = [System.Drawing.Color]::Firebrick
                    }
                }
                else {
                    $LblHint.Text = "Pairs configured in config.local.psd1 are read-only here.`r`nRemoving a tray-managed pair stops synchronization without deleting any local or remote files."
                    $LblHint.ForeColor = [System.Drawing.Color]::DimGray
                }
            }
            else {
                $BtnRemove.Enabled = $false
                $LblHint.Text = "Pairs configured in config.local.psd1 are read-only here.`r`nRemoving a tray-managed pair stops synchronization without deleting any local or remote files."
                $LblHint.ForeColor = [System.Drawing.Color]::DimGray
            }
        })

        $BtnRemove.add_Click({
            if ($ListView.SelectedItems.Count -eq 0) { return }
            $Selected = $ListView.SelectedItems[0]
            if ($Selected.Tag -ne "Tray-managed") { return }

            $PairName = $Selected.Text
            $LocalPath = $Selected.SubItems[1].Text
            $RemotePath = $Selected.SubItems[2].Text
            $IsConflicting = ($Selected.SubItems[3].Text -eq "Conflict / disabled")

            if ($IsConflicting) {
                $ConfirmMsg = "Remove conflicting pair `"$PairName`" from Watch-Sync settings?`n`n" +
                              "No files will be deleted from:`n  $LocalPath`nor`n  $RemotePath"
            }
            else {
                $ConfirmMsg = "Remove `"$PairName`" from Watch-Sync?`n`n" +
                              "This stops Watch-Sync from synchronizing this pair.`n" +
                              "No files will be deleted from:`n  $LocalPath`nor`n  $RemotePath"
            }

            $Confirm = [System.Windows.Forms.MessageBox]::Show(
                $ConfirmMsg,
                "Remove Sync Pair - Watch-Sync",
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )

                if ($Confirm -eq [System.Windows.Forms.DialogResult]::Yes) {
                    try {
                        $CurrentTrayPairs = Get-TrayManagedPairs
                        if ($CurrentTrayPairs.Contains($PairName)) {
                            $CurrentTrayPairs.Remove($PairName)
                        }
                        Save-TrayManagedPairs -PairsDictionary $CurrentTrayPairs
                        Write-Log "[$PairName] Pair removed from pairs.local.json."

                        [System.Windows.Forms.MessageBox]::Show(
                            "Pair `"$PairName`" has been removed from Watch-Sync.`n`nWatch-Sync will now restart to update synchronization.",
                            "Watch-Sync",
                            [System.Windows.Forms.MessageBoxButtons]::OK,
                            [System.Windows.Forms.MessageBoxIcon]::Information
                        ) | Out-Null

                        Write-Log "Restart requested after removing pair '$PairName'."
                        $script:RestartRequested = $true
                        $script:ExitRequested = $true
                        $Form.Close()
                    }
                    catch {
                        Write-Log "Failed to remove pair '$PairName': $($_.Exception.Message)" "ERROR"
                        [System.Windows.Forms.MessageBox]::Show(
                            "Failed to remove pair:`n$($_.Exception.Message)",
                            "Watch-Sync Error",
                            [System.Windows.Forms.MessageBoxButtons]::OK,
                            [System.Windows.Forms.MessageBoxIcon]::Error
                        ) | Out-Null
                    }
                }
            })

        $Form.ShowDialog() | Out-Null
        $Form.Dispose()
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

        if ($script:AddPairRequested) {
            $script:AddPairRequested = $false
            if ($script:ActiveSyncJobs.Count -gt 0) {
                Show-TrayError -Message "A synchronization is currently in progress. Please wait for it to finish."
            }
            else {
                try {
                    Invoke-AddSyncPairFlow
                }
                catch {
                    Write-Log "Error during Add sync folder flow: $($_.Exception.ToString())" "ERROR"
                    [System.Windows.Forms.MessageBox]::Show(
                        "An error occurred while adding sync folder:`n$($_.Exception.Message)",
                        "Watch-Sync Error",
                        [System.Windows.Forms.MessageBoxButtons]::OK,
                        [System.Windows.Forms.MessageBoxIcon]::Error
                    ) | Out-Null
                }
            }

            if ($script:ExitRequested) {
                break
            }
        }

        if ($script:ManagePairsRequested) {
            $script:ManagePairsRequested = $false
            if ($script:ActiveSyncJobs.Count -gt 0) {
                Show-TrayError -Message "A synchronization is currently in progress. Please wait for it to finish."
            }
            else {
                try {
                    Show-ManagePairsDialog
                }
                catch {
                    Write-Log "Error in Manage sync folders dialog: $($_.Exception.ToString())" "ERROR"
                    [System.Windows.Forms.MessageBox]::Show(
                        "An error occurred in Manage sync folders dialog:`n$($_.Exception.Message)",
                        "Watch-Sync Error",
                        [System.Windows.Forms.MessageBoxButtons]::OK,
                        [System.Windows.Forms.MessageBoxIcon]::Error
                    ) | Out-Null
                }
            }

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
