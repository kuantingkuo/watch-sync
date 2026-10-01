# Watch-Sync

基於 **PowerShell 7** 與 **rclone bisync** 的 Windows 背景雙向雲端同步常駐工具。

提供無黑窗背景執行、系統匣 (System Tray) 圖示狀態、檔案變動自動防抖同步 (Debounce)、使用者閒置偵測定時同步、休眠/喚醒偵測、防誤刪安全鎖，以及 Filter 變更保護等功能。

---

## 專案結構

```text
watch-sync/
├── .gitignore
├── README.md
├── VERSION                    # 版本號 (例如 0.2.0)
│
├── watch-sync-tray.ps1        # 核心常駐程式與 Tray UI
├── watch-sync.filters         # rclone bisync 過濾器規則
├── start-watch-sync.vbs       # 手動無黑窗背景啟動器 (VBScript)
├── install.ps1                # 一鍵安裝、檢查與工作排程器設定精靈
│
├── config.example.psd1        # 設定檔範本 (追蹤於 Git)
├── config.local.psd1          # 本機獨立設定檔 (被 .gitignore 排除，不進 Git)
│
└── icons/                     # 狀態圖示
    ├── standby.ico            # 待命/監聽中
    ├── syncing.ico            # 正在同步中
    └── error.ico              # 錯誤/需要手動介入
```

---

## 系統需求

1. **Windows 10 / 11**
2. **PowerShell 7+**：
   ```powershell
   winget install Microsoft.PowerShell
   ```
3. **rclone**：
   ```powershell
   winget install Rclone.Rclone
   ```
   請確認 `rclone.exe` 已加入系統 PATH，且已完成雲端帳號授權（`rclone config`）。

---

## 新電腦部署與安裝指南

### 1. 取得專案代碼
可將本專案 Fork 或 Clone 至您的電腦：
```powershell
git clone https://github.com/<YOURNAME>/watch-sync.git
cd watch-sync
```

### 2. 首次執行安裝精靈
執行部署腳本以檢查環境並初始化設定檔：
```powershell
pwsh -File .\install.ps1
```
精靈將會自動：
- 檢查 PowerShell 7 與 `rclone` 環境。
- 若尚未存在 `config.local.psd1`，自動由範本複製建立，並提醒您先進行編輯。
- 檢查過濾器規則檔案。

### 3. 配置本機同步目錄 (`config.local.psd1`)
開啟 `config.local.psd1`，依照這台電腦的實際路徑填寫：
```powershell
@{
    Pairs = @{
        Documents = @{
            Local  = "%USERPROFILE%\Documents\Work"
            Remote = "gdrive:Backup/Documents"
        }
        Photos = @{
            Local  = "%USERPROFILE%\Pictures\Camera"
            Remote = "onedrive:Media/Photos"
        }
    }

    Settings = @{
        # 選填覆蓋主程式預設行為
        # QuietSeconds = 30
        # IdleMinutes  = 10
        # Transfers    = 4
    }
}
```
> **注意**：本設定檔為 PowerShell Data File (`.psd1`)，**不執行任何程式碼**以確保安全性。路徑支援 `%USERPROFILE%` 等 Windows 環境變數語法。

### 4. 放置安全標記檔案
為了防止目錄未掛載或誤刪導致雲端被清空，每個同步目錄的本機與雲端根目錄均需手動放置一個空檔案：
```text
.rclone-bisync-check
```

### 5. 進行初次 Bisync 初始化 (重要！)
> [!IMPORTANT]
> **GitHub 只同步 watch-sync 工具代碼，絕對不同步各電腦的 rclone bisync 狀態快取！**
> 新電腦首次同步前，必須先手動針對每個 Pair 執行一次初始化：

```powershell
# 先以 --dry-run 測試
rclone bisync "%USERPROFILE%\Documents\Work" "gdrive:Backup/Documents" `
    --resync --resync-mode path2 --filters-file ".\watch-sync.filters" `
    --check-access --check-filename ".rclone-bisync-check" --dry-run

# 確認無誤後正式初始化
rclone bisync "%USERPROFILE%\Documents\Work" "gdrive:Backup/Documents" `
    --resync --resync-mode path2 --filters-file ".\watch-sync.filters" `
    --check-access --check-filename ".rclone-bisync-check"
```

### 6. 完成安裝與常駐註冊
完成初次 bisync 後，重新執行安裝精靈以完成最終驗證並註冊工作排程器：
```powershell
pwsh -File .\install.ps1 -StartNow
```
精靈將會驗證目錄、安全標記，並在 Windows **工作排程器** 建立登入自動啟動工作，接著於背景無黑窗啟動 Watch-Sync！

---

## 日常操作與維護

### 系統匣功能 (System Tray)
在右下角通知區域找到同步圖示，右鍵選單提供：
- **Watch-Sync v0.2.0**：當前版本號
- **Status**：目前監聽狀態、同步進度或錯誤警報
- **Sync all now**：立即強制對所有配對執行同步
- **Open log folder**：開啟日誌資料夾 (`%LOCALAPPDATA%\rclone\watch-sync`)
- **Restart**：安全釋放 Mutex 並重新載入最新設定與程式碼
- **Exit**：退出常駐程式

### 程式更新工作流
當在 GitHub 上更新了工具代碼後，在本機終端機執行：
```powershell
git pull --ff-only
```
更新完畢後，直接點擊系統匣圖示的 **「Restart」**，即可無縫套用最新版本！

### 過濾器變更與安全保護 (rclone 原生 MD5 機制)
`rclone bisync` 具有強大的過濾器保護機制：一旦變更過濾規則（`watch-sync.filters`），既有的 bisync baseline 就不再可靠。
- **Git 只管理規則本體**：`watch-sync.filters` 進 Git；而各電腦的 `watch-sync.filters.md5` 則**留在每台電腦本機**（由 `.gitignore` 排除，由 rclone 自行維護）。
- **跨電腦安全阻擋**：
  1. 當你在桌機修改 `watch-sync.filters` 並完成 `--resync` 後，只需將新規則 push 至 Git。
  2. 筆電執行 `git pull` 取得新規則後，筆電本機的舊 `.md5` 與新規則不符，rclone 在下次同步時會**主動安全中斷（exit code 7）**，Tray 圖示會切換為警告並顯示 `Blocked`。
  3. 這表示 rclone 成功阻擋了潛在的跨版本檔案誤刪！只要在筆電依提示執行一次 `rclone bisync ... --resync`，rclone 便會自動更新筆電本機的 `.md5`，接著點擊 Tray 的 **Restart** 即可恢復監聽。

---

## 安全聲明

下列本機特定檔案、金鑰與快取**已被 `.gitignore` 嚴格排除，絕不進 Git Repo**：
- `config.local.psd1`（本機個人同步路徑與設定）
- `watch-sync.filters.md5`（各電腦獨立的 rclone bisync 過濾器校驗碼）
- `rclone.conf`（包含 OAuth Token 與雲端金鑰）
- `%LOCALAPPDATA%\rclone\bisync\`（本機 bisync 狀態與檔案清單）
- `*.log`、`*.lnk`
