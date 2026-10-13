#Requires -Version 7.0
# Load function definitions through the AST, never the production startup/configuration.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepoDir = Split-Path -Parent $PSScriptRoot
. (Join-Path $RepoDir 'watch-sync-core.ps1')
. (Join-Path $RepoDir 'watch-sync-maintenance.ps1')
. (Join-Path $RepoDir 'watch-sync-resync.ps1')
$Tokens = $null; $ParseErrors = $null
$Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoDir 'watch-sync-tray.ps1'), [ref]$Tokens, [ref]$ParseErrors)
if ($ParseErrors.Count) { throw ($ParseErrors -join "`n") }
$Definitions = $Ast.FindAll({ param($Node) $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
foreach ($Definition in $Definitions) { . ([scriptblock]::Create($Definition.Extent.Text)) }
$script:Assertions = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:Assertions++
}
# Every project-local command must resolve, catching the half-integrated scheduler.
$ProjectVerbs = 'Resync|Pair|Sync|Tray|Filters|WatchSync|Bisync|Loop|Application|Watcher|Rclone|Manual|Remote|Normalized|Cleanup|LogFile'
foreach ($Command in $Ast.FindAll({ param($Node) $Node -is [System.Management.Automation.Language.CommandAst] }, $true)) {
    $Name = $Command.GetCommandName()
    if ($Name -and $Name -match "^[A-Za-z]+-($ProjectVerbs)") {
        Assert-True ($null -ne (Get-Command $Name -ErrorAction SilentlyContinue)) "Unresolved project command: $Name"
    }
}
# Headless UI substitutes: real scheduler/process/filter functions remain loaded.
function Write-Log { param($Message, $Level = 'INFO') }
function Show-TrayError { param($Message) }
function Invoke-ApplicationPump { }
$script:TrayIcon = $null
$script:FiltersHash = $null
$script:FiltersReadError = $null
$script:FilterBlockCheckDue = $true
$script:NextFilterCheck = [datetime]::MinValue
$script:ExitRequested = $false
$script:HoldNewSyncs = $false
$script:SyncQueue = [ordered]@{}
$script:ActiveSyncJobs = [System.Collections.Generic.List[object]]::new()
$script:FiltersBaselines = [ordered]@{}
$script:QuietSeconds = 0; $script:RetryDelaySeconds = 60; $script:MaxAutoRetries = 2; $script:MaxParallelSyncs = 1
$script:Transfers = 1; $script:Checkers = 1; $CheckFileName = '.rclone-bisync-check'
$script:LogMaxFileMiB = 10; $script:LogRetentionDays = 30
$script:RcloneExe = (Get-Command rclone.exe -ErrorAction Stop).Source
$TempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
$TestDir = Join-Path $TempRoot ('watch-sync-integration-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($TestDir)
try {
    $LogDir = Join-Path $TestDir 'logs'
    [void][IO.Directory]::CreateDirectory($LogDir)
    $FiltersFile = Join-Path $TestDir 'test.filters'
    [IO.File]::WriteAllText($FiltersFile, "- *.tmp`n")
    $FiltersBaselineFile = Join-Path $TestDir 'baselines.json'
    $CommonArguments = @(Get-CommonBisyncArguments) + @('--workdir', (Join-Path $TestDir 'bisync'), '--config', (Join-Path $TestDir 'empty.conf'))
    [IO.File]::WriteAllText((Join-Path $TestDir 'empty.conf'), '')
    function Get-CommonBisyncArguments { return $CommonArguments }
    $Pairs = [ordered]@{}
    $State = @{}
    foreach ($Name in @('a', 'b')) {
        $Left = Join-Path $TestDir "$Name-left"
        $Right = Join-Path $TestDir "$Name-right"
        foreach ($Dir in @($Left, $Right)) {
            [void][IO.Directory]::CreateDirectory($Dir)
            [IO.File]::WriteAllText((Join-Path $Dir $CheckFileName), '')
            [IO.File]::SetLastWriteTimeUtc((Join-Path $Dir $CheckFileName), [datetime]'2026-01-01T00:00:00Z')
        }
        [IO.File]::WriteAllText((Join-Path $Left 'seed.txt'), "seed-$Name")
        $Pairs[$Name] = @{ Local = $Left; Remote = $Right }
        $State[$Name] = New-PairState
    }
    Update-PairFilterBlocks
    Assert-True ($State.a.Blocked -and $State.b.Blocked) 'Unknown baselines must not silently sync.'
    foreach ($Name in @('a', 'b')) {
        $Dry = Invoke-BisyncInit -LocalPath $Pairs[$Name].Local -RemotePath $Pairs[$Name].Remote -ResyncMode path1 -PairName $Name -DryRun
        Assert-True $Dry.Success "Local dry-run failed: $($Dry.Output)"
        Assert-True (-not $script:FiltersBaselines.Contains($Name)) 'Dry-run must not record a baseline.'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $Pairs[$Name].Remote 'seed.txt'))) 'Dry-run must not copy data.'
        $Init = Invoke-BisyncInit -LocalPath $Pairs[$Name].Local -RemotePath $Pairs[$Name].Remote -ResyncMode path1 -PairName $Name -ExpectedFiltersHash $Dry.FiltersHash
        Assert-True $Init.Success "Local resync failed: $($Init.Output)"
        Assert-True ((Get-PairFilterStatus -Name $Name) -eq 'Current') 'Successful resync records only its pair.'
        Reset-PairBlock -State $State[$Name]
    }
    Assert-True ((Get-FiltersBaselines -Path $FiltersBaselineFile).Count -eq 2) 'Both baselines persist.'
    [IO.File]::WriteAllText((Join-Path $Pairs.a.Local 'new.txt'), 'new file')
    Add-AllSyncRequests -Reason 'test'
    Start-DuePairSyncs
    Assert-True ($script:ActiveSyncJobs.Count -eq 1 -and $State.a.InProgress -and $script:SyncQueue.Contains('b')) 'Starting work returns without waiting, honors the cap and retains the queue.'
    Register-PairChange -State $State.a -Time (Get-Date)
    $script:HoldNewSyncs = $true
    Start-DuePairSyncs
    Assert-True ($script:ActiveSyncJobs.Count -eq 1) 'A pending UI flow prevents new starts.'
    $Deadline = (Get-Date).AddSeconds(30)
    while ($script:ActiveSyncJobs.Count -gt 0 -and (Get-Date) -lt $Deadline) {
        Receive-FinishedSyncs
        Start-Sleep -Milliseconds 30
    }
    Assert-True ($script:ActiveSyncJobs.Count -eq 0 -and $State.a.Dirty) 'Completion preserves changes made while syncing.'
    Assert-True (Test-Path -LiteralPath (Join-Path $Pairs.a.Remote 'new.txt')) 'The actual local sync copied the new file.'
    $script:HoldNewSyncs = $false
    Start-DuePairSyncs
    Assert-True $State.b.InProgress 'The waiting pair gets the freed slot before a follow-up change.'
    $script:ExitRequested = $true
    Start-DuePairSyncs
    Assert-True (-not $State.a.InProgress) 'Exit prevents queued/follow-up work from starting.'
    $Deadline = (Get-Date).AddSeconds(30)
    while ($script:ActiveSyncJobs.Count -gt 0 -and (Get-Date) -lt $Deadline) {
        Receive-FinishedSyncs
        Start-Sleep -Milliseconds 30
    }
    Assert-True ($script:ActiveSyncJobs.Count -eq 0) 'Active work can drain on exit.'
    $script:ExitRequested = $false
    $OldHash = $script:FiltersHash
    [IO.File]::WriteAllText($FiltersFile, "- *.tmp`n- *.bak`n")
    $script:FilterBlockCheckDue = $true
    Update-PairFilterBlocks
    Assert-True ($State.a.Blocked -and $State.b.Blocked) 'A filter edit blocks each stale pair.'
    $Rejected = $false
    try { Invoke-BisyncInit -LocalPath $Pairs.a.Local -RemotePath $Pairs.a.Remote -ResyncMode path1 -PairName a -ExpectedFiltersHash $OldHash | Out-Null }
    catch { $Rejected = $true }
    Assert-True $Rejected 'Changing filters after preview refuses the actual run.'
    $Init = Invoke-BisyncInit -LocalPath $Pairs.a.Local -RemotePath $Pairs.a.Remote -ResyncMode path1 -PairName a
    Assert-True $Init.Success "Second resync failed: $($Init.Output)"
    Assert-True ((Get-PairFilterStatus a) -eq 'Current' -and (Get-PairFilterStatus b) -eq 'Stale') 'Resyncing one pair must not certify another.'
    Reset-PairBlock -State $State.a
    # Missing filters halt starts, then resume checks after restoration.
    $SavedFilters = [IO.File]::ReadAllText($FiltersFile)
    Remove-Item -LiteralPath $FiltersFile
    $script:FilterBlockCheckDue = $true
    Start-DuePairSyncs
    Assert-True ($null -ne $script:FiltersReadError -and $script:ActiveSyncJobs.Count -eq 0) 'Unreadable filters stop new work.'
    [IO.File]::WriteAllText($FiltersFile, $SavedFilters)
    $script:FilterBlockCheckDue = $true
    Update-PairFilterBlocks
    Assert-True ($null -eq $script:FiltersReadError) 'Restored filters recover without restarting.'
    # Exercise the real persistent WinForms wizard offscreen. All Resync
    # operations still use the isolated local rclone fixtures above.
    [IO.File]::WriteAllBytes((Join-Path $Pairs.b.Local 'live-progress.bin'), [byte[]]::new(512KB))
    $CommonArguments += @('--bwlimit', '128k')
    $script:WizardScenario = 'SelectCancel'
    $script:ProgressUpdates = 0
    $script:SawTransferPercentage = $false
    $script:RealProgressUpdate = (Get-Command Update-ResyncWizardProgress).ScriptBlock
    function Update-ResyncWizardProgress {
        param($Wizard, $Update)
        & $script:RealProgressUpdate -Wizard $Wizard -Update $Update
        $script:ProgressUpdates++
        if ($Wizard.Session.Phase -eq 'SyncRunning' -and $null -ne $Update.Percent -and $Update.Percent -gt 0 -and $Update.Percent -lt 100) {
            $script:SawTransferPercentage = $true
            Assert-True ($Wizard.Progress.Style -eq [Windows.Forms.ProgressBarStyle]::Continuous -and $Wizard.Progress.Value -eq $Update.Percent) 'Real transfer percentages update the progress bar before completion.'
        }
        Assert-True ($Wizard.Form.Visible -and $Wizard.Session.Busy) 'The same wizard must stay visible throughout a running operation.'
        Assert-True (-not $Wizard.Next.Enabled -and -not $Wizard.Back.Enabled -and -not $Wizard.Close.Enabled) 'Navigation is disabled while rclone is running.'
        $Wizard.Form.Close()
        Assert-True ($Wizard.Form.Visible -and -not $Wizard.Form.IsDisposed) 'Closing a running wizard must not hide or abandon rclone.'
        Assert-True ([Windows.Forms.Application]::OpenForms.Count -eq 1) 'No extra confirmation or progress windows may appear.'
    }
    function Show-ResyncWizard {
        param($PairNames, $PairInfo, $PrepareAction, $RunAction, $CompleteAction)
        $Wizard = New-ResyncWizard @PSBoundParameters
        try {
            $Wizard.Form.StartPosition = [Windows.Forms.FormStartPosition]::Manual
            $Wizard.Form.Location = [Drawing.Point]::new(-32000, -32000)
            $Wizard.Form.ShowInTaskbar = $false
            $Wizard.Form.Show()
            [Windows.Forms.Application]::DoEvents()
            $OriginalHandle = $Wizard.Form.Handle
            Assert-True ($Wizard.Close.Bottom -le $Wizard.Close.Parent.ClientSize.Height) 'Footer buttons stay within the visible window.'
            $LastInfoPosition = $Wizard.Info.GetPositionFromCharIndex($Wizard.Info.TextLength - 1)
            # ClientSize already excludes the horizontal scrollbar.
            Assert-True ($LastInfoPosition.Y + $Wizard.Info.Font.Height -le $Wizard.Info.ClientSize.Height) 'Both paths, state and baseline remain visible without scrolling.'
            Assert-True ($Wizard.Next.DialogResult -eq [Windows.Forms.DialogResult]::None) 'Next must not dismiss the form.'
            if ($script:WizardScenario -eq 'SelectCancel') { $Wizard.Close.PerformClick(); return }
            $Wizard.Next.PerformClick()
            if ($script:WizardScenario -eq 'MarkerFailure') {
                Assert-True ($Wizard.Session.Phase -eq 'Failed' -and $Wizard.Form.Visible) 'A missing marker must leave the error in the same open window.'
                Assert-True ($Wizard.Log.Text.Contains('缺少安全標記') -and $Wizard.Close.Enabled) 'The error remains readable and the idle form can close.'
                return
            }
            Assert-True ($Wizard.Session.Phase -eq 'Review' -and $Wizard.Form.Handle -eq $OriginalHandle) 'Preview transitions to review without replacing the window.'
            Assert-True ($Wizard.Log.Text.Contains('預覽完成') -and $Wizard.Next.Enabled -and $Wizard.Back.Enabled) 'The preview and confirmation button stay available together.'
            if ($script:WizardScenario -eq 'ReviewCancel') { $Wizard.Close.PerformClick(); return }
            if ($script:WizardScenario -eq 'ChangedFilters') { [IO.File]::AppendAllText($FiltersFile, "- *.different`n") }
            $Wizard.Next.PerformClick()
            if ($script:WizardScenario -eq 'ChangedFilters') {
                Assert-True ($Wizard.Session.Phase -eq 'Failed' -and $State[$Wizard.Session.Selection.Name].Blocked) 'Changing filters after preview fails in place and keeps the pair blocked.'
                Assert-True ($Wizard.Form.Visible -and $Wizard.Log.Text.Contains('Filters changed after the preview')) 'Failure keeps the full reason visible.'
                return
            }
            Assert-True ($Wizard.Session.Phase -eq 'Completed' -and $Wizard.Form.Visible) 'Success must remain visible until the user closes or continues.'
            Assert-True ($Wizard.Progress.Value -eq 100 -and -not $State[$Wizard.Session.Selection.Name].Blocked) 'Only completed Resync restores synchronization.'
            Assert-True ($Wizard.Info.Text.Contains('可以正常同步') -and $Wizard.Info.Text.Contains('符合目前的過濾規則')) 'Pair information reflects the completed baseline instead of stale blocked status.'
            Assert-True ($Wizard.Form.Handle -eq $OriginalHandle) 'Selection, preview, confirmation and completion use one form.'
            $Wizard.Next.PerformClick()
            Assert-True ($Wizard.Session.Phase -eq 'Select' -and $Wizard.Form.Visible) 'Another pair can be selected in the same window.'
        }
        finally { $Wizard.Form.Dispose() }
    }
    $SavedBaseline = [IO.File]::ReadAllText($FiltersBaselineFile)
    Invoke-ResyncPairFlow
    Assert-True ($script:ProgressUpdates -eq 0) 'Canceling selection starts no preview.'
    $script:WizardScenario = 'ReviewCancel'
    Invoke-ResyncPairFlow
    Assert-True ([IO.File]::ReadAllText($FiltersBaselineFile) -ceq $SavedBaseline) 'Canceling preview does not record a new baseline.'
    $script:WizardScenario = 'Complete'
    Invoke-ResyncPairFlow
    Assert-True ($script:ProgressUpdates -ge 6) 'Both preview and actual Resync provide live updates.'
    Assert-True $script:SawTransferPercentage 'Real rclone transfer progress is displayed while it is still running.'
    $Marker = Join-Path $Pairs.a.Local $CheckFileName
    Set-PairBlocked -State $State.a -Kind Marker -Reason 'test'
    Remove-Item -LiteralPath $Marker
    $script:WizardScenario = 'MarkerFailure'
    Invoke-ResyncPairFlow
    [IO.File]::WriteAllText($Marker, '')
    [IO.File]::SetLastWriteTimeUtc($Marker, [datetime]'2026-01-01T00:00:00Z')
    $script:WizardScenario = 'ChangedFilters'
    Invoke-ResyncPairFlow
    Assert-True (-not $State.a.InProgress) 'An unsuccessful Resync always releases the in-progress state.'
    # A failed baseline write must not certify an unrecorded hash in memory.
    $PreviousFile = $FiltersBaselineFile
    $FiltersBaselineFile = $TestDir
    $Before = $script:FiltersBaselines.a.FiltersHash
    [IO.File]::WriteAllText($FiltersFile, "- *.tmp`n- *.bak`n- *.cache`n")
    $Init = Invoke-BisyncInit -LocalPath $Pairs.a.Local -RemotePath $Pairs.a.Remote -ResyncMode path1 -PairName a
    Assert-True (-not $Init.Success -and $script:FiltersBaselines.a.FiltersHash -eq $Before) 'Failed persistence must not update the in-memory baseline.'
    $FiltersBaselineFile = $PreviousFile
    # UI property writes are skipped for unchanged status (including the same countdown second).
    $script:TrayIcon = [pscustomobject]@{ Text = ''; Icon = $null }
    $script:TrayStatusItem = [pscustomobject]@{ Text = '' }
    $script:LastTrayStatus = $null; $script:LastTrayState = $null; $script:IconCalls = 0
    function Get-StateIcon { param($State) $script:IconCalls++; return $State }
    Set-TrayStatus -Status 'Watching'
    Set-TrayStatus -Status 'Watching'
    Assert-True ($script:IconCalls -eq 1) 'Identical tray states do not rewrite properties.'
    Set-TrayStatus -Status 'Retry pending: a (1s)' -State Warning
    Assert-True ($script:IconCalls -eq 2) 'Changed countdown/status is rendered.'
    Write-Output "Passed $script:Assertions integration assertions (isolated local rclone, no cloud)."
}
finally {
    foreach ($Job in @($script:ActiveSyncJobs.ToArray())) {
        if (-not $Job.Process.HasExited) { $Job.Process.Kill() ; $Job.Process.WaitForExit() }
        $Job.Process.Dispose()
    }
    $Resolved = [IO.Path]::GetFullPath($TestDir)
    if ($Resolved.StartsWith($TempRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $Resolved) -match '^watch-sync-integration-[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $Resolved -Recurse -Force
    }
    else { throw 'Refusing cleanup outside the generated test directory.' }
}
