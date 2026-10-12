# Helpers without tray/startup side effects, also used by the maintenance tests.

function Get-WatchSyncWatcherFilters {
    param([Parameter(Mandatory)][string]$FiltersFile)

    $Lines = @(Get-Content -LiteralPath $FiltersFile -Encoding UTF8)
    $Files = [System.Collections.Generic.List[object]]::new()
    $Directories = [System.Collections.Generic.List[object]]::new()
    # Include rules can override an exclusion. Fall back to watching everything.
    if (-not ($Lines | Where-Object { $_ -match '^\s*\+\s' })) {
        foreach ($Line in $Lines) {
            if ($Line -notmatch '^\s*-\s+(.+?)\s*$') { continue }
            $Pattern = $Matches[1]
            $IsDirectory = $Pattern.EndsWith('/**')
            if ($IsDirectory) { $Pattern = $Pattern.Substring(0, $Pattern.Length - 3) }
            # Only optimize basename rules; let rclone handle more complex filters.
            if ($Pattern.Contains('/') -or $Pattern.Contains('{{') -or $Pattern.Contains('`')) { continue }
            try {
                $Wildcard = [System.Management.Automation.WildcardPattern]::new($Pattern)
                if ($IsDirectory) { $Directories.Add($Wildcard) } else { $Files.Add($Wildcard) }
            }
            catch { continue }
        }
    }
    [pscustomobject]@{ Files = $Files.ToArray(); Directories = $Directories.ToArray() }
}

function Test-WatchSyncIgnoredPath {
    param(
        [AllowNull()][string]$FullPath,
        [Parameter(Mandatory)][string]$LocalRoot,
        [Parameter(Mandatory)][pscustomobject]$Filters
    )
    if ([string]::IsNullOrWhiteSpace($FullPath)) { return $false }
    $Relative = [IO.Path]::GetRelativePath($LocalRoot, $FullPath)
    if ($Relative -eq '.' -or $Relative -eq '..' -or $Relative -match '^\.\.[\\/]') { return $false }
    $Parts = $Relative -split '[\\/]'
    foreach ($Pattern in $Filters.Directories) {
        foreach ($Part in $Parts) { if ($Pattern.IsMatch($Part)) { return $true } }
    }
    foreach ($Pattern in $Filters.Files) {
        if ($Pattern.IsMatch($Parts[-1])) { return $true }
    }
    return $false
}

function Get-WatchSyncPairLogFile {
    param([Parameter(Mandatory)][string]$LogDir, [Parameter(Mandatory)][string]$PairName)
    $SafeName = ($PairName -replace '[^\p{L}\p{N}._-]', '_')
    if ($SafeName.Length -gt 64) { $SafeName = $SafeName.Substring(0, 64) }
    $Hasher = [Security.Cryptography.SHA256]::Create()
    try { $Hash = [BitConverter]::ToString($Hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($PairName))).Replace('-', '').Substring(0, 8).ToLowerInvariant() }
    finally { $Hasher.Dispose() }
    Join-Path $LogDir ('bisync-{0}-{1}-{2:yyyy-MM-dd}.log' -f $SafeName, $Hash, (Get-Date))
}

function Get-WatchSyncSummaryLogFile {
    param([Parameter(Mandatory)][string]$LogDir, [ValidateRange(1, 1024)][int]$MaxFileMiB = 10)
    $Path = Join-Path $LogDir ('watch-sync-{0:yyyy-MM-dd}.log' -f (Get-Date))
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $File = Get-Item -LiteralPath $Path
        if ($File.Length -ge $MaxFileMiB * 1MB -and -not ($File.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            try {
                $Archive = Join-Path $LogDir ('watch-sync-{0:yyyy-MM-dd.HHmmssfff}-{1}.log' -f (Get-Date), [Guid]::NewGuid().ToString('N').Substring(0, 8))
                Move-Item -LiteralPath $Path -Destination $Archive -ErrorAction Stop
            }
            catch { Write-Warning "Log rotation deferred: $($_.Exception.Message)" }
        }
    }
    return $Path
}

function Get-WatchSyncManagedLogFiles {
    param([Parameter(Mandatory)][string]$LogDir)
    $Directory = Get-Item -LiteralPath $LogDir -ErrorAction Stop
    if ($Directory.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Log directory must not be a junction or symbolic link.' }
    Get-ChildItem -LiteralPath $Directory.FullName -File | Where-Object {
        $_.DirectoryName -eq $Directory.FullName -and
        -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -and
        $_.Name -match '^(?:watch-sync-\d{4}-\d{2}(?:-\d{2})?(?:[.-].+)?|bisync-.+-\d{4}-\d{2}-\d{2}(?:-.+)?|init-\d{8}-\d{6}-[a-f0-9]{8}(?:-.+)?)\.log(?:\.gz)?$'
    }
}

function Compress-WatchSyncLog {
    param([Parameter(Mandatory)][IO.FileInfo]$File)
    $Destination = $File.FullName + '.gz'
    if (Test-Path -LiteralPath $Destination) { return $false }
    $Temporary = $Destination + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    $SourceStream = $null
    $DestinationStream = $null
    $Gzip = $null
    $OriginalTime = $File.LastWriteTimeUtc
    try {
        # Refuse to compress a file which still has a writer.
        $SourceStream = [IO.File]::Open($File.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $DestinationStream = [IO.File]::Open($Temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $Gzip = [IO.Compression.GZipStream]::new($DestinationStream, [IO.Compression.CompressionLevel]::Optimal)
        $SourceStream.CopyTo($Gzip)
        $Gzip.Dispose(); $Gzip = $null
        $DestinationStream.Dispose(); $DestinationStream = $null
        $SourceStream.Dispose(); $SourceStream = $null
        [IO.File]::SetLastWriteTimeUtc($Temporary, $OriginalTime)
        Move-Item -LiteralPath $Temporary -Destination $Destination -ErrorAction Stop
        Remove-Item -LiteralPath $File.FullName -ErrorAction Stop
        return $true
    }
    catch {
        Write-Warning "Log compression deferred for $($File.Name): $($_.Exception.Message)"
        return $false
    }
    finally {
        if ($null -ne $Gzip) { $Gzip.Dispose() }
        if ($null -ne $DestinationStream) { $DestinationStream.Dispose() }
        if ($null -ne $SourceStream) { $SourceStream.Dispose() }
        if (Test-Path -LiteralPath $Temporary) { Remove-Item -LiteralPath $Temporary -ErrorAction SilentlyContinue }
    }
}

function Invoke-WatchSyncLogMaintenance {
    param(
        [Parameter(Mandatory)][string]$LogDir,
        [ValidateRange(1, 3650)][int]$RetentionDays = 30,
        [ValidateRange(1, 1048576)][int]$MaxTotalMiB = 200,
        [string[]]$ProtectedPaths = @()
    )
    $Protected = @($ProtectedPaths | ForEach-Object { [IO.Path]::GetFullPath($_) })
    $Files = @(Get-WatchSyncManagedLogFiles -LogDir $LogDir)
    $Before = ($Files | Measure-Object Length -Sum).Sum
    $Deleted = 0
    $Compressed = 0
    $Cutoff = [DateTime]::UtcNow.AddDays(-$RetentionDays)
    foreach ($File in $Files) {
        if ($File.FullName -in $Protected) { continue }
        try {
            if ($File.LastWriteTimeUtc -lt $Cutoff) {
                Remove-Item -LiteralPath $File.FullName -ErrorAction Stop
                $Deleted++
            }
            elseif ($File.Extension -eq '.log' -and ($File.Name -notlike 'init-*' -or $File.LastWriteTimeUtc -lt [DateTime]::UtcNow.AddDays(-1))) {
                if (Compress-WatchSyncLog -File $File) { $Compressed++ }
            }
        }
        catch { Write-Warning "Log cleanup deferred for $($File.Name): $($_.Exception.Message)" }
    }
    $Files = @(Get-WatchSyncManagedLogFiles -LogDir $LogDir)
    $Total = ($Files | Measure-Object Length -Sum).Sum
    foreach ($File in ($Files | Sort-Object LastWriteTimeUtc, Name)) {
        if ($Total -le $MaxTotalMiB * 1MB) { break }
        if ($File.FullName -in $Protected) { continue }
        try {
            Remove-Item -LiteralPath $File.FullName -ErrorAction Stop
            $Total -= $File.Length
            $Deleted++
        }
        catch { Write-Warning "Log cleanup deferred for $($File.Name): $($_.Exception.Message)" }
    }
    [pscustomobject]@{ Deleted = $Deleted; Compressed = $Compressed; FreedBytes = $Before - $Total; TotalBytes = $Total }
}

function Remove-WatchSyncOldPreviews {
    param([Parameter(Mandatory)][string]$StateDir, [ValidateRange(1, 3650)][int]$RetentionDays = 30)
    if (-not (Test-Path -LiteralPath $StateDir -PathType Container)) { return 0 }
    $Directory = Get-Item -LiteralPath $StateDir
    if ($Directory.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Bisync state directory must not be a junction or symbolic link.' }
    $Files = @(Get-ChildItem -LiteralPath $Directory.FullName -File)
    # Locks, current listings and recovery snapshots are never cleaned here.
    if ($Files | Where-Object { $_.Name -like '*.lck' }) { return 0 }
    $Deleted = 0
    foreach ($File in $Files) {
        if ($File.DirectoryName -eq $Directory.FullName -and
            -not ($File.Attributes -band [IO.FileAttributes]::ReparsePoint) -and
            $File.Name -match '\.path[12]\.lst-dry(?:-old|-err)?$' -and
            $File.LastWriteTimeUtc -lt [DateTime]::UtcNow.AddDays(-$RetentionDays)) {
            Remove-Item -LiteralPath $File.FullName -ErrorAction Stop
            $Deleted++
        }
    }
    return $Deleted
}
