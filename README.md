# Watch-Sync

Watch-Sync 使用 **PowerShell 7** 與 **rclone bisync**，在 Windows 背景同步電腦與雲端的檔案。

程式在背景執行，不會顯示命令視窗。你可以從系統匣圖示查看狀態。檔案變更後，程式會等一段時間，確認沒有新的變更，再開始同步；也會在電腦閒置或從休眠喚醒後同步。安全標記和過濾規則檢查用來降低誤刪檔案的風險。

說明中的幾個名稱：

- **同步配對**：一組要同步的本機資料夾與雲端資料夾。
- **Remote**：在 rclone 中設定的雲端連線名稱，例如 `gdrive:`。
- **baseline**：bisync 用來判斷檔案新增、修改或刪除的同步比對紀錄。
- **Resync**：重新建立 baseline；兩邊同名檔案內容不同時，會依你選擇的方式決定保留哪個版本。
- **dry-run**：預覽同步會進行哪些操作，不會修改要同步的檔案。

---

## 專案結構

```text
watch-sync/
├── .gitignore
├── README.md
├── VERSION                    # 版本號 (目前 0.4.0)
├── CHANGELOG.md               # 版本變更與升級說明
├── watch-sync-core.ps1        # 設定、配對、同步狀態、排程與 baseline 檢查
│
├── watch-sync-tray.ps1        # 背景執行程式與系統匣介面
├── watch-sync-maintenance.ps1 # 排除規則、log 檔管理與舊檔清理
├── watch-sync-resync.ps1      # Resync 分步視窗、即時紀錄與進度顯示
├── watch-sync.filters         # rclone bisync 過濾規則
├── start-watch-sync.vbs       # 在背景啟動程式，不顯示命令視窗
├── install.ps1                # 安裝檢查與工作排程器設定
│
├── config.example.psd1        # 設定檔範本 (追蹤於 Git)
├── config.local.psd1          # 這台電腦的手動設定 (不加入 Git)
├── pairs.local.json           # 從系統匣新增的同步配對 (不加入 Git)
│
└── icons/                     # 狀態圖示
    ├── standby.ico            # 等待檔案變更
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
3. **rclone 1.71+**（需要內建的 log 檔大小與保存期限管理功能）：
   ```powershell
   winget install Rclone.Rclone
   ```
   請確認 `rclone.exe` 已加入系統 PATH，且已完成雲端帳號授權（`rclone config`）。

---

## 在新電腦上安裝

### 1. 下載專案程式碼

使用 Git 將專案下載到你的電腦：
```powershell
git clone https://github.com/kuantingkuo/watch-sync.git
cd watch-sync
```

### 2. 執行安裝程式

執行以下指令，檢查環境並建立設定檔：
```powershell
pwsh -File .\install.ps1
```
安裝程式會：

- 檢查 PowerShell 7 與 `rclone` 環境。
- 若還沒有 `config.local.psd1`，從範本建立設定檔，並提示你先填寫設定再繼續安裝。
- 檢查過濾規則檔案。

### 3. 設定同步目錄（選擇一種方式）

#### 方法 A：從系統匣新增

使用介面新增配對，程式會引導你完成安全檢查與第一次同步：

1. 註冊排程並在背景啟動 Watch-Sync：
   ```powershell
   pwsh -File .\install.ps1 -StartNow
   ```
2. 啟動後，在右下角通知區域的同步圖示點右鍵，選取 **「Add sync folder...」**。
3. 依視窗提示選擇本機資料夾、Remote 與雲端子資料夾。程式會在兩邊建立安全標記，先執行 dry-run 預覽，等你確認後才進行第一次同步，完成後重新啟動並開始監看檔案變更。

#### 方法 B：手動編輯設定檔 (`config.local.psd1`)

如果你習慣直接編輯設定檔：

1. **填寫設定檔**：開啟 `config.local.psd1`，填入這台電腦的資料夾路徑：
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
           # 選填；未填寫時使用預設值
           # QuietSeconds = 30
           # IdleMinutes  = 10
           # Transfers    = 4
       }
   }
   ```
   > 設定檔使用 PowerShell Data File (`.psd1`) 格式，只讀取設定值，不執行程式碼。路徑支援 `%USERPROFILE%` 等 Windows 環境變數。
2. **手動放置安全標記檔案**：
   程式會用安全標記檢查資料夾是否仍可正常存取。請在每個配對的本機資料夾與雲端資料夾最上層，各放一個空檔案：
   ```text
   .rclone-bisync-check
   ```
3. **設定登入時自動啟動**：
   執行安裝程式，在 Windows 工作排程器建立工作並啟動 Watch-Sync。還沒有 baseline 紀錄的配對會先停止同步，顯示 `Blocked`：
   ```powershell
   pwsh -File .\install.ps1 -StartNow
   ```
4. **建立各配對的 baseline**：在系統匣選 **Resync...**，選擇配對，以及兩邊同名檔案內容不同時要保留哪個版本。檢查 dry-run 預覽後確認執行；若要保留雲端版本，選 **Remote version wins**。成功後恢復正常同步。

---

## 日常操作與維護

### 系統匣選單

系統匣是螢幕右下角、時鐘旁邊的通知區域。若沒看到 Watch-Sync 圖示，先點 **`^` 向上箭頭**展開隱藏圖示。對 Watch-Sync 圖示按滑鼠右鍵，可使用以下選項：

- **Watch-Sync v0.4.0**：顯示 VERSION 檔中的版本號。
- **Status**：顯示目前狀態，例如等待變更、同步中或錯誤。
- **Sync all now**：安排所有可以同步的配對立即同步；已停止同步的 `Blocked` 配對仍需先處理原因。
- **Add sync folder...**：新增配對，依畫面提示完成安全檢查與第一次同步。
- **Manage sync folders...**：查看配對來源，或移除從系統匣新增的配對。
- **Open log folder**：開啟 log 資料夾 (`%LOCALAPPDATA%\rclone\watch-sync`)。
- **Recheck blocked pairs**：處理安全標記或錯誤原因後，重新檢查配對。通過檢查後安排同步；baseline 過期時仍需 Resync。
- **Resync...**：在同一個視窗選擇配對、查看預覽、確認執行及查看結果。視窗會持續顯示目前階段、經過時間、進度條與即時 log；完成或失敗後保留結果，也能繼續選擇下一組配對。
- **Restart**：等待目前的同步完成，再重新啟動，套用最新設定與程式碼。
- **Exit**：等待目前的同步完成，再結束程式。

### 透過系統匣新增同步目錄 (Add sync folder...)

在系統匣選 **Add sync folder...**，依下列步驟操作：

1. **選擇本機資料夾**：在 Windows 資料夾選擇視窗，選擇要同步的資料夾（Path1）。
2. **設定配對資訊**：
   - **Pair name**：配對名稱，預設使用資料夾名稱。可以自行修改；名稱不能重複，也不能含有不允許的字元。
   - **Local folder**：顯示選擇的本機資料夾路徑，不能在這個欄位修改。
   - **Remote**：從 `rclone listremotes` 列出的雲端連線中選擇，再於右側填入雲端子資料夾路徑（Path2）。**子資料夾路徑不能留空**，以免把整個雲端硬碟都加入同步。
   - **避免重複或重疊的資料夾**：同一個資料夾不能加入兩次，也不能同時同步父資料夾與其子資料夾，例如 `C:\Data` 與 `C:\Data\Project`，或 `gdrive:Data` 與 `gdrive:Data/Project`。
   - **Initial synchronization**：兩邊同名檔案內容不同時，要保留哪個版本：
     - **Local version wins** (`--resync-mode path1`，預設)：保留本機版本，覆蓋雲端的不同版本。
     - **Remote version wins** (`--resync-mode path2`)：保留雲端版本，覆蓋本機的不同版本。
     - **Newer version wins** (`--resync-mode newer`)：自動比對並保留修改時間較新的檔案版本。
3. **檢查並開始同步**：
   - 在本機與雲端資料夾建立 `.rclone-bisync-check` 安全標記。
   - 執行 dry-run 預覽；失敗時顯示原因，並停止新增配對。
   - 顯示確認視窗，列出兩邊的路徑與你選擇的檔案保留方式。
   - 你確認後，才進行第一次同步。成功後將配對設定寫入 `pairs.local.json`。
   - 儲存完成後重新啟動 Watch-Sync，開始監看檔案變更。

### 透過系統匣管理與移除配對 (Manage sync folders...)

在系統匣選 **Manage sync folders...**：

- **查看配對清單**：列出配對名稱、兩邊的路徑與設定來源：
  - `config.local.psd1`：手動設定的配對。要修改時，請直接編輯設定檔。
  - `Tray-managed`：從系統匣新增的配對，儲存在 `pairs.local.json`。
  - `Conflict / disabled`：與其他配對的資料夾重疊或設定衝突，已停用並以紅色顯示。你可以將它從配對清單移除。
- **移除配對 (Remove from Watch-Sync)**：
  - 選擇 `Tray-managed` 配對，再按 **Remove from Watch-Sync**。
  - 移除配對後，Watch-Sync 會停止同步這組資料夾，**兩邊的檔案都會保留**。
  - 程式會更新 `pairs.local.json`，再重新啟動以套用變更。

### 設定儲存在哪裡

- **`config.local.psd1`**：手動設定檔。從系統匣新增或移除配對時，不會修改這個檔案。
- **`pairs.local.json`**：儲存從系統匣新增的配對，使用 JSON 格式，由 `.gitignore` 排除。
- **啟動時合併設定**：程式會讀取兩份設定檔，檢查系統匣新增的配對是否與其他配對名稱重複，或資料夾路徑重疊。

### 更新程式

GitHub 上有新版時，在專案資料夾開啟終端機並執行：
```powershell
git pull --ff-only
```
更新後，在系統匣選 **Restart** 套用新版。請先查看 CHANGELOG 的升級步驟；第一次升級到 0.4.0，需要為各配對建立 baseline 紀錄。

### 過濾規則變更與 baseline 檢查

**Resync 視窗操作：** 選好配對與檔案保留方式後，按 **下一步：預覽**。預覽完成後，在同一個視窗檢查紀錄，再按 **確認並開始 Resync**。掃描與檢查時，進度條持續移動；rclone 提供傳輸統計時，則顯示目前這一輪的傳輸百分比、速度與預估剩餘時間。傳輸達 100% 後仍可能需要檢查結果，只有畫面顯示完成才代表整次 Resync 成功。執行期間關閉按鈕暫停使用；完成後可以關閉視窗，或選擇下一組配對。**開啟完整 log** 可以查看全部紀錄，視窗內只保留最近的內容。

[rclone bisync](https://rclone.org/bisync/#filters-file) 要求修改 `watch-sync.filters` 後執行 Resync。rclone 的 `.md5` 檔放在過濾規則檔旁邊，多個配對共用，無法單靠它確認每個配對都已更新 baseline。

Watch-Sync 另外在 `%LOCALAPPDATA%\rclone\watch-sync\filters-baselines.json` 記錄每個配對成功 Resync 時的過濾規則 SHA-256，以及兩邊的路徑（Local、Remote）。這份紀錄與 `.md5` 檔都是這台電腦專用，請不要複製到其他電腦。

程式在啟動時及執行期間每秒檢查過濾規則，讓檔案變更偵測使用相同規則。baseline 已過期或沒有紀錄的配對會停止同步，顯示 `Blocked`。請從系統匣選 **Resync...**，逐一預覽並重新建立 baseline，成功後恢復同步。

每個配對都要各自完成 Resync。若過濾規則在預覽後又改變，程式會要求重新預覽；在執行期間改變，也不會將這次結果記為成功。已經開始的同步會先完成，後續同步則會停止。修改過濾規則前，建議先選 **Exit**，等待同步完成。

**第一次升級到 0.4.0：** 舊版沒有每個配對的 baseline 紀錄，因此每台電腦都需要為各配對執行一次 **Resync...**。檢查預覽並選好要保留的檔案版本，再確認執行。程式不會自動執行 Resync。在終端機直接執行 `rclone bisync ... --resync`，也不會更新 Watch-Sync 的紀錄。

若 baseline 紀錄檔損毀，程式會顯示錯誤並停止啟動。請先保留檔案副本，再移開損毀的檔案，重新啟動並逐一預覽、執行 Resync。

### 同步排程

不論同步是由啟動程式、手動操作、閒置、喚醒、檔案變更或失敗後再次嘗試所觸發，都會由同一套排程安排。預設最多同時同步 4 組配對；可在 `Settings` 將 `MaxParallelSyncs` 設為 1–32。每個配對同一時間只會執行一次同步。

排隊的工作依順序開始，其次處理等待時間已到、可以再次嘗試的失敗工作，最後處理已一段時間沒有新變更的本機檔案。同步期間出現的新變更，會留待下一次同步處理。

使用新增配對、管理配對或 Resync 時，程式會先等目前的同步完成，再開啟相關操作。**Exit** 和 **Restart** 也會等目前的同步結束。

---

## 預設排除規則

`watch-sync.filters` 會排除 Windows/macOS 產生的輔助檔案、Office 鎖定檔、`.tmp` 暫存檔、Vim swap 檔、尚未完成的下載檔、Dropbox 本機快取，以及 Python 虛擬環境與工具快取。FileSystemWatcher（用來偵測檔案變更）使用同一份規則，這些檔案的變更不會單獨觸發同步；重新命名導致檔案開始或停止符合排除規則時，仍會觸發同步。

一般 `.log`、`.bak`、Git 資料、Obsidian 設定和筆記會繼續同步。這些檔案可能是工作成果或復原所需的資料。新增排除規則後，符合規則的檔案會停止同步，兩邊原有的副本會保留。

參考：[Dropbox 不同步的檔案](https://help.dropbox.com/sync/files-not-syncing)、[OneDrive 限制](https://support.microsoft.com/en-us/onedrive/restrictions-and-limitations-in-onedrive-and-sharepoint)。修改規則後，請從系統匣為各配對執行 **Resync...**，先預覽再確認；其他電腦下載新規則後，也需要各自更新 baseline。

## log 與診斷檔案

在系統匣選 **Open log folder** 開啟 `%LOCALAPPDATA%\rclone\watch-sync`：

- `watch-sync-yyyy-MM-dd.log`：一般狀態、同步結果、錯誤，以及詳細 log 的路徑。
- `bisync-配對名稱-識別碼-yyyy-MM-dd.log`：每個配對的詳細 log，各自管理檔案大小與保存期限，避免多個 rclone 程式同時處理同一個 log。
- `init-時間-識別碼.log`：第一次同步、Resync 及預覽的紀錄。
- `.log.gz`：壓縮的舊紀錄，可用 7-Zip 等工具開啟；既有按月保存的紀錄也會壓縮並套用保存期限。

預設保留最近 **30 天**的 log。單一檔案達 **10 MiB** 時，程式會保存舊檔並開始寫入新檔；全部 log 的容量目標為 **200 MiB**。超過容量時先刪除較舊的 log，因此紀錄很多時，保留時間可能少於 30 天。程式在啟動時及之後每小時、沒有同步工作時清理；當天仍在使用的 log 會保留，因此總容量可能暫時超過目標。

`%LOCALAPPDATA%\rclone\bisync` 中，超過保存期限的 `*.path1.lst-dry*`、`*.path2.lst-dry*` 預覽清單，會在沒有 bisync 鎖定檔時清理。正式 `.lst`、復原用的 `.lst-old`、尚未完成的 `.lst-new`、鎖定檔和過濾規則檢查碼都會保留。你在同步資料夾中建立的研究 log、改名紀錄、備份和復原資料夾，也會保留。

可在 `config.local.psd1` 的 `Settings` 覆蓋以下預設值：

```powershell
LogRetentionDays = 30
LogMaxFileMiB    = 10
LogMaxTotalMiB   = 200
```

log 管理參考 [Syncthing 的 log 設定](https://docs.syncthing.net/users/syncthing.html) 和 [rclone 的 log 大小與保存設定](https://rclone.org/docs/#log-file-max-size-sizesuffix)。Dropbox 的[本機快取清理](https://help.dropbox.com/delete-restore/cache-folder) 處理的是暫存資料，不能用同樣方式刪除同步 baseline 或你的檔案。

完整測試：`pwsh -NoProfile -File .\tests\run-tests.ps1`。測試涵蓋同步狀態、排程、維護功能、主程式整合與本機 rclone，只使用專用暫存資料夾，不會操作你設定的配對或雲端。加上 `-Analyze` 可執行 PSScriptAnalyzer 1.24.0 程式檢查（需先安裝該模組）。GitHub 上的 Windows CI 自動測試也執行相同指令。

## 不加入 Git 的本機資料

下列檔案由 `.gitignore` 排除，避免將個人路徑、帳號憑證和本機狀態加入 Git：

- `config.local.psd1`（手動填寫的同步路徑與設定）
- `pairs.local.json`（從系統匣新增的配對）
- `watch-sync.filters.md5`（這台電腦的 rclone 過濾規則檢查碼）
- `rclone.conf`（包含 OAuth Token 與雲端金鑰）
- `%LOCALAPPDATA%\rclone\bisync\`（本機 bisync 狀態與檔案清單）
- `*.log`、`*.lnk`
