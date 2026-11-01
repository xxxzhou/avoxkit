# 生成侧载用自签 MSIX 签名证书: build/avoxkit-store.pfx
# 主题须与 pubspec msix_config.publisher 一致; 内联 bash 造证书会丢
# Code Signing EKU(装包报 0x800B0109), 必须走本脚本。
# 入库 TrustedPeople+Root 需要管理员 PowerShell。
param(
  [string]$Password = "avx123",
  [string]$Subject = "CN=31E15229-A9B5-4A96-B8F3-8F02865815FF"
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$pfx = Join-Path $root "build/avoxkit-store.pfx"

$existing = Get-ChildItem Cert:\CurrentUser\My |
  Where-Object { $_.Subject -eq $Subject -and
    $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date) } |
  Sort-Object NotAfter -Descending | Select-Object -First 1
if ($existing) {
  $cert = $existing
  Write-Host "reuse existing cert $($cert.Thumbprint)"
} else {
  $cert = New-SelfSignedCertificate -Type Custom -Subject $Subject `
    -KeyUsage DigitalSignature -FriendlyName "avoxkit msix sign" `
    -CertStoreLocation "Cert:\CurrentUser\My" `
    -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.3", "2.5.29.19={text}") `
    -NotAfter (Get-Date).AddYears(5)
  Write-Host "created cert $($cert.Thumbprint)"
}

$secure = ConvertTo-SecureString -String $Password -Force -AsPlainText
$staging = Join-Path $env:TEMP ("avoxkit-sign-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $staging | Out-Null
Export-PfxCertificate -Cert $cert -FilePath $pfx -Password $secure | Out-Null
$cer = Join-Path $staging "avoxkit-store.cer"
Export-Certificate -Cert $cert -FilePath $cer | Out-Null

# 公钥入本机信任链后侧载才认签名(0x800B0109 = 没进 TrustedPeople/Root)
foreach ($store in "Root", "TrustedPeople") {
  try {
    Import-Certificate -FilePath $cer -CertStoreLocation "Cert:\LocalMachine\$store" | Out-Null
    Write-Host "imported to LocalMachine\$store"
  } catch {
    Write-Warning "import to LocalMachine\$store failed (need admin PowerShell): $_"
  }
}
Remove-Item -Recurse -Force $staging
Write-Host "pfx: $pfx"
