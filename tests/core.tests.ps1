#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepoDir = Split-Path -Parent $PSScriptRoot
. (Join-Path $RepoDir 'watch-sync-core.ps1')
$script:Assertions = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:Assertions++
}
function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -ne $Expected) { throw "$Message (expected '$Expected', got '$Actual')" }
    $script:Assertions++
}
$Now = [datetime]'2026-01-01T12:00:00'

# ---- Remote path helpers ----
Assert-Equal (ConvertTo-NormalizedRemotePath 'GDrive:/Pictures//Upscale/') 'gdrive:pictures/upscale' 'Remote normalization'
Assert-Equal (ConvertTo-NormalizedRemotePath 'obsidian_crypt:') 'obsidian_crypt:' 'Root remote normalization'
Assert-Equal (Join-RemotePath -RemotePrefix 'gdrive:A/B' -SubPath '/.check') 'gdrive:A/B/.check' 'Join remote path'
Assert-Equal (Get-RemoteFilePath -RemotePath 'obsidian_crypt:' -FileName '.check') 'obsidian_crypt:.check' 'Marker at remote root'

# ---- Pair conflict checks ----
$Existing = [ordered]@{ Docs = @{ Local = 'C:\Data\Docs'; Remote = 'gdrive:Docs' } }
Assert-True (-not (Test-SyncPairConflict -ExistingPairs $Existing -CandidateName 'Other' -CandidateLocal 'C:\Data\Other' -CandidateRemote 'gdrive:Other').HasConflict) 'Unrelated pair must be accepted.'
Assert-Equal (Test-SyncPairConflict -ExistingPairs $Existing -CandidateName 'docs' -CandidateLocal 'C:\X' -CandidateRemote 'gdrive:X').ConflictType 'Name' 'Names compare case-insensitively.'
Assert-Equal (Test-SyncPairConflict -ExistingPairs $Existing -CandidateName 'N' -CandidateLocal 'c:\data\docs\' -CandidateRemote 'gdrive:X').ConflictType 'LocalPath' 'Same folder differing in case/slash.'
Assert-Equal (Test-SyncPairConflict -ExistingPairs $Existing -CandidateName 'N' -CandidateLocal 'C:\Data\Docs\Sub' -CandidateRemote 'gdrive:X').ConflictType 'LocalOverlap' 'Nested local folder.'
Assert-Equal (Test-SyncPairConflict -ExistingPairs $Existing -CandidateName 'N' -CandidateLocal 'C:\Data' -CandidateRemote 'gdrive:X').ConflictType 'LocalOverlap' 'Parent local folder.'
Assert-Equal (Test-SyncPairConflict -ExistingPairs $Existing -CandidateName 'N' -CandidateLocal 'C:\Y' -CandidateRemote 'GDRIVE:docs/').ConflictType 'RemotePath' 'Same remote path.'
Assert-Equal (Test-SyncPairConflict -ExistingPairs $Existing -CandidateName 'N' -CandidateLocal 'C:\Y' -CandidateRemote 'gdrive:Docs/Sub').ConflictType 'RemoteOverlap' 'Nested remote path.'
Assert-Equal (Test-SyncPairConflict -ExistingPairs $Existing -CandidateName 'N' -CandidateLocal 'C:\Y' -CandidateRemote 'gdrive:').ConflictType 'RemoteOverlap' 'Remote root contains existing pair.'
Assert-True (-not (Test-SyncPairConflict -ExistingPairs $Existing -CandidateName 'N' -CandidateLocal 'C:\Y' -CandidateRemote 'other:Docs').HasConflict) 'Same path on another remote is fine.'
Assert-True (-not (Test-SyncPairConflict -ExistingPairs $Existing -CandidateName 'N' -CandidateLocal 'C:\Data\Docs2' -CandidateRemote 'gdrive:Docs2').HasConflict) 'Sibling prefix names must not count as nesting.'

# ---- Manual pair parsing and merging ----
$RootPair = [ordered]@{ Root = @{ Local = 'C:\'; Remote = 'gdrive:Root' } }
Assert-Equal (Test-SyncPairConflict -ExistingPairs $RootPair -CandidateName Child -CandidateLocal 'C:\Data' -CandidateRemote 'gdrive:Child').ConflictType 'LocalOverlap' 'Drive root contains its child folders.'
Assert-Equal (Test-SyncPairConflict -ExistingPairs $Existing -CandidateName Root -CandidateLocal 'C:\' -CandidateRemote 'gdrive:Root').ConflictType 'LocalOverlap' 'Drive root overlaps an existing folder.'
$Manual = ConvertTo-ManualPairs -ConfigPairs @{ A = @{ Local = '%SystemDrive%\A'; Remote = 'gdrive:A' } }
Assert-True ($null -eq $Manual.Error) 'Valid config pairs must parse.'
Assert-True (-not $Manual.Pairs['A'].Local.Contains('%')) 'Environment variables must be expanded.'
Assert-Equal $Manual.Pairs['A'].Source 'config.local.psd1' 'Manual pair source.'
Assert-True ($null -ne (ConvertTo-ManualPairs -ConfigPairs @{ B = @{ Local = 'C:\B' } }).Error) 'A pair without Remote must be reported.'
Assert-True ($null -ne (ConvertTo-ManualPairs -ConfigPairs @{ B = 'text' }).Error) 'A non-table pair must be reported, not thrown.'

$ManualPairs = [ordered]@{ Docs = @{ Local = 'C:\Data\Docs'; Remote = 'gdrive:Docs'; Source = 'config.local.psd1' } }
$TrayPairs = [ordered]@{
    Good     = @{ Local = 'C:\Data\Good'; Remote = 'gdrive:Good' }
    Nested   = @{ Local = 'C:\Data\Docs\Inner'; Remote = 'gdrive:Inner' }
    SameName = @{ Local = 'C:\Data\Else'; Remote = 'gdrive:Docs' }
}
$Merged = Resolve-SyncPairs -ManualPairs $ManualPairs -TrayPairs $TrayPairs
Assert-Equal (@($Merged.Pairs.Keys) -join ',') 'Docs,Good' 'Conflicting tray pairs must be rejected, manual pairs win.'
Assert-Equal $Merged.Pairs['Good'].Source 'Tray-managed' 'Tray pair source.'
Assert-Equal $Merged.Rejected.Count 2 'Both conflicts must be reported.'
Assert-True (-not $Merged.TrayStatus['Nested'].IsActive) 'Rejected tray pair must be inactive.'
Assert-True ($Merged.TrayStatus['Good'].IsActive) 'Accepted tray pair must be active.'
Assert-Equal ($Merged.Loaded -join ',') 'Good' 'Loaded list.'

# ---- Settings ----
$Defaults = @{
    QuietSeconds = 30; IdleMinutes = 10; IdleRepeatMinutes = 60; ResumeGapSeconds = 90; ResumeDelaySeconds = 10
    StartupDelaySeconds = 3; RetryDelaySeconds = 120; MaxAutoRetries = 3; MaxParallelSyncs = 4; Transfers = 4
    Checkers = 8; CheckFileName = '.rclone-bisync-check'; LogRetentionDays = 30; LogMaxFileMiB = 10
    LogMaxTotalMiB = 200; EnableTrayIcon = $true; ShowTrayErrorNotifications = $true
}
$Resolved = Resolve-WatchSyncSettings -Defaults $Defaults -Overrides @{ QuietSeconds = '45'; EnableTrayIcon = 0; Mystery = 1 }
Assert-Equal $Resolved.Settings.QuietSeconds 45 'Override must be coerced to int.'
Assert-True (-not $Resolved.Settings.EnableTrayIcon) 'Override must be coerced to bool.'
Assert-Equal $Resolved.Settings.IdleMinutes 10 'Unspecified settings keep defaults.'
Assert-Equal $Defaults.QuietSeconds 30 'Defaults must not be modified.'
Assert-Equal ($Resolved.Unknown -join ',') 'Mystery' 'Unknown keys are reported.'
Assert-Equal (Resolve-WatchSyncSettings -Defaults $Defaults -Overrides @{ Transfers = 'many' }).Errors.Count 1 'Invalid values are reported, not thrown.'
Assert-Equal (Resolve-WatchSyncSettings -Defaults $Defaults -Overrides $null).Settings.Transfers 4 'Missing Settings block is allowed.'
Assert-Equal (Test-WatchSyncSettings -Settings $Defaults).Count 0 'Defaults must validate.'
$Bad = $Defaults.Clone(); $Bad.MaxParallelSyncs = 0
Assert-Equal (Test-WatchSyncSettings -Settings $Bad).Count 1 'MaxParallelSyncs below 1 is invalid.'
$Bad.MaxParallelSyncs = 4; $Bad.LogMaxTotalMiB = 5
Assert-Equal (Test-WatchSyncSettings -Settings $Bad).Count 1 'Log total smaller than one file is invalid.'

# ---- Pair state transitions ----
$S = New-PairState
Register-PairChange -State $S -Time $Now
Assert-True ($S.Dirty -and $S.LastChange -eq $Now) 'Change marks the pair dirty.'
Set-PairSyncStarted -State $S
Assert-True ($S.InProgress -and -not $S.Dirty) 'Start clears dirty and sets in-progress.'
Register-PairChange -State $S -Time $Now.AddSeconds(5)
Assert-True ($S.Dirty -and $S.InProgress) 'A change during a run must stay dirty for a follow-up sync.'

$Outcome = Set-PairSyncFinished -State $S -ExitCode 0 -Now $Now -RetryDelaySeconds 120 -MaxAutoRetries 3
Assert-Equal $Outcome.Kind 'Success' 'Exit 0 is success.'
Assert-True (-not $S.InProgress -and $null -eq $S.RetryAt -and $S.RetryCount -eq 0) 'Success clears retry state.'

$S = New-PairState
foreach ($Attempt in 1..3) {
    Set-PairSyncStarted -State $S
    $Outcome = Set-PairSyncFinished -State $S -ExitCode 1 -Now $Now -RetryDelaySeconds 120 -MaxAutoRetries 3
    Assert-Equal $Outcome.Kind 'RetryScheduled' "Failure $Attempt schedules a retry."
    Assert-Equal $Outcome.Attempt $Attempt 'Attempt number.'
    Assert-Equal $S.RetryAt $Now.AddSeconds(120) 'Retry time.'
}
Set-PairSyncStarted -State $S
$Outcome = Set-PairSyncFinished -State $S -ExitCode 1 -Now $Now -RetryDelaySeconds 120 -MaxAutoRetries 3
Assert-Equal $Outcome.Kind 'RetriesExhausted' 'Fourth failure exhausts retries.'
Assert-True ($S.RetryPaused -and $null -eq $S.RetryAt -and $S.RetryCount -eq 0) 'Exhausted retries pause until the next trigger.'
Register-PairChange -State $S -Time $Now
Assert-True (-not $S.RetryPaused) 'A new local change resumes automatic retries.'

foreach ($Code in 2, 7) {
    $S = New-PairState
    Set-PairSyncStarted -State $S
    $Outcome = Set-PairSyncFinished -State $S -ExitCode $Code -Now $Now -RetryDelaySeconds 120 -MaxAutoRetries 3
    Assert-Equal $Outcome.Kind 'Blocked' "Exit $Code blocks the pair."
    Assert-True ($S.Blocked -and $S.BlockKind -eq 'ExitCode' -and $null -eq $S.RetryAt) "Exit $Code must not schedule retries."
    Assert-Equal $S.BlockReason "rclone exit code $Code" 'Block reason.'
}

$S = New-PairState
Set-PairSyncStarted -State $S
Set-PairLaunchFailed -State $S -Now $Now -RetryDelaySeconds 60 -MaxAutoRetries 1
Assert-True (-not $S.InProgress -and $S.RetryAt -eq $Now.AddSeconds(60)) 'Launch failure schedules a retry.'
Set-PairLaunchFailed -State $S -Now $Now -RetryDelaySeconds 60 -MaxAutoRetries 1
Assert-True ($S.RetryPaused -and -not $S.Blocked) 'Repeated launch failures pause but never block.'
$S = New-PairState
Set-PairLocalUnavailable -State $S -Now $Now -RetryDelaySeconds 60
Assert-Equal $S.RetryAt $Now.AddSeconds(60) 'Missing local folder retries later.'

# ---- Block recheck ----
$S = New-PairState
Assert-True (-not (Get-PairRecheckOutcome -State $S -MarkerExists $true -FilterStatus 'Current').Unblock) 'An unblocked pair has nothing to recheck.'
Set-PairBlocked -State $S -Kind Marker -Reason 'local safety marker missing'
Assert-True (-not (Get-PairRecheckOutcome -State $S -MarkerExists $false -FilterStatus 'Current').Unblock) 'Missing marker keeps the pair blocked.'
Assert-True ((Get-PairRecheckOutcome -State $S -MarkerExists $true -FilterStatus 'Current').Unblock) 'Restored marker allows a retry.'
Assert-True (-not (Get-PairRecheckOutcome -State $S -MarkerExists $true -FilterStatus 'Unknown').Unblock) 'Unknown baseline requires one verified resync before unblocking.'
Assert-True (-not (Get-PairRecheckOutcome -State $S -MarkerExists $true -FilterStatus 'Stale').Unblock) 'A stale filters baseline always requires a resync.'
Set-PairBlocked -State $S -Kind ExitCode -Reason 'rclone exit code 7'
Assert-True ((Get-PairRecheckOutcome -State $S -MarkerExists $true -FilterStatus 'Current').Unblock) 'An rclone-blocked pair may be retried after inspection.'
Reset-PairBlock -State $S
Assert-True (-not $S.Blocked -and $null -eq $S.BlockKind -and $S.RetryCount -eq 0) 'Clearing a block resets retry state.'

# ---- Scheduling ----
function New-States { param([string[]]$Names) $R = @{}; foreach ($N in $Names) { $R[$N] = New-PairState }; return $R }
function Get-Starts { param($States, $Queue = [ordered]@{}, [int]$Max = 2, [datetime]$At = $Now) (Select-PairsDueForSync -States $States -Queue $Queue -Now $At -QuietSeconds 30 -MaxParallel $Max) }

$States = New-States 'a', 'b', 'c', 'd'
Assert-Equal (Get-Starts $States).Starts.Count 0 'Nothing due means nothing starts.'

Register-PairChange -State $States['a'] -Time $Now.AddSeconds(-10)
Assert-Equal (Get-Starts $States).Starts.Count 0 'A change inside the quiet period waits.'
Assert-Equal (Get-Starts $States -At $Now.AddSeconds(20)).Starts.Count 1 'A change is due once the quiet period elapsed.'
Assert-Equal (Get-Starts $States -At $Now.AddSeconds(20)).Starts[0].Reason 'local change' 'Reason for a local change.'

$States = New-States 'a', 'b', 'c', 'd'
Register-PairChange -State $States['c'] -Time $Now.AddSeconds(-300)
Register-PairChange -State $States['a'] -Time $Now.AddSeconds(-200)
Register-PairChange -State $States['b'] -Time $Now.AddSeconds(-100)
$Order = (Get-Starts $States -Max 2).Starts.Name -join ','
Assert-Equal $Order 'c,a' 'Oldest change goes first and the parallel limit caps starts.'
Assert-Equal (Get-Starts $States -Max 3).Starts.Count 3 'A higher limit starts more pairs.'
Set-PairSyncStarted -State $States['c']
Assert-Equal ((Get-Starts $States -Max 2).Starts.Name -join ',') 'a' 'A running pair consumes a slot.'
Set-PairSyncStarted -State $States['a']
Assert-Equal (Get-Starts $States -Max 2).Starts.Count 0 'No free slot means no start.'

# A retry waiting for its time must not let the dirty flag bypass the delay.
$States = New-States 'a'
Register-PairChange -State $States['a'] -Time $Now.AddSeconds(-100)
$States['a'].RetryAt = $Now.AddSeconds(60)
Assert-Equal (Get-Starts $States).Starts.Count 0 'A pending retry holds back the local-change sync.'
Assert-Equal (Get-Starts $States -At $Now.AddSeconds(61)).Starts[0].Reason 'retry' 'Retry is due after its delay.'

# Retries outrank local changes; blocked pairs never start.
$States = New-States 'a', 'b', 'c'
Register-PairChange -State $States['a'] -Time $Now.AddSeconds(-500)
$States['b'].RetryAt = $Now.AddSeconds(-1)
Register-PairChange -State $States['c'] -Time $Now.AddSeconds(-400)
Set-PairBlocked -State $States['c'] -Kind ExitCode -Reason 'x'
$Starts = (Get-Starts $States -Max 2).Starts
Assert-Equal ($Starts.Name -join ',') 'b,a' 'Retry first, then change; blocked pair excluded.'

# Queue handling
$States = New-States 'a', 'b', 'c', 'd'
Set-PairBlocked -State $States['b'] -Kind Marker -Reason 'x'
Set-PairSyncStarted -State $States['c']
$Queue = [ordered]@{ a = 'manual tray'; b = 'manual tray'; c = 'manual tray'; d = 'manual tray'; ghost = 'manual tray' }
$Result = Get-Starts $States $Queue 3
Assert-Equal ($Result.Starts.Name -join ',') 'a,d' 'Queued pairs start in request order.'
Assert-Equal ($Result.Starts[0].Reason) 'manual tray' 'Queue reason is preserved.'
Assert-Equal (($Result.Dropped | Sort-Object) -join ',') 'b,c,ghost' 'Blocked, running and unknown pairs are dropped from the queue.'

$States = New-States 'a', 'b', 'c'
$Queue = [ordered]@{ a = 'startup'; b = 'startup'; c = 'startup' }
$Result = Get-Starts $States $Queue 2
Assert-Equal ($Result.Starts.Name -join ',') 'a,b' 'The limit holds queue entries back.'
Assert-Equal $Result.Dropped.Count 0 'Entries waiting for a slot stay queued.'
foreach ($Item in $Result.Starts) { $Queue.Remove($Item.Name); $States[$Item.Name].InProgress = $true }
Assert-Equal (Get-Starts $States $Queue 2).Starts.Count 0 'Queue waits while all slots are busy.'
$States['a'].InProgress = $false
Assert-Equal ((Get-Starts $States $Queue 2).Starts.Name -join ',') 'c' 'A freed slot starts the next queued pair.'

# Queue entries take priority and are not started twice.
$States = New-States 'a', 'b'
$States['a'].RetryAt = $Now.AddSeconds(-1)
Register-PairChange -State $States['b'] -Time $Now.AddSeconds(-100)
$Result = Get-Starts $States ([ordered]@{ a = 'manual tray' }) 5
Assert-Equal (($Result.Starts | ForEach-Object { "$($_.Name):$($_.Reason)" }) -join ',') 'a:manual tray,b:local change' 'A queued pair is not also started as a retry.'

# ---- Filters baseline ----
$TempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
$TestDir = Join-Path $TempRoot ('watch-sync-core-tests-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($TestDir)
try {
    $FiltersFile = Join-Path $TestDir 'watch-sync.filters'
    [IO.File]::WriteAllText($FiltersFile, "- *.tmp`n")
    $HashA = Get-WatchSyncFiltersHash -FiltersFile $FiltersFile
    Assert-Equal $HashA.Length 64 'SHA-256 hex length.'
    Assert-Equal (Get-WatchSyncFiltersHash -FiltersFile $FiltersFile) $HashA 'Hash is stable.'
    [IO.File]::WriteAllText($FiltersFile, "- *.tmp`n- *.bak`n")
    $HashB = Get-WatchSyncFiltersHash -FiltersFile $FiltersFile
    Assert-True ($HashA -ne $HashB) 'Content changes alter the hash.'

    $BaselineFile = Join-Path $TestDir 'state\filters-baselines.json'
    Assert-Equal (Get-FiltersBaselines -Path $BaselineFile).Count 0 'A missing baseline file reads as empty.'

    $Baselines = [ordered]@{}
    Assert-Equal (Get-FiltersBaselineStatus -Baselines $Baselines -PairName 'Docs' -Local 'C:\Data\Docs' -Remote 'gdrive:Docs' -CurrentHash $HashA) 'Unknown' 'No record is Unknown.'
    Set-FiltersBaseline -Baselines $Baselines -PairName 'Docs' -Local 'C:\Data\Docs' -Remote 'gdrive:Docs' -FiltersHash $HashA -Now $Now
    Set-FiltersBaseline -Baselines $Baselines -PairName 'Pics' -Local 'C:\Data\Pics' -Remote 'gdrive:Pics' -FiltersHash $HashA -Now $Now
    Write-FiltersBaselines -Baselines $Baselines -Path $BaselineFile
    Write-FiltersBaselines -Baselines $Baselines -Path $BaselineFile
    Assert-Equal @(Get-ChildItem -LiteralPath (Split-Path -Parent $BaselineFile) -Filter '*.tmp.*').Count 0 'Atomic write must not leave temp files.'
    $Loaded = Get-FiltersBaselines -Path $BaselineFile
    Assert-Equal $Loaded.Count 2 'Baselines round-trip.'

    Assert-Equal (Get-FiltersBaselineStatus -Baselines $Loaded -PairName 'Docs' -Local 'c:\data\docs\' -Remote 'GDRIVE:docs' -CurrentHash $HashA.ToUpperInvariant()) 'Current' 'Matching hash is Current regardless of path/hash case.'
    Assert-Equal (Get-FiltersBaselineStatus -Baselines $Loaded -PairName 'Docs' -Local 'C:\Data\Docs' -Remote 'gdrive:Docs' -CurrentHash $HashB) 'Stale' 'Changed filters make the baseline Stale.'
    Assert-Equal (Get-FiltersBaselineStatus -Baselines $Loaded -PairName 'Docs' -Local 'C:\Elsewhere' -Remote 'gdrive:Docs' -CurrentHash $HashA) 'Unknown' 'A baseline for another folder is ignored.'

    # Resyncing one pair must not make other pairs current.
    Set-FiltersBaseline -Baselines $Loaded -PairName 'Docs' -Local 'C:\Data\Docs' -Remote 'gdrive:Docs' -FiltersHash $HashB
    Assert-Equal (Get-FiltersBaselineStatus -Baselines $Loaded -PairName 'Docs' -Local 'C:\Data\Docs' -Remote 'gdrive:Docs' -CurrentHash $HashB) 'Current' 'The resynced pair is Current.'
    Assert-Equal (Get-FiltersBaselineStatus -Baselines $Loaded -PairName 'Pics' -Local 'C:\Data\Pics' -Remote 'gdrive:Pics' -CurrentHash $HashB) 'Stale' 'Other pairs stay Stale until resynced themselves.'

    [IO.File]::WriteAllText($BaselineFile, '{ not json')
    $Failed = $false
    try { [void](Get-FiltersBaselines -Path $BaselineFile) } catch { $Failed = $true }
    Assert-True $Failed 'A corrupt baseline file must be reported to the caller.'
}
finally {
    $Resolved = [IO.Path]::GetFullPath($TestDir)
    if ($Resolved.StartsWith($TempRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $Resolved) -match '^watch-sync-core-tests-[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $Resolved -Recurse -Force
    }
    else { throw 'Refusing cleanup outside the generated test directory.' }
}

# ---- Resync preview ----
$Log = @'
2026/10/14 00:34:15 NOTICE: mount/a.lnk: Skipped copy as --dry-run is set (size 1.889Ki)
2026/10/14 00:34:15 NOTICE: mount: Skipped set directory modification time as --dry-run is set (size 0)
2026/10/14 00:34:16 NOTICE: old/b.txt: Skipped delete as --dry-run is set (size 2)
2026/10/14 00:34:16 NOTICE: c.txt: Skipped copy as --dry-run is set (size 3)
2026/10/14 00:34:17 INFO  : unrelated line
'@
$Preview = Get-ResyncPreviewSummary -LogText $Log
Assert-Equal $Preview.Total 3 'Directory timestamp noise is excluded from the total.'
Assert-Equal $Preview.Counts['copy'] 2 'Copies are counted.'
Assert-Equal $Preview.Deletes 1 'Deletes are surfaced separately.'
Assert-Equal $Preview.Samples[0] 'copy: mount/a.lnk' 'Samples name the operation and path.'
Assert-Equal (Get-ResyncPreviewSummary -LogText '').Total 0 'Empty logs summarize to nothing.'

# Retry exhaustion must not be bypassed by an older dirty event.
$States = New-States 'a'
Register-PairChange -State $States.a -Time $Now.AddSeconds(-60)
$States.a.RetryPaused = $true
Assert-Equal (Get-Starts $States).Starts.Count 0 'A dirty flag left by a failed run does not bypass paused retries.'
Register-PairChange -State $States.a -Time $Now.AddSeconds(-60)
Assert-Equal (Get-Starts $States).Starts.Count 1 'A new event rearms a paused pair.'
$States.a.RetryAt = $Now.AddSeconds(-60)
$States.a.RetryCount = 1
Set-PairLaunchFailed -State $States.a -Now $Now -RetryDelaySeconds 60 -MaxAutoRetries 1
Assert-True ($null -eq $States.a.RetryAt -and $States.a.RetryCount -eq 0 -and $States.a.RetryPaused) 'Exhausted launch retries clear stale due times.'
Assert-True (-not (Resolve-WatchSyncSettings -Defaults $Defaults -Overrides @{ EnableTrayIcon = 'false' }).Settings.EnableTrayIcon) 'String false must not become true.'
Assert-Equal (Resolve-WatchSyncSettings -Defaults $Defaults -Overrides @{ EnableTrayIcon = 'invalid' }).Errors.Count 1 'Invalid boolean is rejected.'
$Bad = $Defaults.Clone(); $Bad.RetryDelaySeconds = 0
Assert-True ((Test-WatchSyncSettings -Settings $Bad).Count -gt 0) 'Zero retry delay is invalid.'
Write-Output "Passed $script:Assertions core assertions."
