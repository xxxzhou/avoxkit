param(
  [string]$Flutter = "D:/Work/flutter/bin/flutter",
  [string]$Config = "Release",
  [string]$Dist = "dist/avoxkit-windows-x64"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

if (-not (Test-Path $Flutter)) {
  $cmd = Get-Command flutter -ErrorAction SilentlyContinue
  if (-not $cmd) { throw "flutter not found; pass -Flutter <path>" }
  $Flutter = $cmd.Source
}

cmake -S native/avtool -B native/avtool/build -G "Visual Studio 17 2022" -A x64
if ($LASTEXITCODE -ne 0) { throw "cmake configure failed" }
cmake --build native/avtool/build --config $Config --parallel 8
if ($LASTEXITCODE -ne 0) { throw "native build failed" }

& $Flutter pub get
if ($LASTEXITCODE -ne 0) { throw "flutter pub get failed" }
& $Flutter build windows --release
if ($LASTEXITCODE -ne 0) { throw "flutter build failed" }

$src = Join-Path $root "build/windows/x64/runner/Release"
if (-not (Test-Path (Join-Path $src "avoxkit.exe"))) {
  throw "avoxkit.exe not found at $src"
}
if (Get-Process avoxkit -ErrorAction SilentlyContinue) {
  throw "avoxkit.exe is running; close it before packaging"
}

if (Test-Path $Dist) { Remove-Item -Recurse -Force $Dist }
New-Item -ItemType Directory -Force -Path $Dist | Out-Null
Copy-Item (Join-Path $src "*") $Dist -Recurse -Force

Write-Host ""
Write-Host "portable build: $Dist"
Write-Output (Join-Path $Dist "avoxkit.exe")
