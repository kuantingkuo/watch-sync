# ==============================================================================
# Watch-Sync Configuration Template
# ==============================================================================
# 複製此檔案為 config.local.psd1 並根據此台電腦的路徑進行修改。
# 注意：本檔案為 PowerShell 數據檔案 (.psd1)，不支援變數求值（如 $env:USERPROFILE）與型別轉換。
# 如需使用使用者家目錄，請使用環境變數語法：%USERPROFILE%
# ==============================================================================

@{
    # 同步配對清單 (Pairs)
    Pairs = @{
        Documents = @{
            Local  = "%USERPROFILE%\Documents\Work"
            Remote = "gdrive:Backup/Documents"
        }

        Photos = @{
            Local  = "%USERPROFILE%\Pictures\Camera"
            Remote = "onedrive:Media/Photos"
        }

        Notes = @{
            Local  = "%USERPROFILE%\Documents\Notes"
            Remote = "remote_crypt:Notes"
        }
    }

    # 行為參數設定 (選填覆蓋，若未設定則使用主程式預設值)
    Settings = @{
        # 本地檔案變動後等待靜止的秒數 (防抖動)
        # QuietSeconds        = 30

        # 使用者閒置幾分鐘後觸發全配對同步
        # IdleMinutes         = 10

        # 長時間閒置期間，每隔幾分鐘再次同步遠端變更 (0 代表停用重複閒置檢查)
        # IdleRepeatMinutes   = 60

        # 電腦休眠/喚醒偵測容許秒數
        # ResumeGapSeconds    = 90
        # ResumeDelaySeconds  = 10

        # 啟動後等待初始同步的秒數
        # StartupDelaySeconds = 3

        # 失敗重試間隔秒數與最大次數
        # RetryDelaySeconds   = 120
        # MaxAutoRetries      = 3

        # rclone 傳輸與檢查執行緒數
        # Transfers           = 4
        # Checkers            = 8

        # 診斷日誌：保留天數、單檔輪替門檻、總容量（MiB）
        # LogRetentionDays    = 30
        # LogMaxFileMiB       = 10
        # LogMaxTotalMiB      = 200

        # 防誤刪安全標記檔案名稱
        # CheckFileName       = ".rclone-bisync-check"

        # 是否啟用系統匣 (System Tray) 圖示與通知
        # EnableTrayIcon      = $true
        # ShowTrayErrorNotifications = $true
    }
}
