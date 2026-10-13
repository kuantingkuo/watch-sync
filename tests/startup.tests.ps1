#Requires -Version 7.0
[CmdletBinding()]
param([string]$ConfigPath)
# Exercise the actual startup settings block without running the UI or syncing.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepoDir = Split-Path -Parent $PSScriptRoot
. (Join-Path $RepoDir 'watch-sync-core.ps1')
$Tokens = $null; $ParseErrors = $null
$Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoDir 'watch-sync-tray.ps1'), [ref]$Tokens, [ref]$ParseErrors)
if ($ParseErrors.Count) { throw ($ParseErrors -join "`n") }
$SettingsStart = $null
$SettingsEnd = $null
foreach ($Statement in $Ast.EndBlock.Statements) {
    if ($Statement -isnot [System.Management.Automation.Language.AssignmentStatementAst] -or
        $Statement.Left -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
    $Name = $Statement.Left.VariablePath.UserPath
    if ($script:WatchSyncSettingTypes.Contains($Name)) {
        . ([scriptblock]::Create($Statement.Extent.Text))
    }
    if ($Name -eq 'Defaults') { $SettingsStart = $Statement.Extent.StartOffset }
    if ($Name -eq 'script:TrayIcon') { $SettingsEnd = $Statement.Extent.StartOffset; break }
}
if ($null -eq $SettingsStart -or $null -eq $SettingsEnd) { throw 'Startup settings block not found.' }
$StartupBlock = [scriptblock]::Create($Ast.Extent.Text.Substring($SettingsStart, $SettingsEnd - $SettingsStart))
function Show-FatalStartupError {
    param([string]$Message)
    throw "Startup failed: $Message"
}
function Write-Log { param($Message, $Level = 'INFO') Write-Debug "$Level`: $Message" }
$script:Assertions = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:Assertions++
}
function Invoke-StartupSettings {
    param([hashtable]$Config)
    $script:LocalConfig = $Config
    . $StartupBlock
    return [pscustomobject]@{
        ErrorCount = $SettingErrors.Count
        QuietSeconds = $QuietSeconds
        EnableTrayIcon = $EnableTrayIcon
    }
}
$Example = Import-PowerShellDataFile -LiteralPath (Join-Path $RepoDir 'config.example.psd1')
$Result = Invoke-StartupSettings -Config $Example
Assert-True ($Result.ErrorCount -eq 0) 'The example configuration must start without false errors.'
$Result = Invoke-StartupSettings -Config @{ Pairs = @{} }
Assert-True ($Result.ErrorCount -eq 0) 'Missing optional Settings must start without false errors.'
$Result = Invoke-StartupSettings -Config @{ Settings = @{ QuietSeconds = '45'; EnableTrayIcon = $false } }
Assert-True ($Result.ErrorCount -eq 0 -and $Result.QuietSeconds -eq 45 -and -not $Result.EnableTrayIcon) 'Valid overrides must be applied without false errors.'
foreach ($Config in @(
    @{ Settings = @{ MaxParallelSyncs = 0 } },
    @{ Settings = @{ Transfers = 'invalid'; RetryDelaySeconds = 0 } },
    @{ Settings = 'invalid' }
)) {
    $Failure = $null
    try { Invoke-StartupSettings -Config $Config | Out-Null }
    catch { $Failure = $_.Exception.Message }
    Assert-True ($null -ne $Failure -and $Failure.StartsWith('Startup failed:')) 'Invalid settings must stop startup with a message.'
    Assert-True ($Failure -notmatch 'System\.Object\[\]') 'Startup errors must show messages instead of an array type name.'
}
Write-Output "Passed $script:Assertions startup assertions (actual startup settings block, no UI or cloud)."
if ($ConfigPath) {
    $Local = Import-PowerShellDataFile -LiteralPath $ConfigPath
    $Result = Invoke-StartupSettings -Config $Local
    Assert-True ($Result.ErrorCount -eq 0) 'Local configuration must pass startup settings validation.'
    Write-Output 'Local configuration startup settings passed.'
}
