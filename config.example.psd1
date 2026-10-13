# ==============================================================================
# Watch-Sync Configuration Template
# ==============================================================================
# 將此檔案複製為 config.local.psd1，再填入這台電腦的同步路徑。
# 這是 PowerShell Data File (.psd1)，只讀取設定值，不執行程式碼。
# 不支援 $env:USERPROFILE 等變數寫法；使用者資料夾請寫成 %USERPROFILE%。
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

    # 程式設定 (選填；未填寫時使用預設值)
    Settings = @{
        # 本機檔案變更後，連續幾秒沒有新變更才開始同步
        # QuietSeconds        = 30

        # 電腦閒置幾分鐘後，同步所有配對
        # IdleMinutes         = 10

        # 持續閒置時，每隔幾分鐘再次同步 (0 代表停用)
        # IdleRepeatMinutes   = 60

        # 程式暫停幾秒後，視為電腦剛從休眠喚醒
        # ResumeGapSeconds    = 90
        # 偵測到喚醒後，等待幾秒再同步，讓網路有時間恢復
        # ResumeDelaySeconds  = 10

        # 啟動後等待幾秒再開始同步
        # StartupDelaySeconds = 3

        # 同步失敗後，等待幾秒再試一次，以及最多自動嘗試幾次
        # RetryDelaySeconds   = 120
        # MaxAutoRetries      = 3

        # 最多同時同步幾組配對（1–32）；每組各自使用下面的 Transfers/Checkers 設定
        # MaxParallelSyncs    = 4

        # 每組配對同時傳輸的檔案數，以及同時執行的檔案檢查數
        # Transfers           = 4
        # Checkers            = 8

        # log 保存天數、單檔大小上限與總容量（MiB）
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
