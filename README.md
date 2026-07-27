# COSCUP SSD 拔除警告系統
專門監測於 USB port 上拔除硬體狀態。

## 注意事項
如果要將監控軟體部屬，然後將監控結果回傳至 Server
Server 應該要具備 api 讓程式能將結果回傳

## 架構
`monitor.ps1` 是固定的腳本，所有設定都放在同資料夾的 `config.json`。
換 URL、改音效、調輪詢間隔等功能，只要編輯 `config.json`就好，**不需要重新產生腳本**。

| 名稱 | 說明 |
| --- | --- |
|資料夾|
| `sounds/` | 放自訂音效檔的地方（選用） |
| `Modules/BurntToast` | 通知模組 |
|監控軟體|
| `run.bat` | 啟動監控 |
| `config.json` | 設定檔（`generator.html` 產生，或直接手動編輯） |
| `generator.html` | 設定產生器 |
| `monitor.ps1` | 監控腳本（固定，不需修改） |
|工具 部屬用|
| `collect.bat` | 識別碼 (GUID, Signature) 蒐集 |
| `tools/collect-serials.ps1` | 收集裝置序號／識別碼 |
| `tools/deploy.ps1` | 依映射表批次產生各場地的部署套件 |
| `deploy-table.example.json` | 映射表範例 |

## Install
1. 使用瀏覽器開啟 `generator.html`
2. 依序填寫下列欄位

| 欄位 |  `config.json`對應欄位 | 說明 |
| --- | --- | --- |
| 資產名稱／電腦識別碼 | `computerName` | 留空則自動使用電腦名稱 |
| 監控伺服器 API 位址 | `serverUrl` | 留空用預設值 |
| API 金鑰 | `apiKey` | 留空用預設值 |
| 監控範圍：指定裝置識別碼 | `watchIds` | 一行一個，留空 = 監控所有 USB 磁碟 |
| 警報音效 | `sound` | 內建音效，或選「自訂音效檔…」填路徑 |
| 循環播放 | `soundLoopSeconds` | 僅自訂音效適用 |
| 輪詢間隔（秒） | `pollSeconds` | 預設 3 |
| 標記為重要通知 | `urgent` | 可穿透「專注助理」 |
| 略過 TLS 憑證驗證 | `skipCertificateCheck` | 搭配自簽憑證時需勾選 |

各欄位的詳細行為見下方 [config.json 欄位](#configjson-欄位)。
3. 點選下載，會自動產生一個檔案為 `config.json`
4. 把下載的檔案移動到資料夾內，覆蓋既有的那份
5. 利用**管理員權限**執行 `run.bat`

#### __Warning__
* __run.bat 會強制繞過未簽章之檔案的執行限制__
* __`skipCertificateCheck` 預設為 true（配合自簽憑證），此時 HTTPS 不具備防中間人的效果。正式環境請改用受信任的憑證並關掉這個選項__

## config.json 欄位

| 欄位 | 說明 | 預設 |
| --- | --- | --- |
| `serverUrl` | 事件回傳的 API 位址 | `https://localhost:8443/api/usb-event` |
| `apiKey` | Bearer token | `your-secret-api-key-here` |
| `computerName` | 電腦識別碼  | `%COMPUTERNAME%` |
| `pollSeconds` | 輪詢間隔（秒），最小 1 | `3` |
| `sound` | `Silent`、內建音效名稱，或音效檔路徑 | `Alarm` |
| `soundLoopSeconds` | 自訂音效的循環行為（[音效設定](#音效設定)） | `0` |
| `urgent` | 標記為重要通知，可穿透「專注助理」 | `true` |
| `skipCertificateCheck` | 略過 TLS 憑證驗證 | `true` |
| `identifyBy` | 用什麼識別方式：`auto` / `diskId` / `serial` | `auto` |
| `watchIds` | 只監控指定識別碼的裝置，留空監控全部 Serial | `[]` |

## 音效設定

**內建音效**（由 Windows 通知系統播放）：
`Default`、`IM`、`Mail`、`Reminder`、`SMS`、`Alarm`～`Alarm10`、`Call`～`Call10`、`Silent`

**自訂音效**：把 `sound` 填成音效檔路徑即可，相對路徑以 `monitor.ps1` 所在資料夾為基準。

```json
"sound": "sounds/alarm.wav",
"soundLoopSeconds": -1
```

自訂音效由腳本自己播放、通知本身設為靜音。因為 Windows 通知平台在載入自訂音效失敗時會**靜默 fallback 成預設音而不報錯**，對「一定要被聽見」的場合不夠可靠。

| `soundLoopSeconds` | 行為 |
| --- | --- |
| `0` | 播放一次就停 |
| `> 0` | 循環播放，N 秒後自動停止 |
| `-1` | 持續循環，直到在監控視窗按任意鍵 |

格式建議用 `.wav`（走 .NET 內建的 `SoundPlayer`，最穩定）。`.mp3` / `.wma` 會改用 Windows Media Player COM 元件。找不到檔案時會印出警告並退回內建的 `Alarm`。

## 裝置識別方式（identifyBy）

| 值 | 行為 |
| --- | --- |
| `auto` | 優先用 diskId，沒有才改用序號（建議） |
| `diskId` | 只用 diskId |
| `serial` | 只用 USB Serial |

**diskId 是磁碟分割表裡的識別碼** —— GPT 磁碟用磁碟 GUID，MBR 磁碟用磁碟簽章。它有幾個關鍵優勢：

- **存在硬碟本身**，跟著硬碟走，換 USB Port、換電腦都不會變
- **不受晶片影響**，外接盒本身會自帶序號，通常同一批出來的號碼全部都一樣，因此不使用此外接盒之晶片序號
- **不需要掛載**，BitLocker 上鎖、未格式化、非 Windows 檔案系統都讀得到
- **可以事先讀取**，可預先把 config 全部備妥

**什麼時候會變：** diskId 存在分割表裡，所以只有動到**分割表**的操作才會改變它。

| 操作 | diskId |
| --- | --- |
| 格式化磁碟區（快速或完整）、刪檔案 | 不變 |
| 刪除分割區後重建、初始化磁碟、`diskpart clean` | 改變 |
| MBR ↔ GPT 轉換 | 改變（型態也會從 `SIG-xxx` 換成 GUID 或反之） |

**鏡像複製限制：** 從同一個鏡像檔複製出來的硬碟，diskId 會相同。比方說利用軟體，可以將硬碟的所有分區設定 (分區大小、格式、頁面數量等)，完全複製到另外一個硬碟，有時候為了快速大量重建分區會採用此方式，不過通常外接硬碟不會有這狀況（`collect-serials.ps1` 會偵測並警告）。

`watchIds` 兩種識別碼都比對得到，所以填 GUID、填序號、或兩者混用都可以。GUID 的大括號會自動去除，大小寫不拘。舊設定的 `watchSerials` 欄位仍然有效。

## 監控特定硬碟

`watchIds` 留空（`[]`）時監控所有 USB 磁碟。要鎖定特定裝置就填入識別碼：
```json
# Example
"watchIds": ["8CC7E79D-0033-4852-9390-AFEA5304B70B", "SIG-965F8964"]
```

沒列在裡面的 USB 磁碟會被完全忽略 —— 不跳通知、不叫、不回報。

**查識別碼**：直接執行 `run.bat`，啟動時會列出目前接上的**所有** USB 磁碟，並標示哪些正在監控：

```
# Example
USB disks currently attached: 2
  [watching] CT500MX5 00SSD1
             diskId: 8CC7E79D-0033-4852-9390-AFEA5304B70B
             serial: 676038EE1A62
             key   : 8CC7E79D-0033-4852-9390-AFEA5304B70B
  [ignored]  KINGSTON SA400S37240G
             diskId: SIG-965F8964
             serial: 0000000000000000
             key   : SIG-965F8964
```

`key` 是這顆裝置實際拿來比對的值（依 `identifyBy` 決定）。把需要的 `diskId` 複製進 `watchIds` 即可。若填的識別碼目前一顆都沒接上，啟動時會跳警告提醒你檢查是否打錯。

要一次部屬多顆，可用 `collect.bat` 比較方便，見[多場地部署](#多場地部署)。

> **序號（`serial`）來自 USB Serial 晶片，不一定來自硬碟本身。** 部分便宜外接盒會整批回報相同序號，甚至回報全 0。這正是預設 `identifyBy` 用 `auto`（優先 diskId）的原因 —— 請**每顆裝置實際插上跑一次**確認，不要照抄型錄或規格書。

## 識別碼重複時 (Serial Mode Only)

### 單機單顆的情況不受影響
每台機器只看得到自己那顆硬碟，識別碼只需要在該台機器內唯一。就算 20 個場地的硬碟序號全部相同，各站的 `watchIds` 照樣正確比對，回報到 server 的紀錄也靠 `computer` 欄位（= 場地名稱）區分得出來。

### 單機兩顆以上識別碼相同的裝置
腳本靠**數量比對**偵測拔除（`Get-DiskDelta`），所以 2 顆變 1 顆會正確觸發一次告警、3 顆一次拔 2 顆會觸發兩次；但**告警訊息無法指出是哪一顆**。啟動時偵測到重複會主動印出警告。

已知限制：同一個輪詢週期內「拔掉一顆、插上另一顆識別碼相同的」會因為總數不變而偵測不到。

要檢視所有候選識別欄位，插上兩顆後執行：

```powershell
.\tools\collect-serials.ps1 -Detail
```

會列出 `SerialNumber`、`UniqueId`、`Signature`、`Guid`、`Path`、`PNPDeviceID`。其中 `Path` 與 `PNPDeviceID` 編碼了 USB 埠位置 —— 同款裝置插在不同埠會不同，但**換一個埠插就會變**，而且要接上才知道，所以不適合用來事先備妥設定。



## 多場地部署

要在多個場地各裝一套時，不需要一台一台手動填 config。流程分兩步。

### 步驟一：收集識別碼

以**管理員權限**執行 `collect.bat`，然後把硬碟一顆一顆插上去。

（`collect.bat` 等同於執行下面這行，只是順便繞過執行原則限制。）

```powershell
.\tools\collect-serials.ps1 -Watch -Detail -OutFile ..\deploy-table.csv
```

每插入一顆就會印出一列並即時寫檔（中途 Ctrl+C 也不會遺失已收集的資料）。之後用 Excel 打開補上 `deployAt` 欄位即可。

工具會主動抓取兩種問題：

- **序號可疑** —— 空值、全 0、已知的預設佔位序號、長度過短
- **序號重複** —— 兩顆實體不同的硬碟回報同一組序號

序號重複就是前面說的便宜外接盒問題。碰到就代表那款盒子不能用 `watchSerials` 識別，得換盒子或改用其他識別方式。

### 步驟二：產生各場地的套件

映射表可用 JSON 或 CSV（副檔名 `.csv` 會自動以 CSV 解析），三個必要欄位：

| 欄位 | 說明 |
| --- | --- |
| `deployAt` | 部署場地，會成為資料夾名稱與 `computerName` |
| `ssdName` | SSD 型號，僅作記錄用，會寫進 manifest |
| `diskIds` | 磁碟識別碼，會成為 `watchIds`（建議用這個） |
| `serials` | USB 序號，同樣會進 `watchIds`；與 `diskIds` 擇一或並用 |

```csv
# Example
deployAt,ssdName,diskIds,serials
攤位 A,Crucial MX500 500GB,A57F2BCF-20BF-4680-981E-56D539D61D48,676038EE1A62
攤位 A,Samsung T7 1TB,FFE7CF8A-7ADB-4211-919B-6CB273127007,
攤位 B,Crucial MX500 500GB,0E8C485B-CD80-4E92-AE3F-8BE7D3297CAA,676038EE1A62
```

`collect-serials.ps1 -OutFile` 產生的 CSV 已經含有這四個欄位，只要補上 `deployAt` 即可。同一批外接盒序號重複沒關係 —— `diskIds` 不同就分得出來。

同一個 `deployAt` 可以佔多列（一顆硬碟一列），識別碼會自動合併。JSON 格式則可直接把 `diskIds` 寫成陣列，範例見 `deploy-table.example.json`。

```powershell
.\tools\deploy.ps1                          # 讀 deploy-table.json
.\tools\deploy.ps1 -Table ..\sites.csv      # 讀 CSV
.\tools\deploy.ps1 -ConfigOnly              # 只產生 config.json，不複製檔案
```

輸出到 `deploy\<場地名稱>\`，每個資料夾都是可直接壓縮寄出的完整套件（`monitor.ps1`、`run.bat`、`Modules\`、`sounds\`、`config.json`），另外產生一份 `deploy\manifest.csv` 記錄哪個場地配了哪些序號。

其餘設定（`serverUrl`、`apiKey`、音效等）由根目錄的 `config.json` 當範本繼承。**表格中任何額外欄位只要名稱對得上 config 的鍵，就會覆寫該場地的設定** —— 例如加一欄 `serverUrl`，就能讓不同場地回報到不同伺服器。

#### 建置前的檢查

以下情況會直接中止（可用 `-Force` 強制建置）：

- 某列缺少 `deployAt` 或 `serials`
- **同一組序號被指派給多個場地** —— 不是複製貼上錯了，就是遇到了廉價外接盒回報重複序號的問題。兩種情況都會讓白名單失去意義

建置過程中還會驗證檔案有沒有完整複製。Windows 的路徑上限是 260 字元，而 BurntToast 內部最深的路徑就佔了 123 字元，所以輸出路徑過長時 `Copy-Item` 會靜默漏檔 —— 工具會事先算好並擋下，也會在複製後比對檔案數量。有任何一個套件不完整就以非 0 結束並明確標示，不會出貨壞掉的包。

## Server side Recieve Format
**JSON**
- computer  :電腦名稱（部署時 = 場地名稱）
- model     :裝置型號
- diskId    :磁碟識別碼（GPT GUID 或 `SIG-XXXXXXXX`），磁碟未初始化時為 null
- serial    :USB 序號，不保證唯一
- timestamp :事件發生時間戳印（ISO 8601，含時區）
- event     :狀態，有 "removed" 和 "connected" 兩種

```json
{"computer":"攤位 A","model":"KINGSTON SA400S37240G","diskId":"SIG-965F8964","serial":"0000000000000000","timestamp":"2026-07-27T12:43:36.2279495+08:00","event":"removed"}
```

> ⚠️ **Server 端要用 `diskId` 而非 `serial` 來識別裝置。** 上面的範例就是實際案例 —— 那顆外接盒的 `serial` 是 `0000000000000000`，20 個場地的紀錄會長得一模一樣；`diskId` 才分得出是哪一顆。

回傳失敗的事件會累積寫進 `failed-events.log`，不會遺失。

## Releases
#### v1.6 2026/7/27
- 回傳給 server 的 payload 新增 `diskId` 與 `key` 欄位；`serial` 不再是唯一識別依據
- 通知與 console 訊息改為顯示識別碼，不再顯示可能全 0 的序號

#### v1.5 2026/7/27
- 新增 `identifyBy`，可改用磁碟 GUID／簽章（存在硬碟分割表裡）識別裝置，解決同批外接盒序號重複的問題
- `watchSerials` 更名為 `watchIds`，兩種識別碼都比對得到，舊欄位仍相容
- `collect-serials.ps1` 輸出 diskId 並偵測「硬碟被複製」導致的 GUID 重複
- 部署映射表新增 `diskIds` 欄位

#### v1.4 2026/7/26
- **修正：同一台機器上多顆相同序號的裝置會被摺疊成一筆，導致拔除時完全不告警。** 改用數量比對偵測增減
- 啟動時偵測並警告已接上的裝置有序號重複
- `collect-serials.ps1` 新增 `-Detail`，列出所有候選識別欄位

#### v1.3 2026/7/26
- 新增 `tools\collect-serials.ps1`，可逐一插拔收集序號，並偵測可疑／重複序號
- 新增 `tools\deploy.ps1`，依映射表（JSON / CSV）批次產生各場地的部署套件
- 建置前後檢查序號衝突、路徑長度與複製完整性

#### v1.2 2026/7/26
- 新增 `watchSerials`，可只監控指定序號的裝置
- 啟動時列出所有已接上的 USB 磁碟與序號，方便查詢；序號全數對不上會發出警告

#### v1.1 2026/7/26
- 設定改由 `config.json` 驅動，`monitor.ps1` 不再由 HTML 生成
- 支援自訂音效檔（.wav / .mp3 / .wma）與循環播放
- 支援 `urgent` 通知（穿透專注助理）與可切換的 TLS 憑證驗證
- `Get-Disk` 查詢失敗時跳過該輪，避免誤判成「全部裝置被拔除」
- 沒有序號的裝置改用 `磁碟編號 + 型號` 當識別鍵

#### v1.0 2026/7/11
Add the features
- Support gen the monitoring program by the html
- Support modifing the alarm sound