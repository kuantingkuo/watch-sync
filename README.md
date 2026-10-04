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
├── config.local.psd1          # 本機獨立手動設定檔 (被 .gitignore 排除，不進 Git)
├── pairs.local.json           # 系統匣 UI 管理之同步配對 (被 .gitignore 排除，不進 Git)
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
git clone https://github.com/kuantingkuo/watch-sync.git
cd watch-sync
```

### 2. 首次執行安裝精靈
執行部署腳本以檢查環境並初始化基礎設定檔：
```powershell
pwsh -File .\install.ps1
```
精靈將會自動：
- 檢查 PowerShell 7 與 `rclone` 環境。
- 若尚未存在 `config.local.psd1`，自動由範本複製建立基礎設定。
- 檢查過濾器規則檔案。

### 3. 設定同步目錄（選擇一種方式）

#### 途徑 A：透過系統匣新增 (推薦，免手動初始化)
如果您希望透過圖形介面輕鬆設定，且由精靈自動建立防誤刪安全標記與執行初始化 bisync：
1. 註冊排程並在背景啟動 Watch-Sync：
   ```powershell
   pwsh -File .\install.ps1 -StartNow
   ```
2. 啟動後，在右下角通知區域的同步圖示點右鍵，選取 **「Add sync folder...」**。
3. 依視窗引導選取本機目錄、雲端 Remote 與遠端子資料夾。精靈會自動在本機與雲端建立安全標記、執行 `--dry-run` 檢查、引導確認後執行正式初始化，完成後自動開始背景監聽！

#### 途徑 B：手動進階設定 (`config.local.psd1`)
如果您習慣直接手動編輯設定檔：
1. **配置本機設定檔**：開啟 `config.local.psd1`，依照這台電腦的實際路徑填寫：
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
2. **手動放置安全標記檔案**：
   為了防止目錄未掛載或誤刪導致雲端被清空，每個同步目錄的本機與雲端根目錄均需手動放置一個空檔案：
   ```text
   .rclone-bisync-check
   ```
3. **手動進行初次 Bisync 初始化**：
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
4. **完成安裝與常駐註冊**：
   完成初始化後，執行安裝精靈註冊工作排程器並啟動：
   ```powershell
   pwsh -File .\install.ps1 -StartNow
   ```

---

## 日常操作與維護

### 系統匣功能 (System Tray)
在右下角通知區域找到同步圖示，右鍵選單提供：
- **Watch-Sync v0.2.0**：當前版本號
- **Status**：目前監聽狀態、同步進度或錯誤警報
- **Sync all now**：立即強制對所有配對執行同步
- **Add sync folder...**：新增同步資料夾（透過圖形引導精靈新增配對，自動完成安全檢查與初次同步）
- **Manage sync folders...**：管理同步資料夾（查看所有配對來源，並可移除 Tray 管理之配對）
- **Open log folder**：開啟日誌資料夾 (`%LOCALAPPDATA%\rclone\watch-sync`)
- **Restart**：安全釋放 Mutex 並重新載入最新設定與程式碼
- **Exit**：退出常駐程式

### 透過系統匣新增同步目錄 (Add sync folder...)
使用者無須手動編輯 `config.local.psd1`，只要在系統匣選單點擊 **「Add sync folder...」**：
1. **選取本機目錄**：使用 Windows 原生資料夾選擇視窗選取欲同步的本機路徑 (Path1)。
2. **設定配對資訊**：
   - **Pair name**：預設為目錄名稱，可自行修改；系統會自動阻擋重複名稱與不合法字元。
   - **Local folder**：顯示已選取的本地路徑（唯讀）。
   - **Remote**：下拉選單自動由 `rclone listremotes` 動態填入，並需於右側欄位輸入遠端子目錄 (Path2)。**系統要求遠端子目錄不可為空**，以防誤將整個雲端硬碟根目錄納入雙向同步。
   - **衝突與重疊保護**：系統會主動檢查並阻擋同名、重複路徑以及**父子目錄重疊 (例如本機 C:\Data 與 C:\Data\Project，或遠端 gdrive:Data 與 gdrive:Data/Project)**，保護監聽器與快取狀態。
   - **Initial synchronization (初次同步方向)**：
     - **Local version wins** (`--resync-mode path1`，預設)：以本地檔案為基準，覆蓋遠端雲端之衝突檔案。
     - **Remote version wins** (`--resync-mode path2`)：以遠端雲端檔案為基準，覆蓋本地之衝突檔案。
     - **Newer version wins** (`--resync-mode newer`)：自動比對並保留修改時間較新的檔案版本。
3. **安全防護與初始化流程**：
   - **安全標記**：自動在本機與雲端目錄建立 `.rclone-bisync-check` 防誤刪安全標記。
   - **Phase 1: 模擬測試 (Dry Run)**：自動執行帶有 `--dry-run` 的 initial bisync；若失敗會跳出錯誤視窗顯示原因，**絕不儲存無效設定**。
   - **確認對話框**：模擬測試通過後，顯示確認對話框，清楚列出本地目錄、遠端目錄與所選衝突偏好。
   - **Phase 2: 正式初次同步**：確認後執行正式 initial bisync；執行成功後才將設定寫入 `pairs.local.json`。
   - **自動重啟監聽**：寫入完成後透過原生重啟機制重新啟動 Watch-Sync，自動建立 FileSystemWatcher 開始背景監聽！

### 透過系統匣管理與移除配對 (Manage sync folders...)
點選系統匣選單的 **「Manage sync folders...」**：
- **查看配對清單**：列出所有生效中與已設定的同步配對，包含配對名稱、本地路徑、遠端路徑以及配置來源：
  - `config.local.psd1`：手動設定檔定義之配對（在此介面中為唯讀保護，維護手動相容性）。
  - `Tray-managed`：透過系統匣新增之配對（儲存於 `pairs.local.json`）。
  - `Conflict / disabled`：若 `pairs.local.json` 中的配對與其他設定產生目錄重疊或衝突，將以紅色標示為停用，使用者可直接點選將其自設定中移除。
- **移除配對 (Remove from Watch-Sync)**：
  - 選取 Tray-managed 配對後，點選「Remove from Watch-Sync」即可解除同步。
  - **非破壞性移除設計 (Non-destructive removal)**：移除配對**僅代表 Watch-Sync 停止監聽與同步此項目**，**不會刪除本地或雲端的任何檔案**，亦不執行任何破壞性 rclone purge/delete 指令。
  - 移除後程式將更新 `pairs.local.json` 並自動重新啟動，乾淨釋放該目錄的背景監聽資源。

### 設定檔存儲與相容性設計
- **`config.local.psd1`**：維持原有手動設定檔設計，維持向下相容性，系統匣 UI **絕不自動竄改**此檔案。
- **`pairs.local.json`**：系統匣 UI 專屬存儲檔案，採用 JSON 格式，已被 `.gitignore` 排除，絕不進 Git。
- **啟動時自動合併與衝突檢查**：主程式啟動時會同時載入 `config.local.psd1` 與 `pairs.local.json`，並自動偵測並阻擋重複名稱、重複目錄或父子目錄重疊衝突。

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
- `config.local.psd1`（本機手動個人同步路徑與設定）
- `pairs.local.json`（系統匣 UI 新增與管理之個人同步配對）
- `watch-sync.filters.md5`（各電腦獨立的 rclone bisync 過濾器校驗碼）
- `rclone.conf`（包含 OAuth Token 與雲端金鑰）
- `%LOCALAPPDATA%\rclone\bisync\`（本機 bisync 狀態與檔案清單）
- `*.log`、`*.lnk`
