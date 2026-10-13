<#
.SYNOPSIS
    Watch-Sync core logic: settings, pair merging, per-pair sync state and scheduling.
.DESCRIPTION
    Everything in this file is deliberately free of UI, logging, rclone processes
    and live application state (apart from a setting-type schema). Functions take their inputs as parameters and
    return results (or mutate the pair-state object passed in), so they can be
    tested without the tray application. The tray script dot-sources this file.
#>

# ----------------------------
# Path and sync pair helpers
# ----------------------------

function ConvertTo-NormalizedLocalPath {
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

function ConvertTo-NormalizedRemotePath {
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

    $NormalizedCandidateLocal = ConvertTo-NormalizedLocalPath -Path $CandidateLocal
    foreach ($Name in $ExistingPairs.Keys) {
        $ExistingLocal = [string]$ExistingPairs[$Name].Local
        $NormalizedExisting = ConvertTo-NormalizedLocalPath -Path $ExistingLocal
        if ($NormalizedCandidateLocal -eq $NormalizedExisting) {
            return [pscustomobject]@{
                HasConflict     = $true
                ConflictType    = "LocalPath"
                ConflictingName = $Name
                Message         = "Local folder '$CandidateLocal' is already configured by pair '$Name' ($ExistingLocal)."
            }
        }

        if ($NormalizedCandidateLocal.StartsWith($NormalizedExisting.TrimEnd('\') + "\", [System.StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{
                HasConflict     = $true
                ConflictType    = "LocalOverlap"
                ConflictingName = $Name
                Message         = "Local folder '$CandidateLocal' is inside existing pair '$Name' ($ExistingLocal). Nested folder synchronization is not allowed."
            }
        }

        if ($NormalizedExisting.StartsWith($NormalizedCandidateLocal.TrimEnd('\') + "\", [System.StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{
                HasConflict     = $true
                ConflictType    = "LocalOverlap"
                ConflictingName = $Name
                Message         = "Local folder '$CandidateLocal' contains existing pair '$Name' ($ExistingLocal). Nested folder synchronization is not allowed."
            }
        }
    }

    $NormalizedCandidateRemote = ConvertTo-NormalizedRemotePath -Remote $CandidateRemote
    foreach ($Name in $ExistingPairs.Keys) {
        $ExistingRemote = [string]$ExistingPairs[$Name].Remote
        $NormalizedExisting = ConvertTo-NormalizedRemotePath -Remote $ExistingRemote
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

# ----------------------------
# Configuration: pairs and settings
# ----------------------------

function ConvertTo-ManualPairs {
    <#
    .SYNOPSIS
        Validates the Pairs block of config.local.psd1 and expands environment variables.
    .OUTPUTS
        Object with Pairs (ordered dictionary, or $null when invalid) and Error (message or $null).
    #>
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$ConfigPairs
    )

    $Pairs = [ordered]@{}
    foreach ($PairKey in $ConfigPairs.Keys) {
        $PairData = $ConfigPairs[$PairKey]
        if (-not ($PairData -is [System.Collections.IDictionary]) -or
            -not $PairData.Contains("Local") -or
            -not $PairData.Contains("Remote")) {
            return [pscustomobject]@{
                Pairs = $null
                Error = "配對 [$PairKey] 設定不完整：必須包含 Local 與 Remote。"
            }
        }

        $Pairs[$PairKey] = [ordered]@{
            Local  = [System.Environment]::ExpandEnvironmentVariables([string]$PairData.Local)
            Remote = [string]$PairData.Remote
            Source = "config.local.psd1"
        }
    }

    return [pscustomobject]@{ Pairs = $Pairs; Error = $null }
}

function Resolve-SyncPairs {
    <#
    .SYNOPSIS
        Merges config.local.psd1 pairs with tray-managed pairs, rejecting conflicts.
    .OUTPUTS
        Object with Pairs (effective pairs), TrayStatus (per tray pair activity/reason),
        Loaded (accepted tray pair names) and Rejected (name, conflicting name, message).
    #>
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$ManualPairs,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$TrayPairs
    )

    $Effective = [ordered]@{}
    $TrayStatus = [ordered]@{}
    $Loaded = [System.Collections.Generic.List[string]]::new()
    $Rejected = [System.Collections.Generic.List[object]]::new()

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
            $TrayStatus[$Key] = [ordered]@{
                IsActive = $false
                Local    = $ExpandedLocal
                Remote   = $TrayRemote
                Reason   = $Conflict.Message
            }
            $Rejected.Add([pscustomobject]@{
                    Name            = $Key
                    ConflictingName = $Conflict.ConflictingName
                    Message         = $Conflict.Message
                })
            continue
        }

        $Effective[$Key] = [ordered]@{
            Local  = $ExpandedLocal
            Remote = $TrayRemote
            Source = "Tray-managed"
        }
        $TrayStatus[$Key] = [ordered]@{
            IsActive = $true
            Local    = $ExpandedLocal
            Remote   = $TrayRemote
            Reason   = $null
        }
        $Loaded.Add([string]$Key)
    }

    return [pscustomobject]@{
        Pairs     = $Effective
        TrayStatus = $TrayStatus
        Loaded    = @($Loaded)
        Rejected  = @($Rejected)
    }
}

$script:WatchSyncSettingTypes = [ordered]@{
    QuietSeconds               = 'int'
    IdleMinutes                = 'int'
    IdleRepeatMinutes          = 'int'
    ResumeGapSeconds           = 'int'
    ResumeDelaySeconds         = 'int'
    StartupDelaySeconds        = 'int'
    RetryDelaySeconds          = 'int'
    MaxAutoRetries             = 'int'
    MaxParallelSyncs           = 'int'
    Transfers                  = 'int'
    Checkers                   = 'int'
    CheckFileName              = 'string'
    LogRetentionDays           = 'int'
    LogMaxFileMiB              = 'int'
    LogMaxTotalMiB             = 'int'
    EnableTrayIcon             = 'bool'
    ShowTrayErrorNotifications = 'bool'
}

function Resolve-WatchSyncSettings {
    <#
    .SYNOPSIS
        Applies the Settings block of config.local.psd1 over built-in defaults.
    .OUTPUTS
        Object with Settings (merged hashtable), Errors (invalid values) and Unknown (unrecognized keys).
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable]$Defaults,

        [System.Collections.IDictionary]$Overrides
    )

    $Settings = $Defaults.Clone()
    $Errors = [System.Collections.Generic.List[string]]::new()
    $Unknown = [System.Collections.Generic.List[string]]::new()

    if ($null -ne $Overrides) {
        foreach ($Key in $Overrides.Keys) {
            if (-not $script:WatchSyncSettingTypes.Contains($Key)) {
                $Unknown.Add([string]$Key)
                continue
            }

            try {
                $Settings[$Key] = switch ($script:WatchSyncSettingTypes[$Key]) {
                    'int' { [int]$Overrides[$Key] }
                    'bool' {
                        if ($Overrides[$Key] -is [bool]) { $Overrides[$Key] }
                        elseif ($Overrides[$Key] -is [string]) { [bool]::Parse($Overrides[$Key]) }
                        elseif ($Overrides[$Key] -in @(0, 1)) { [bool]$Overrides[$Key] }
                        else { throw 'Expected a boolean.' }
                    }
                    default { [string]$Overrides[$Key] }
                }
            }
            catch {
                $Errors.Add("Setting '$Key' has an invalid value '$($Overrides[$Key])'.")
            }
        }
    }

    return [pscustomobject]@{
        Settings = $Settings
        Errors   = @($Errors)
        Unknown  = @($Unknown)
    }
}

function Test-WatchSyncSettings {
    <#
    .SYNOPSIS
        Range-checks resolved settings. Returns an array of error messages (empty when valid).
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable]$Settings
    )

    $Errors = [System.Collections.Generic.List[string]]::new()

    if ($Settings.LogRetentionDays -lt 1 -or $Settings.LogRetentionDays -gt 3650 -or
        $Settings.LogMaxFileMiB -lt 1 -or $Settings.LogMaxFileMiB -gt 1024 -or
        $Settings.LogMaxTotalMiB -lt $Settings.LogMaxFileMiB -or $Settings.LogMaxTotalMiB -gt 1048576) {
        $Errors.Add("Log settings require retention of 1-3650 days, file sizes of 1-1024 MiB, and a total limit at least as large as one log file.")
    }

    if ($Settings.MaxParallelSyncs -lt 1 -or $Settings.MaxParallelSyncs -gt 32) {
        $Errors.Add("MaxParallelSyncs must be between 1 and 32.")
    }

    foreach ($Key in @('QuietSeconds', 'IdleRepeatMinutes', 'ResumeDelaySeconds', 'StartupDelaySeconds', 'MaxAutoRetries')) {
        if ($Settings[$Key] -lt 0) { $Errors.Add("$Key must not be negative.") }
    }
    foreach ($Key in @('IdleMinutes', 'ResumeGapSeconds', 'RetryDelaySeconds', 'Transfers', 'Checkers')) {
        if ($Settings[$Key] -lt 1) { $Errors.Add("$Key must be positive.") }
    }
    if ([string]::IsNullOrWhiteSpace($Settings.CheckFileName) -or $Settings.CheckFileName -match '[/\\]' -or $Settings.CheckFileName -in @('.', '..')) {
        $Errors.Add('CheckFileName must be a filename at the pair root.')
    }

    # The leading comma keeps an empty list from being unrolled into $null.
    return , @($Errors)
}

# ----------------------------
# Per-pair sync state
# ----------------------------
# BlockKind records why a pair is blocked so the recheck logic knows what to verify:
#   Marker   - local safety marker file missing
#   ExitCode - rclone bisync reported a critical/usage error (exit 2 or 7)
#   Filters  - the filters file changed after the pair's last resync

function New-PairState {
    return [pscustomobject]@{
        Dirty       = $false
        LastChange  = [datetime]::MinValue
        RetryAt     = $null
        RetryCount  = 0
        RetryPaused = $false
        Blocked     = $false
        BlockKind   = $null
        BlockReason = $null
        InProgress  = $false
    }
}

function Register-PairChange {
    # A local filesystem change (or a watcher error that requires a full check).
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][datetime]$Time
    )

    $State.Dirty = $true
    $State.LastChange = $Time
    $State.RetryCount = 0
    $State.RetryPaused = $false
}

function Set-PairSyncStarted {
    # The dirty flag is cleared first so changes made during the run trigger one follow-up sync.
    param([Parameter(Mandatory)]$State)

    $State.Dirty = $false
    $State.RetryAt = $null
    $State.RetryPaused = $false
    $State.InProgress = $true
}

function Set-PairBlocked {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][ValidateSet('Marker', 'ExitCode', 'Filters')][string]$Kind,
        [Parameter(Mandatory)][string]$Reason
    )

    $State.Blocked = $true
    $State.BlockKind = $Kind
    $State.BlockReason = $Reason
    $State.RetryAt = $null
    $State.RetryPaused = $false
}

function Reset-PairBlock {
    param([Parameter(Mandatory)]$State)

    $State.Blocked = $false
    $State.BlockKind = $null
    $State.BlockReason = $null
    $State.RetryCount = 0
    $State.RetryAt = $null
    $State.RetryPaused = $false
}

function Set-PairLocalUnavailable {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][datetime]$Now,
        [Parameter(Mandatory)][int]$RetryDelaySeconds
    )

    $State.RetryAt = $Now.AddSeconds($RetryDelaySeconds)
    $State.RetryPaused = $false
}

function Set-PairLaunchFailed {
    # rclone could not be started at all; retried like a failed run but never blocks.
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][datetime]$Now,
        [Parameter(Mandatory)][int]$RetryDelaySeconds,
        [Parameter(Mandatory)][int]$MaxAutoRetries
    )

    $State.InProgress = $false
    $State.RetryCount++

    if ($State.RetryCount -le $MaxAutoRetries) {
        $State.RetryAt = $Now.AddSeconds($RetryDelaySeconds)
        $State.RetryPaused = $false
    }
    else {
        $State.RetryAt = $null
        $State.RetryCount = 0
        $State.RetryPaused = $true
    }
}

function Set-PairSyncFinished {
    <#
    .SYNOPSIS
        Applies the result of a finished rclone bisync run to the pair state.
    .OUTPUTS
        Object whose Kind is Success, Blocked, RetryScheduled or RetriesExhausted.
    #>
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][int]$ExitCode,
        [Parameter(Mandatory)][datetime]$Now,
        [Parameter(Mandatory)][int]$RetryDelaySeconds,
        [Parameter(Mandatory)][int]$MaxAutoRetries
    )

    $State.InProgress = $false

    if ($ExitCode -eq 0) {
        $State.RetryCount = 0
        $State.RetryAt = $null
        $State.RetryPaused = $false
        return [pscustomobject]@{ Kind = 'Success'; Attempt = 0 }
    }

    # Exit 2 is a usage/configuration error and exit 7 a critical abort that
    # needs manual inspection or a resync. Neither may become a retry loop.
    if ($ExitCode -eq 2 -or $ExitCode -eq 7) {
        Set-PairBlocked -State $State -Kind ExitCode -Reason "rclone exit code $ExitCode"
        return [pscustomobject]@{ Kind = 'Blocked'; Attempt = 0 }
    }

    $State.RetryCount++
    if ($State.RetryCount -le $MaxAutoRetries) {
        $State.RetryAt = $Now.AddSeconds($RetryDelaySeconds)
        $State.RetryPaused = $false
        return [pscustomobject]@{ Kind = 'RetryScheduled'; Attempt = $State.RetryCount }
    }

    $State.RetryAt = $null
    $State.RetryCount = 0
    $State.RetryPaused = $true
    return [pscustomobject]@{ Kind = 'RetriesExhausted'; Attempt = 0 }
}

function Get-PairRecheckOutcome {
    <#
    .SYNOPSIS
        Decides whether a blocked pair may be retried, without touching the state.
    .PARAMETER FilterStatus
        Current, Stale or Unknown (see Get-FiltersBaselineStatus).
    #>
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][bool]$MarkerExists,
        [Parameter(Mandatory)][ValidateSet('Current', 'Stale', 'Unknown')][string]$FilterStatus
    )

    if (-not $State.Blocked) {
        return [pscustomobject]@{ Unblock = $false; Reason = "Pair is not blocked." }
    }

    if ($FilterStatus -ne 'Current') {
        return [pscustomobject]@{
            Unblock = $false
            Reason  = "This pair has no verified baseline for the current filters. A resync is required."
        }
    }

    if (-not $MarkerExists) {
        return [pscustomobject]@{
            Unblock = $false
            Reason  = "The local safety marker file is still missing."
        }
    }

    return [pscustomobject]@{ Unblock = $true; Reason = $null }
}

# ----------------------------
# Scheduling
# ----------------------------

function Select-PairsDueForSync {
    <#
    .SYNOPSIS
        Chooses which pairs should start a sync now, within the parallelism limit.
    .DESCRIPTION
        Priority: explicit requests in the queue (in request order), then due
        retries (oldest due time first), then debounced local changes (oldest
        change first). Queue entries for pairs that are blocked, unknown or already
        running are dropped. Entries that merely wait for a free slot stay queued.
    .OUTPUTS
        Object with Starts (Name/Reason, at most the number of free slots) and
        Dropped (queue names the caller should remove).
    #>
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$States,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Queue,
        [Parameter(Mandatory)][datetime]$Now,
        [Parameter(Mandatory)][int]$QuietSeconds,
        [Parameter(Mandatory)][int]$MaxParallel
    )

    $Running = 0
    foreach ($Name in $States.Keys) {
        if ($States[$Name].InProgress) { $Running++ }
    }
    $Free = $MaxParallel - $Running

    $Starts = [System.Collections.Generic.List[object]]::new()
    $Dropped = [System.Collections.Generic.List[string]]::new()
    $Chosen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($Name in @($Queue.Keys)) {
        if (-not $States.Contains($Name) -or $States[$Name].Blocked -or $States[$Name].InProgress) {
            $Dropped.Add([string]$Name)
            continue
        }
        if ($Starts.Count -lt $Free) {
            [void]$Chosen.Add([string]$Name)
            $Starts.Add([pscustomobject]@{ Name = [string]$Name; Reason = [string]$Queue[$Name] })
        }
    }

    $Retries = foreach ($Name in $States.Keys) {
        $Entry = $States[$Name]
        if (-not $Entry.Blocked -and -not $Entry.InProgress -and
            $null -ne $Entry.RetryAt -and $Now -ge $Entry.RetryAt -and
            -not $Chosen.Contains([string]$Name)) {
            [pscustomobject]@{ Name = [string]$Name; DueAt = [datetime]$Entry.RetryAt }
        }
    }
    foreach ($Item in @($Retries | Sort-Object DueAt, Name)) {
        if ($Starts.Count -ge $Free) { break }
        [void]$Chosen.Add($Item.Name)
        $Starts.Add([pscustomobject]@{ Name = $Item.Name; Reason = 'retry' })
    }

    $Changes = foreach ($Name in $States.Keys) {
        $Entry = $States[$Name]
        if (-not $Entry.Blocked -and -not $Entry.InProgress -and -not $Entry.RetryPaused -and $Entry.Dirty -and
            $null -eq $Entry.RetryAt -and
            (($Now - $Entry.LastChange).TotalSeconds -ge $QuietSeconds) -and
            -not $Chosen.Contains([string]$Name)) {
            [pscustomobject]@{ Name = [string]$Name; DueAt = [datetime]$Entry.LastChange }
        }
    }
    foreach ($Item in @($Changes | Sort-Object DueAt, Name)) {
        if ($Starts.Count -ge $Free) { break }
        [void]$Chosen.Add($Item.Name)
        $Starts.Add([pscustomobject]@{ Name = $Item.Name; Reason = 'local change' })
    }

    return [pscustomobject]@{
        Starts  = @($Starts)
        Dropped = @($Dropped)
    }
}

# ----------------------------
# Filters baseline (per pair)
# ----------------------------
# rclone keeps a single filters hash next to the filters file. Once any one pair
# has been resynced after a filters change, that shared hash matches again and
# rclone stops complaining for every other pair even though their listings were
# built with the old filters. Watch-Sync therefore records the filters hash per
# pair at each successful resync and compares against that record.

function Get-WatchSyncFiltersHash {
    param([Parameter(Mandatory)][string]$FiltersFile)

    $Bytes = [System.IO.File]::ReadAllBytes($FiltersFile)
    $Hasher = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($Hasher.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $Hasher.Dispose() }
}

function Get-FiltersBaselines {
    param([Parameter(Mandatory)][string]$Path)

    $Result = [ordered]@{}
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $Result
    }

    $Raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($Raw)) {
        return $Result
    }

    $Parsed = ConvertFrom-Json -InputObject $Raw -AsHashtable
    if ($null -eq $Parsed) {
        return $Result
    }
    if ($Parsed -isnot [System.Collections.IDictionary]) { throw 'Invalid filters baseline file: expected a JSON object.' }

    foreach ($Key in $Parsed.Keys) {
        $Entry = $Parsed[$Key]
        if ($Entry -is [System.Collections.IDictionary] -and $Entry.Contains('FiltersHash')) {
            $Result[[string]$Key] = [ordered]@{
                FiltersHash = [string]$Entry['FiltersHash']
                Local       = if ($Entry.Contains('Local')) { [string]$Entry['Local'] } else { '' }
                Remote      = if ($Entry.Contains('Remote')) { [string]$Entry['Remote'] } else { '' }
                UpdatedAt   = if ($Entry.Contains('UpdatedAt')) { [string]$Entry['UpdatedAt'] } else { '' }
            }
        }
    }
    return $Result
}

function Write-FiltersBaselines {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Baselines,
        [Parameter(Mandatory)][string]$Path
    )

    $Directory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrEmpty($Directory)) {
        [void][System.IO.Directory]::CreateDirectory($Directory)
    }

    $Json = if ($Baselines.Count -eq 0) { "{}`r`n" } else { $Baselines | ConvertTo-Json -Depth 4 }
    $TempFile = "$Path.tmp.$([System.Guid]::NewGuid().ToString('N'))"
    try {
        [System.IO.File]::WriteAllText($TempFile, $Json, [System.Text.UTF8Encoding]::new($false))
        # Antivirus/indexers may briefly hold the destination on Windows. Retry
        # the atomic rename; never fall back to truncating/copying the live file.
        for ($Attempt = 0; ; $Attempt++) {
            try {
                [System.IO.File]::Move($TempFile, $Path, $true)
                break
            }
            catch [System.IO.IOException] {
                if ($Attempt -ge 3) { throw }
                Start-Sleep -Milliseconds (50 * ($Attempt + 1))
            }
        }
    }
    finally {
        if (Test-Path -LiteralPath $TempFile) {
            Remove-Item -LiteralPath $TempFile -Force -ErrorAction SilentlyContinue
        }
    }
}

function Set-FiltersBaseline {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Baselines,
        [Parameter(Mandatory)][string]$PairName,
        [Parameter(Mandatory)][string]$Local,
        [Parameter(Mandatory)][string]$Remote,
        [Parameter(Mandatory)][string]$FiltersHash,
        [datetime]$Now = (Get-Date)
    )

    $Baselines[$PairName] = [ordered]@{
        FiltersHash = $FiltersHash
        Local       = ConvertTo-NormalizedLocalPath -Path $Local
        Remote      = ConvertTo-NormalizedRemotePath -Remote $Remote
        UpdatedAt   = $Now.ToString('o')
    }
}

function Get-FiltersBaselineStatus {
    <#
    .SYNOPSIS
        Compares the current filters hash with the one recorded at the pair's last resync.
    .OUTPUTS
        Current - recorded hash matches.
        Stale   - recorded hash differs; the pair's baseline was built with other filters.
        Unknown - nothing recorded for this pair (or recorded for a different folder pair).
    #>
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Baselines,
        [Parameter(Mandatory)][string]$PairName,
        [Parameter(Mandatory)][string]$Local,
        [Parameter(Mandatory)][string]$Remote,
        [Parameter(Mandatory)][string]$CurrentHash
    )

    if (-not $Baselines.Contains($PairName)) {
        return 'Unknown'
    }

    $Entry = $Baselines[$PairName]
    if ($Entry.Local -ne (ConvertTo-NormalizedLocalPath -Path $Local) -or
        $Entry.Remote -ne (ConvertTo-NormalizedRemotePath -Remote $Remote)) {
        return 'Unknown'
    }

    if ($Entry.FiltersHash.Equals($CurrentHash, [System.StringComparison]::OrdinalIgnoreCase)) {
        return 'Current'
    }
    return 'Stale'
}

# ----------------------------
# Resync preview
# ----------------------------

function Get-ResyncPreviewSummary {
    <#
    .SYNOPSIS
        Summarizes what a `bisync --resync --dry-run` would change from its log text.
    .OUTPUTS
        Object with Counts (operation -> count), Total, Deletes and Samples ("operation: path").
    #>
    param([AllowEmptyString()][string]$LogText = '')

    $Counts = [ordered]@{}
    $Samples = [System.Collections.Generic.List[string]]::new()

    foreach ($Line in ($LogText -split "\r?\n")) {
        if ($Line -match 'NOTICE: (?<path>.+?): Skipped (?<op>.+?) as --dry-run') {
            $Operation = $Matches['op']
            # Directory timestamp updates are noise in a preview.
            if ($Operation -eq 'set directory modification time') { continue }

            if ($Counts.Contains($Operation)) { $Counts[$Operation]++ } else { $Counts[$Operation] = 1 }
            if ($Samples.Count -lt 10) { $Samples.Add("${Operation}: $($Matches['path'])") }
        }
    }

    $Total = 0
    foreach ($Value in $Counts.Values) { $Total += $Value }
    $Deletes = 0
    foreach ($Key in $Counts.Keys) {
        if ($Key -match 'delete|remove') { $Deletes += $Counts[$Key] }
    }

    return [pscustomobject]@{
        Counts  = $Counts
        Total   = $Total
        Deletes = $Deletes
        Samples = @($Samples)
    }
}
