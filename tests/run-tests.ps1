#Requires -Version 7.0
[CmdletBinding()]
param([switch]$Analyze)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepoDir = Split-Path -Parent $PSScriptRoot
foreach ($Name in @('core.tests.ps1', 'startup.tests.ps1', 'resync-progress.tests.ps1', 'maintenance.tests.ps1', 'integration.tests.ps1')) {
    & pwsh -NoProfile -STA -File (Join-Path $PSScriptRoot $Name)
    if ($LASTEXITCODE -ne 0) { throw "$Name failed with exit $LASTEXITCODE" }
}
if ($Analyze) {
    Import-Module PSScriptAnalyzer -RequiredVersion 1.24.0 -ErrorAction Stop
    $Findings = @(Invoke-ScriptAnalyzer -Path $RepoDir -Recurse -Settings (Join-Path $RepoDir 'PSScriptAnalyzerSettings.psd1'))
    if ($Findings.Count) { $Findings | Format-Table -AutoSize; throw 'Script analysis failed.' }
    Write-Output 'Script analysis passed.'
}
