// server.js
const https = require('https');
const fs = require('fs');
const express = require('express');
const helmet = require('helmet');

const app = express();
app.use(express.json());
app.use(helmet());

// 簡單的 API Key 驗證中介層
const API_KEY = 'your-secret-api-key-here'; // 建議改用環境變數
app.use((req, res, next) => {
    const auth = req.headers['authorization'];
    if (auth !== `Bearer ${API_KEY}`) {
        return res.status(401).json({ error: 'Unauthorized' });
    }
    next();
});

// 接收 USB 事件
app.post('/api/usb-event', (req, res) => {
    const { computer, model, serial, deviceId, timestamp, event } = req.body;

    if (!computer || !serial || !event) {
        return res.status(400).json({ error: 'Missing required fields' });
    }

    const record = { computer, model, serial, deviceId, timestamp, event, receivedAt: new Date().toISOString() };

    console.log('[USB Event]', record);

    fs.appendFileSync('usb-events.log', JSON.stringify(record) + '\n');

    res.status(200).json({ status: 'received' });
});

// TLS 憑證設定（讀取 pfx）
const options = {
    pfx: fs.readFileSync('D:\\Desktop\\Code\\ProdTW\\SSDRemoveWarning\\server.pfx'),
    passphrase: 'prodtw-export-password'   // 跟前面 $pwd 設定的密碼一致
};

https.createServer(options, app).listen(8443, () => {
    console.log('HTTPS 伺服器已啟動於 port 8443');
});