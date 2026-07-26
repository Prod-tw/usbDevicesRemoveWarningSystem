# 1. 建立憑證
$cert = New-SelfSignedCertificate `
    -DnsName "prodtw-monitor-server.local" `
    -CertStoreLocation "cert:\CurrentUser\My" `
    -NotAfter (Get-Date).AddYears(1) `
    -KeyExportPolicy Exportable `
    -KeyUsage DigitalSignature, KeyEncipherment `
    -Type SSLServerAuthentication

# 2. 建立輸出資料夾
New-Item -Path "C:\certs" -ItemType Directory -Force

# 3. 匯出成 pfx
$pwd = ConvertTo-SecureString -String "prodtw-export-password" -Force -AsPlainText
Export-PfxCertificate -Cert $cert -FilePath "D:\Desktop\Code\ProdTW\SSDRemoveWarning\server.pfx" -Password $pwd