# COSCUP SSD 拔除警告系統
專門監測於 USB port 上拔除硬體狀態。

## 注意事項
如果要將監控軟體部屬，然後將監控結果回傳至 Server
Server 應該要具備 api 讓程式能將結果回傳

## Install 
1. 使用瀏覽器開啟 Generator.html
2. 依序填寫下列欄位
```python
PC_name：就是電腦本身的名稱
```
```python
API URL：傳給監控 server 的 URL
# 預設值：https://localhost:8443/api/usb-event
```
```python
API Key：同上，對應的 API Key
# 預設值：your-secret-api-key-here
```
```python
alarmType：報警鈴聲種類
```
```python
CycleTime：每隔幾秒查一次 IO (建議不要太高)
# 預設 3 secs
```
3. 點選下載，會自動產生一個檔案為 monitor.ps1
4. 把下載的檔案移動到資料夾內
5. 利用**管理員權限**執行 run.bat
#### __Warning__
* __bat 檔預設檔名是 monitor.ps1__
* __bat 檔會強制繞過未簽章之檔案，請先確認 monitor.ps1 不是惡意程式__

## Return Format
**JSON**
- computer  :電腦名稱
- model     :裝置名稱
- serial    :裝置對應之 Serial ID (Unique)
- timestamp :事件發生時間戳印
- event     :狀態，有 "removed" 和" connected" 兩種

## Releases
#### v1.0
Add the features
- Support gen the monitoring program by the html
- Support modifing the alarm sound


