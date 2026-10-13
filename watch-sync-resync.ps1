<#
.SYNOPSIS
    Persistent Resync wizard and live bisync progress helpers.
.DESCRIPTION
    One form stays open through selection, preview, confirmation, execution and
    completion. Operation callbacks keep filesystem/process logic in the tray
    application and allow the wizard to be tested with isolated local pairs.
#>

function Get-BisyncLogUpdate {
    param([Parameter(Mandatory)][string]$Path, [long]$Offset = 0)
    $Stream = $null
    $Buffer = $null
    try {
        $Stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        if ($Offset -gt $Stream.Length) { $Offset = 0 }
        [void]$Stream.Seek($Offset, [IO.SeekOrigin]::Begin)
        $Buffer = [IO.MemoryStream]::new()
        $Stream.CopyTo($Buffer)
        $Bytes = $Buffer.ToArray()
        # Read complete lines only: a concurrent write may split a UTF-8
        # filename between polls. Leave incomplete bytes for the next read.
        $LastNewline = $Bytes.Length - 1
        while ($LastNewline -ge 0 -and $Bytes[$LastNewline] -ne 10) { $LastNewline-- }
        $Length = $LastNewline + 1
        $Text = [Text.Encoding]::UTF8.GetString($Bytes, 0, $Length)
        if ($Offset -eq 0) { $Text = $Text.TrimStart([char]0xFEFF) }
        return [pscustomobject]@{ Text = $Text; Offset = $Offset + $Length }
    }
    catch [IO.IOException] { return [pscustomobject]@{ Text = ''; Offset = $Offset } }
    finally {
        if ($null -ne $Buffer) { $Buffer.Dispose() }
        if ($null -ne $Stream) { $Stream.Dispose() }
    }
}

function Get-BisyncProgress {
    param([AllowEmptyString()][string]$LogText = '')
    $Description = '正在讀取與比對檔案'
    $Percent = $null
    $TransferText = ''
    foreach ($Line in ($LogText -split '\r?\n')) {
        if ($Line -match 'Synching Path1|checking for diffs|Comparison Settings') {
            $Description = '正在讀取與比對兩邊的檔案'
            $Percent = $null
        }
        elseif ($Line -match 'Checking access health') {
            $Description = '正在檢查兩邊的安全標記'
            $Percent = $null
        }
        elseif ($Line -match 'Copying Path[12] files|Resync is copying|Copied \(') {
            $Description = '正在處理這一輪的檔案傳輸'
            $Percent = $null
        }
        elseif ($Line -match 'updating listings|Updating listings|Validating listings') {
            $Description = '正在更新 baseline 並檢查同步結果'
            $Percent = $null
        }
        # --stats-one-line reports bytes, percentage, rate and ETA. This is
        # transfer progress for the current pass, not overall bisync completion.
        if ($Line -match '(?<stats>\d+(?:\.\d+)?\s*[A-Za-z]+\s*/\s*\d+(?:\.\d+)?\s*[A-Za-z]+,\s*(?<percent>\d+(?:\.\d+)?)%,\s*.+?,\s*ETA\s+.+)$') {
            $TransferText = $Matches['stats'].Trim()
            if ($Description -notmatch '檢查同步結果') {
                $Percent = [int][math]::Min(100, [math]::Max(0, [double]::Parse($Matches['percent'], [Globalization.CultureInfo]::InvariantCulture)))
            }
        }
    }
    return [pscustomobject]@{ Description = $Description; Percent = $Percent; TransferText = $TransferText }
}

function Set-ResyncWizardView {
    param([Parameter(Mandatory)]$Wizard)
    $Session = $Wizard.Session
    $Phase = $Session.Phase
    $Busy = $Phase -in @('PreviewRunning', 'SyncRunning')
    $Session.Busy = $Busy
    $Wizard.Pair.Enabled = ($Phase -eq 'Select' -and $Wizard.Pair.Items.Count -gt 0)
    $Wizard.Mode.Enabled = ($Phase -eq 'Select')
    $Wizard.Back.Enabled = ($Phase -in @('Review', 'Failed'))
    $Wizard.Close.Enabled = -not $Busy
    $Wizard.Close.Text = if ($Busy) { '處理中…' } else { '關閉' }
    $Wizard.Next.Enabled = -not $Busy -and $Wizard.Pair.Items.Count -gt 0
    switch ($Phase) {
        'Select' {
            $Wizard.Steps.Text = '1 選擇配對  →  2 預覽  →  3 確認並執行  →  4 完成'
            $Wizard.Status.Text = '步驟 1 / 4：選擇配對與要保留的版本'
            $Wizard.Detail.Text = '先預覽，再確認執行 Resync。'
            $Wizard.Next.Text = '下一步：預覽'
        }
        'PreviewRunning' {
            $Wizard.Steps.Text = '1 選擇配對  →  【2 預覽中】  →  3 確認並執行  →  4 完成'
            $Wizard.Status.Text = "步驟 2 / 4：正在預覽 $($Session.Selection.Name)"
            $Wizard.Detail.Text = '正在啟動 rclone；預覽不會修改要同步的檔案。'
            $Wizard.Next.Text = '預覽中…'
        }
        'Review' {
            $Wizard.Steps.Text = '1 選擇配對  →  2 預覽完成  →  【3 等待確認】  →  4 完成'
            $Wizard.Status.Text = '步驟 3 / 4：預覽完成，請檢查下方紀錄'
            $Wizard.Detail.Text = "同名檔案內容不同時：$($Session.Selection.PreferenceLabel)。確認後才會修改檔案。"
            $Wizard.Next.Text = '確認並開始 Resync'
        }
        'SyncRunning' {
            $Wizard.Steps.Text = '1 選擇配對  →  2 預覽完成  →  【3 Resync 中】  →  4 完成'
            $Wizard.Status.Text = "步驟 3 / 4：正在執行 Resync — $($Session.Selection.Name)"
            $Wizard.Detail.Text = '正在啟動 rclone；請等待這次操作完成。'
            $Wizard.Next.Text = 'Resync 中…'
        }
        'Completed' {
            $Wizard.Steps.Text = '1 選擇配對  →  2 預覽完成  →  3 Resync 完成  →  【4 完成】'
            $Wizard.Status.Text = "步驟 4 / 4：$($Session.Selection.Name) 已完成 Resync"
            $Wizard.Detail.Text = '此配對會恢復正常同步。可以在同一個視窗處理下一組。'
            $Wizard.Next.Text = '選擇下一組配對'
        }
        'Failed' {
            $Wizard.Steps.Text = '操作失敗，視窗與執行紀錄會保留'
            $Wizard.Status.Text = if ($Session.FailedOperation -eq 'Sync') { 'Resync 未完成；此配對仍停止同步' } else { '預覽未完成；請檢查原因後再試一次' }
            $Wizard.Detail.Text = $Session.ErrorMessage
            $Wizard.Next.Text = '重新預覽'
        }
    }
    $Wizard.Progress.Style = if ($Busy) { [Windows.Forms.ProgressBarStyle]::Marquee } else { [Windows.Forms.ProgressBarStyle]::Continuous }
    $Wizard.Progress.MarqueeAnimationSpeed = if ($Busy) { 30 } else { 0 }
    $Wizard.Progress.Value = if ($Phase -in @('Review', 'Completed')) { 100 } else { 0 }
    if ($Wizard.Pair.Items.Count -eq 0) {
        $Wizard.Status.Text = '沒有可執行 Resync 的配對'
        $Wizard.Detail.Text = '請先新增同步資料夾。'
    }
}

function Add-ResyncWizardLog {
    param([Parameter(Mandatory)]$Wizard, [AllowEmptyString()][string]$Text)
    if (-not $Text) { return }
    $AtEnd = ($Wizard.Log.SelectionStart -ge [math]::Max(0, $Wizard.Log.TextLength - 2))
    $Wizard.Log.AppendText($Text)
    if ($Wizard.Log.TextLength -gt 150000) { $Wizard.Log.Text = $Wizard.Log.Text.Substring($Wizard.Log.TextLength - 120000) }
    if ($AtEnd) { $Wizard.Log.SelectionStart = $Wizard.Log.TextLength; $Wizard.Log.ScrollToCaret() }
}

function Update-ResyncWizardProgress {
    param([Parameter(Mandatory)]$Wizard, [Parameter(Mandatory)]$Update)
    if ($Wizard.Form.IsDisposed) { return }
    $Wizard.Session.LogFile = $Update.LogFile
    $Wizard.OpenLog.Enabled = Test-Path -LiteralPath $Update.LogFile -PathType Leaf
    Add-ResyncWizardLog -Wizard $Wizard -Text $Update.Text
    $Seconds = [int]$Update.ElapsedSeconds
    $Wizard.Detail.Text = "$($Update.Description) · 已執行 $($Seconds.ToString()) 秒"
    if ($Wizard.Session.Phase -eq 'SyncRunning' -and $null -ne $Update.Percent) {
        $Wizard.Progress.Style = [Windows.Forms.ProgressBarStyle]::Continuous
        $Wizard.Progress.Value = [int]$Update.Percent
        $Wizard.Detail.Text = "目前這一輪傳輸 $($Update.Percent)% · 已執行 $Seconds 秒 · $($Update.TransferText)"
    }
    else {
        $Wizard.Progress.Style = [Windows.Forms.ProgressBarStyle]::Marquee
        $Wizard.Progress.MarqueeAnimationSpeed = 30
    }
}

function Reset-ResyncWizard {
    param([Parameter(Mandatory)]$Wizard, [switch]$NextPair)
    if ($Wizard.Session.Busy) { return }
    $Wizard.Session.Phase = 'Select'
    $Wizard.Session.Selection = $null
    $Wizard.Session.Prepared = $null
    $Wizard.Session.Preview = $null
    $Wizard.Session.LogFile = ''
    $Wizard.Session.ErrorMessage = ''
    $Wizard.Log.Clear()
    $Wizard.OpenLog.Enabled = $false
    if ($NextPair -and $Wizard.Pair.Items.Count -gt 1) {
        $Wizard.Pair.SelectedIndex = ($Wizard.Pair.SelectedIndex + 1) % $Wizard.Pair.Items.Count
    }
    Set-ResyncWizardView -Wizard $Wizard
}

function Invoke-ResyncWizardStep {
    param([Parameter(Mandatory)]$Wizard)
    $Session = $Wizard.Session
    if ($Session.Busy -or $Wizard.Pair.Items.Count -eq 0) { return }
    if ($Session.Phase -eq 'Completed') { Reset-ResyncWizard -Wizard $Wizard -NextPair; return }
    if ($Session.Phase -eq 'Failed') { Reset-ResyncWizard -Wizard $Wizard }
    $IsPreview = ($Session.Phase -eq 'Select')
    if (-not $IsPreview -and $Session.Phase -ne 'Review') { return }
    try {
        if ($IsPreview) {
            $Mode = 'path1'; $Label = '保留本機版本（Local version wins）'
            if ($Wizard.RemoteWins.Checked) { $Mode = 'path2'; $Label = '保留雲端版本（Remote version wins）' }
            elseif ($Wizard.NewerWins.Checked) { $Mode = 'newer'; $Label = '保留較新的版本（Newer version wins）' }
            $Session.Selection = [pscustomobject]@{ Name = [string]$Wizard.Pair.SelectedItem; ResyncMode = $Mode; PreferenceLabel = $Label }
            $Session.Phase = 'PreviewRunning'
        }
        else { $Session.Phase = 'SyncRunning' }
        # Disable buttons before any message pumping to prevent re-entry.
        Set-ResyncWizardView -Wizard $Wizard
        $Session.Prepared = & $Wizard.PrepareAction $Session.Selection
        $ProgressAction = { param($Update) Update-ResyncWizardProgress -Wizard $Wizard -Update $Update }.GetNewClosure()
        $Hash = if ($IsPreview) { '' } else { $Session.Preview.FiltersHash }
        $Result = & $Wizard.RunAction $Session.Prepared $IsPreview $Hash $ProgressAction
        if (-not $Result.Success) { throw "exit $($Result.ExitCode)：$($Result.Output)" }
        if ($IsPreview) {
            $Session.Preview = $Result
            $Summary = Get-ResyncPreviewSummary -LogText $Result.Output
            $Lines = @("`r`n===== 預覽完成，等待你的確認 =====", "完整 log：$($Result.LogFile)")
            if ($Summary.Total -eq 0) { $Lines += '摘要未辨識到複製或刪除操作。請查看完整 log 後再確認。' }
            else {
                $Lines += "摘要辨識到 $($Summary.Total) 個操作："
                foreach ($Operation in $Summary.Counts.Keys) { $Lines += "  $Operation`: $($Summary.Counts[$Operation])" }
                if ($Summary.Deletes -gt 0) { $Lines += "注意：包含 $($Summary.Deletes) 個刪除操作。" }
                $Lines += $Summary.Samples
            }
            Add-ResyncWizardLog -Wizard $Wizard -Text (($Lines -join "`r`n") + "`r`n")
            $Session.Phase = 'Review'
        }
        else {
            $UpdatedInfo = & $Wizard.CompleteAction $Session.Prepared
            if (-not [string]::IsNullOrWhiteSpace([string]$UpdatedInfo)) {
                $Wizard.PairInfo[$Session.Selection.Name] = [string]$UpdatedInfo
                $Wizard.Info.Text = [string]$UpdatedInfo
            }
            $Session.Phase = 'Completed'
            Add-ResyncWizardLog -Wizard $Wizard -Text "`r`n===== Resync 完成，此配對已恢復同步 =====`r`n"
        }
    }
    catch {
        $Session.Phase = 'Failed'
        $Session.FailedOperation = if ($IsPreview) { 'Preview' } else { 'Sync' }
        $Session.ErrorMessage = if ($IsPreview) { '沒有修改要同步的檔案；原因請查看下方紀錄。' } else { '檔案可能已部分變更；請查看紀錄，重新預覽後再執行。' }
        Add-ResyncWizardLog -Wizard $Wizard -Text "`r`n===== 操作失敗 =====`r`n$($_.Exception.Message)`r`n"
    }
    finally { Set-ResyncWizardView -Wizard $Wizard }
}

function New-ResyncWizard {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$PairNames,
        [Parameter(Mandatory)][Collections.IDictionary]$PairInfo,
        [Parameter(Mandatory)][scriptblock]$PrepareAction,
        [Parameter(Mandatory)][scriptblock]$RunAction,
        [Parameter(Mandatory)][scriptblock]$CompleteAction
    )
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $Form = [Windows.Forms.Form]::new()
    $Form.Text = 'Resync — Watch-Sync'
    $Form.Font = [Drawing.Font]::new('Segoe UI', 9)
    $Form.ClientSize = [Drawing.Size]::new(780, 680)
    $Form.MinimumSize = [Drawing.Size]::new(700, 640)
    $Form.StartPosition = [Windows.Forms.FormStartPosition]::CenterScreen
    $Form.AutoScaleMode = [Windows.Forms.AutoScaleMode]::Font
    $Form.BackColor = [Drawing.Color]::White
    $Layout = [Windows.Forms.TableLayoutPanel]::new()
    $Layout.Dock = [Windows.Forms.DockStyle]::Fill
    $Layout.Padding = [Windows.Forms.Padding]::new(16)
    $Layout.ColumnCount = 1; $Layout.RowCount = 10
    foreach ($Height in @(32, 26, 32, 90, 94, 50, 24, 22)) {
        [void]$Layout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, $Height))
    }
    [void]$Layout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent, 100))
    [void]$Layout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, 44))
    $Form.Controls.Add($Layout)
    $Header = [Windows.Forms.Label]::new()
    $Header.Text = '重新建立同步紀錄（Resync）'
    $Header.Font = [Drawing.Font]::new($Form.Font.FontFamily, 14, [Drawing.FontStyle]::Bold)
    $Header.Dock = [Windows.Forms.DockStyle]::Fill
    $Layout.Controls.Add($Header, 0, 0)
    $Steps = [Windows.Forms.Label]::new()
    $Steps.Dock = [Windows.Forms.DockStyle]::Fill
    $Layout.Controls.Add($Steps, 0, 1)
    $Pair = [Windows.Forms.ComboBox]::new()
    $Pair.Dock = [Windows.Forms.DockStyle]::Fill
    $Pair.DropDownStyle = [Windows.Forms.ComboBoxStyle]::DropDownList
    foreach ($Name in $PairNames) { [void]$Pair.Items.Add($Name) }
    $Layout.Controls.Add($Pair, 0, 2)
    $Info = [Windows.Forms.TextBox]::new()
    $Info.Dock = [Windows.Forms.DockStyle]::Fill
    $Info.Multiline = $true; $Info.ReadOnly = $true
    $Info.ScrollBars = [Windows.Forms.ScrollBars]::Both; $Info.WordWrap = $false
    $Layout.Controls.Add($Info, 0, 3)
    $Mode = [Windows.Forms.GroupBox]::new()
    $Mode.Dock = [Windows.Forms.DockStyle]::Fill
    $Mode.Text = '兩邊同名檔案內容不同時，要保留哪個版本？'
    $Options = @()
    $OptionTexts = @('保留本機版本（Local version wins）', '保留雲端版本（Remote version wins）', '保留較新的版本（Newer version wins）')
    for ($Index = 0; $Index -lt 3; $Index++) {
        $Option = [Windows.Forms.RadioButton]::new()
        $Option.Text = $OptionTexts[$Index]
        $Option.AutoSize = $true
        $Option.Location = [Drawing.Point]::new(12, (20 + 22 * $Index))
        $Mode.Controls.Add($Option); $Options += $Option
    }
    $Options[0].Checked = $true
    $Layout.Controls.Add($Mode, 0, 4)
    $StatusPanel = [Windows.Forms.TableLayoutPanel]::new()
    $StatusPanel.Dock = [Windows.Forms.DockStyle]::Fill
    $StatusPanel.RowCount = 2
    [void]$StatusPanel.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent, 50))
    [void]$StatusPanel.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent, 50))
    $Status = [Windows.Forms.Label]::new()
    $Status.Dock = [Windows.Forms.DockStyle]::Fill
    $Status.Font = [Drawing.Font]::new($Form.Font, [Drawing.FontStyle]::Bold)
    $Detail = [Windows.Forms.Label]::new()
    $Detail.Dock = [Windows.Forms.DockStyle]::Fill
    $Detail.AutoEllipsis = $true
    $StatusPanel.Controls.Add($Status, 0, 0); $StatusPanel.Controls.Add($Detail, 0, 1)
    $Layout.Controls.Add($StatusPanel, 0, 5)
    $Progress = [Windows.Forms.ProgressBar]::new()
    $Progress.Dock = [Windows.Forms.DockStyle]::Fill
    $Layout.Controls.Add($Progress, 0, 6)
    $LogLabel = [Windows.Forms.Label]::new()
    $LogLabel.Text = '執行紀錄與預覽摘要'
    $LogLabel.Dock = [Windows.Forms.DockStyle]::Fill
    $Layout.Controls.Add($LogLabel, 0, 7)
    $Log = [Windows.Forms.TextBox]::new()
    $Log.Dock = [Windows.Forms.DockStyle]::Fill
    $Log.Multiline = $true; $Log.ReadOnly = $true
    $Log.ScrollBars = [Windows.Forms.ScrollBars]::Both
    $Log.WordWrap = $false
    $Log.Font = [Drawing.Font]::new('Consolas', 9)
    $Layout.Controls.Add($Log, 0, 8)
    $Footer = [Windows.Forms.FlowLayoutPanel]::new()
    $Footer.Dock = [Windows.Forms.DockStyle]::Fill
    $Footer.FlowDirection = [Windows.Forms.FlowDirection]::RightToLeft
    $Footer.WrapContents = $false
    $Buttons = @()
    foreach ($Caption in @('關閉', '下一步：預覽', '返回設定', '開啟完整 log')) {
        $Button = [Windows.Forms.Button]::new()
        $Button.Text = $Caption
        $Button.Width = if ($Caption -eq '下一步：預覽') { 170 } else { 115 }
        $Button.Height = 30
        [void]$Footer.Controls.Add($Button); $Buttons += $Button
    }
    $Buttons[3].Enabled = $false
    $Layout.Controls.Add($Footer, 0, 9)
    $Wizard = [pscustomobject]@{
        Form = $Form; Pair = $Pair; PairInfo = $PairInfo; Info = $Info; Mode = $Mode
        RemoteWins = $Options[1]; NewerWins = $Options[2]
        Steps = $Steps; Status = $Status; Detail = $Detail; Progress = $Progress; Log = $Log
        Close = $Buttons[0]; Next = $Buttons[1]; Back = $Buttons[2]; OpenLog = $Buttons[3]
        PrepareAction = $PrepareAction; RunAction = $RunAction; CompleteAction = $CompleteAction
        Session = [pscustomobject]@{ Phase = 'Select'; Busy = $false; Selection = $null; Prepared = $null; Preview = $null; LogFile = ''; ErrorMessage = ''; FailedOperation = '' }
    }
    $Pair.add_SelectedIndexChanged({ $Info.Text = [string]$PairInfo[[string]$Pair.SelectedItem] }.GetNewClosure())
    $Buttons[1].add_Click({ Invoke-ResyncWizardStep -Wizard $Wizard }.GetNewClosure())
    $Buttons[2].add_Click({ Reset-ResyncWizard -Wizard $Wizard }.GetNewClosure())
    $Buttons[0].add_Click({ if (-not $Wizard.Session.Busy) { $Wizard.Form.Close() } }.GetNewClosure())
    $Buttons[3].add_Click({
        try { Start-Process -FilePath 'notepad.exe' -ArgumentList ('"' + $Wizard.Session.LogFile + '"') }
        catch { Add-ResyncWizardLog -Wizard $Wizard -Text "`r`n無法開啟 log：$($_.Exception.Message)`r`n" }
    }.GetNewClosure())
    $Form.add_FormClosing({
        param($Sender, $EventArgs)
        if ($Wizard.Session.Busy) {
            $EventArgs.Cancel = $true
            $Wizard.Detail.Text = '仍在處理中，請等待這次操作完成。進度與紀錄會持續更新。'
        }
    }.GetNewClosure())
    $Form.AcceptButton = $Wizard.Next
    $Form.CancelButton = $Wizard.Close
    if ($Pair.Items.Count -gt 0) { $Pair.SelectedIndex = 0 }
    Set-ResyncWizardView -Wizard $Wizard
    return $Wizard
}

function Show-ResyncWizard {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$PairNames,
        [Parameter(Mandatory)][Collections.IDictionary]$PairInfo,
        [Parameter(Mandatory)][scriptblock]$PrepareAction,
        [Parameter(Mandatory)][scriptblock]$RunAction,
        [Parameter(Mandatory)][scriptblock]$CompleteAction
    )
    $Wizard = New-ResyncWizard @PSBoundParameters
    try { [void]$Wizard.Form.ShowDialog() }
    finally { $Wizard.Form.Dispose() }
}
