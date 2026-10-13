#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'watch-sync-resync.ps1')
$script:Assertions = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:Assertions++
}
$Progress = Get-BisyncProgress -LogText '2026/10/14 10:00:00 INFO  : 5 MiB / 10 MiB, 50%, 1 MiB/s, ETA 5s'
Assert-True ($Progress.Percent -eq 50 -and $Progress.TransferText.Contains('ETA 5s')) 'Real transfer statistics expose percentage, rate and ETA.'
$Progress = Get-BisyncProgress -LogText "2026/10/14 10:00:00 INFO  : 10 MiB / 10 MiB, 100%, 1 MiB/s, ETA 0s`n2026/10/14 10:00:01 INFO  : Validating listings for Path1"
Assert-True ($null -eq $Progress.Percent -and $Progress.Description.Contains('檢查同步結果')) 'Transfer completion must not masquerade as overall completion.'
$Progress = Get-BisyncProgress -LogText '2026/10/14 10:00:00 INFO  : Checking access health'
Assert-True ($null -eq $Progress.Percent -and $Progress.Description.Contains('安全標記')) 'Unknown totals use activity indication and a concrete stage.'
$Progress = Get-BisyncProgress -LogText ''
Assert-True ($null -eq $Progress.Percent) 'No log data does not invent a percentage.'
$TempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
$TestDir = Join-Path $TempRoot ('watch-sync-progress-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($TestDir)
try {
    $Path = Join-Path $TestDir 'live.log'
    Assert-True ((Get-BisyncLogUpdate -Path $Path).Text -eq '') 'A not-yet-created log is handled without an error.'
    [IO.File]::WriteAllText($Path, "first`n", [Text.UTF8Encoding]::new($false))
    $First = Get-BisyncLogUpdate -Path $Path
    Assert-True ($First.Text -eq "first`n") 'The first log chunk is read.'
    [IO.File]::AppendAllText($Path, "second`n", [Text.UTF8Encoding]::new($false))
    $Second = Get-BisyncLogUpdate -Path $Path -Offset $First.Offset
    Assert-True ($Second.Text -eq "second`n") 'Incremental reads do not repeat previous log entries.'
    Assert-True ((Get-BisyncLogUpdate -Path $Path -Offset $Second.Offset).Text -eq '') 'Polling without new data produces no duplicate text.'
    [IO.File]::WriteAllText($Path, "new`n", [Text.UTF8Encoding]::new($false))
    Assert-True ((Get-BisyncLogUpdate -Path $Path -Offset $Second.Offset).Text -eq "new`n") 'A shorter rotated log resets the offset.'
    $Lock = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { Assert-True ((Get-BisyncLogUpdate -Path $Path).Text -eq '') 'A temporarily locked log does not interrupt rclone.' }
    finally { $Lock.Dispose() }
    $Unicode = [Text.Encoding]::UTF8.GetBytes("中文檔名.txt`n")
    [IO.File]::WriteAllBytes($Path, [byte[]]$Unicode[0..1])
    $Partial = Get-BisyncLogUpdate -Path $Path
    Assert-True ($Partial.Text -eq '' -and $Partial.Offset -eq 0) 'Partial UTF-8 data is deferred until the full line arrives.'
    [IO.File]::WriteAllBytes($Path, $Unicode)
    Assert-True ((Get-BisyncLogUpdate -Path $Path -Offset $Partial.Offset).Text -eq "中文檔名.txt`n") 'Chinese filenames survive incremental reads.'
}
finally {
    $Resolved = [IO.Path]::GetFullPath($TestDir)
    if ($Resolved.StartsWith($TempRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $Resolved) -match '^watch-sync-progress-[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $Resolved -Recurse -Force
    }
    else { throw 'Refusing cleanup outside the generated test directory.' }
}
Write-Output "Passed $script:Assertions Resync progress assertions."
