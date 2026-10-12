#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepoDir = Split-Path -Parent $PSScriptRoot
. (Join-Path $RepoDir 'watch-sync-maintenance.ps1')
$script:Assertions = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:Assertions++
}
function New-FixtureFile {
    param([string]$Path, [string]$Text = 'fixture')
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}
$TempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
$TestDir = Join-Path $TempRoot ('watch-sync-tests-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($TestDir)
try {
    foreach ($Script in (Get-ChildItem -LiteralPath $RepoDir -Filter '*.ps1' -File)) {
        $Tokens = $null; $ParseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($Script.FullName, [ref]$Tokens, [ref]$ParseErrors)
        Assert-True ($ParseErrors.Count -eq 0) "Syntax errors in $($Script.Name): $ParseErrors"
    }
    [void](Import-PowerShellDataFile -LiteralPath (Join-Path $RepoDir 'config.example.psd1'))

    $Fixture = Join-Path $TestDir 'files'
    $Ignored = @(
        'Thumbs.db', 'nested/desktop.ini', 'nested/ehthumbs.db', 'nested/.DS_Store', 'nested/._image.jpg',
        '.Spotlight-V100/index', 'nested/.Trashes/trash', 'nested/.fseventsd/index',
        'nested/~$draft.docx', 'nested/.~lock.draft.odt#', 'draft.tmp', 'draft.Tmp', 'nested/draft.TMP',
        'nested/.draft.swp', 'nested/.draft.swo', 'nested/file.crdownload', 'nested/file.part',
        '.dropbox', 'nested/.dropbox.attr', 'nested/.dropbox.cache/staging',
        '.venv/pyvenv.cfg', 'nested/.venv/Lib/package.py', 'nested/__pycache__/module.pyc',
        'nested/.pytest_cache/results', 'nested/.mypy_cache/results', 'nested/.ruff_cache/results'
    )
    $Kept = @(
        '.rclone-bisync-check', '.git/config', '.gitignore', '.obsidian/workspace.json',
        'analysis/run.log', 'archive.bak', 'requirements.lock', 'package-lock.json',
        'notes/.venv-notes.md', 'nested/module.py', 'nested/file[1].pdf', 'report.pdf', 'photos/photo.jpg'
    )
    foreach ($Path in ($Ignored + $Kept)) { New-FixtureFile -Path (Join-Path $Fixture $Path) }
    $FilterFile = Join-Path $RepoDir 'watch-sync.filters'
    $WatcherFilters = Get-WatchSyncWatcherFilters -FiltersFile $FilterFile
    $Listed = @(& rclone lsf $Fixture --recursive --files-only --filter-from $FilterFile)
    Assert-True ($LASTEXITCODE -eq 0) 'rclone failed to validate local filters.'
    foreach ($Path in $Ignored) {
        Assert-True ($Path -notin $Listed) "rclone did not exclude $Path"
        Assert-True (Test-WatchSyncIgnoredPath -FullPath (Join-Path $Fixture $Path) -LocalRoot $Fixture -Filters $WatcherFilters) "Watcher did not exclude $Path"
    }
    foreach ($Path in $Kept) {
        Assert-True ($Path -in $Listed) "rclone excluded useful data: $Path"
        Assert-True (-not (Test-WatchSyncIgnoredPath -FullPath (Join-Path $Fixture $Path) -LocalRoot $Fixture -Filters $WatcherFilters)) "Watcher ignored useful data: $Path"
    }
    Assert-True (-not (Test-WatchSyncIgnoredPath -FullPath $null -LocalRoot $Fixture -Filters $WatcherFilters)) 'Missing event paths must remain visible.'
    Assert-True (-not (Test-WatchSyncIgnoredPath -FullPath (Join-Path $TestDir '.venv/outside') -LocalRoot $Fixture -Filters $WatcherFilters)) 'Ignore rules must stay inside the sync root.'
    $IncludeFilters = Join-Path $TestDir 'include.filters'
    New-FixtureFile -Path $IncludeFilters -Text "+ important.tmp`n- *.tmp`n"
    $MixedRules = Get-WatchSyncWatcherFilters -FiltersFile $IncludeFilters
    Assert-True ($MixedRules.Files.Count -eq 0) 'Include rules require the safe watcher fallback.'
    Assert-True ((Get-WatchSyncPairLogFile -LogDir $TestDir -PairName 'a/b') -ne (Get-WatchSyncPairLogFile -LogDir $TestDir -PairName 'a?b')) 'Sanitized pair names must not share log files.'

    $Logs = Join-Path $TestDir 'logs'
    $Current = Get-WatchSyncSummaryLogFile -LogDir $Logs -MaxFileMiB 1
    $Text = ('近期資訊 unchanged' + "`n") * 100000
    New-FixtureFile -Path $Current -Text $Text
    [void](Get-WatchSyncSummaryLogFile -LogDir $Logs -MaxFileMiB 1)
    Assert-True (-not (Test-Path -LiteralPath $Current)) 'A full summary log must rotate before the next write.'
    New-FixtureFile -Path $Current -Text 'current'
    $Archive = @(Get-ChildItem -LiteralPath $Logs -File | Where-Object { $_.FullName -ne $Current })[0]
    $Expired = Join-Path $Logs 'watch-sync-2000-01.log'
    New-FixtureFile -Path $Expired
    [IO.File]::SetLastWriteTimeUtc($Expired, [DateTime]::UtcNow.AddDays(-31))
    $Unknown = Join-Path $Logs 'research.log'
    New-FixtureFile -Path $Unknown -Text 'do not remove'
    [IO.File]::SetLastWriteTimeUtc($Unknown, [DateTime]::UtcNow.AddDays(-100))
    $NestedLog = Join-Path $Logs 'nested/watch-sync-2000-01.log'
    New-FixtureFile -Path $NestedLog
    [IO.File]::SetLastWriteTimeUtc($NestedLog, [DateTime]::UtcNow.AddDays(-100))
    $Result = Invoke-WatchSyncLogMaintenance -LogDir $Logs -RetentionDays 30 -MaxTotalMiB 10 -ProtectedPaths @($Current)
    Assert-True ($Result.Deleted -eq 1) 'Only the expired managed log should be deleted.'
    Assert-True ($Result.Compressed -eq 1) 'The rotated recent log should be compressed.'
    Assert-True (Test-Path -LiteralPath $Current) 'Current logs must be protected.'
    Assert-True (Test-Path -LiteralPath $Unknown) 'Unrecognized log files must be preserved.'
    Assert-True (Test-Path -LiteralPath $NestedLog) 'Maintenance must not recurse into subdirectories.'
    $InputStream = [IO.File]::OpenRead($Archive.FullName + '.gz')
    $Gzip = [IO.Compression.GZipStream]::new($InputStream, [IO.Compression.CompressionMode]::Decompress)
    $Reader = [IO.StreamReader]::new($Gzip, [Text.Encoding]::UTF8)
    try { Assert-True ($Reader.ReadToEnd() -ceq $Text) 'Compressed logs must preserve every byte of recent information.' }
    finally { $Reader.Dispose(); $Gzip.Dispose(); $InputStream.Dispose() }

    $Locked = Join-Path $Logs 'watch-sync-2001-01.log'
    New-FixtureFile -Path $Locked
    $Writer = [IO.File]::Open($Locked, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
    try { Assert-True (-not (Compress-WatchSyncLog -File (Get-Item -LiteralPath $Locked) -WarningAction SilentlyContinue)) 'Logs with a writer must not be compressed.' }
    finally { $Writer.Dispose() }
    Assert-True (Test-Path -LiteralPath $Locked) 'Failed compression must keep the original.'
    Assert-True (-not (Test-Path -LiteralPath ($Locked + '.gz'))) 'Failed compression must not leave a corrupt archive.'

    $CapacityLogs = Join-Path $TestDir 'capacity-logs'
    [void][IO.Directory]::CreateDirectory($CapacityLogs)
    $CapacityCurrent = Get-WatchSyncSummaryLogFile -LogDir $CapacityLogs
    New-FixtureFile -Path $CapacityCurrent -Text 'protected'
    for ($Index = 1; $Index -le 3; $Index++) {
        $Path = Join-Path $CapacityLogs ("watch-sync-2026-01-0$Index.log.gz")
        [IO.File]::WriteAllBytes($Path, [byte[]]::new(400KB))
        [IO.File]::SetLastWriteTimeUtc($Path, [DateTime]::UtcNow.AddDays(-4 + $Index))
    }
    $Result = Invoke-WatchSyncLogMaintenance -LogDir $CapacityLogs -MaxTotalMiB 1 -ProtectedPaths @($CapacityCurrent)
    Assert-True ($Result.TotalBytes -le 1MB) 'Maintenance must enforce the total capacity target.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $CapacityLogs 'watch-sync-2026-01-01.log.gz'))) 'Capacity cleanup must remove the oldest log first.'
    Assert-True (Test-Path -LiteralPath (Join-Path $CapacityLogs 'watch-sync-2026-01-03.log.gz')) 'Capacity cleanup must preserve the newest log.'

    $State = Join-Path $TestDir 'state'
    foreach ($Name in @('pair.path1.lst', 'pair.path1.lst-old', 'pair.path1.lst-new', 'pair.path1.lst-dry', 'pair.path2.lst-dry-old', 'pair.path1.lst-dry-err', 'pair.lck', 'filters.md5')) {
        $Path = Join-Path $State $Name
        New-FixtureFile -Path $Path
        [IO.File]::SetLastWriteTimeUtc($Path, [DateTime]::UtcNow.AddDays(-60))
    }
    Assert-True ((Remove-WatchSyncOldPreviews -StateDir $State) -eq 0) 'Any bisync lock must defer preview cleanup.'
    Remove-Item -LiteralPath (Join-Path $State 'pair.lck')
    New-FixtureFile -Path (Join-Path $State 'recent.path1.lst-dry')
    Assert-True ((Remove-WatchSyncOldPreviews -StateDir $State) -eq 3) 'Only the three old dry-run listings should be removed.'
    foreach ($Name in @('pair.path1.lst', 'pair.path1.lst-old', 'pair.path1.lst-new', 'filters.md5', 'recent.path1.lst-dry')) {
        Assert-True (Test-Path -LiteralPath (Join-Path $State $Name)) "Recovery or recent state was removed: $Name"
    }
    Write-Output "Passed $script:Assertions assertions (including real rclone filtering and gzip round-trip)."
}
finally {
    $ResolvedTestDir = [IO.Path]::GetFullPath($TestDir)
    if ($ResolvedTestDir.StartsWith($TempRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $ResolvedTestDir) -match '^watch-sync-tests-[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $ResolvedTestDir -Recurse -Force
    }
    else { throw 'Refusing cleanup outside the generated test directory.' }
}
