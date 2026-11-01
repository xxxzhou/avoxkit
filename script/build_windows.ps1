param(
  [string]$Flutter = "D:/Work/flutter/bin/flutter",
  [string]$Config = "Release",
  [string]$Dist = "dist/avoxkit-windows-x64",
  # -Msix  出侧载冒烟包(需 build/avoxkit-store.pfx, 用 script/msix_sign.ps1 生成)
  # -Store 出商店上传包(免签; 与 -Msix 互斥)
  [switch]$Msix,
  [switch]$Store
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

# x264/x265 经 libstdc++ 依赖 MinGW 的 libgcc; 缺它时只有 PATH 里带 mingw64
# 的环境能启动, 普通双击报 error 126。kit 不完整时从 MSYS2 补齐。
$kitBin = Join-Path $root "third_party/ffmpeg/kit/bin"
$libgcc = Join-Path $kitBin "libgcc_s_seh-1.dll"
if (-not (Test-Path $libgcc)) {
  $msys = $env:MSYS2_INSTALL_DIR
  if (-not $msys) { $msys = "C:\msys64" }
  $candidate = Join-Path $msys "mingw64/bin/libgcc_s_seh-1.dll"
  if (-not (Test-Path $candidate)) {
    throw "ffmpeg kit 缺 libgcc_s_seh-1.dll, 且 $candidate 不存在"
  }
  Copy-Item $candidate $libgcc
  Write-Host "copied libgcc_s_seh-1.dll from $candidate"
}

if (-not (Test-Path $Flutter)) {
  $cmd = Get-Command flutter -ErrorAction SilentlyContinue
  if (-not $cmd) { throw "flutter not found; pass -Flutter <path>" }
  $Flutter = $cmd.Source
}
# 无扩展名的 flutter 是 bash 启动器: PowerShell 会交给 ShellExecute 立即返回,
# 打包时拿到的是旧 app.so; 一律走 .bat 才能同步等待并拿到退出码
if ([IO.Path]::GetExtension($Flutter) -ne ".bat" -and
    (Test-Path "$Flutter.bat")) {
  $Flutter = "$Flutter.bat"
}

cmake -S native/avtool -B native/avtool/build -G "Visual Studio 17 2022" -A x64
if ($LASTEXITCODE -ne 0) { throw "cmake configure failed" }
cmake --build native/avtool/build --config $Config --parallel 8
if ($LASTEXITCODE -ne 0) { throw "native build failed" }

& $Flutter pub get
if ($LASTEXITCODE -ne 0) { throw "flutter pub get failed" }
# 增量缓存会留着旧的 icon tree-shake 子集: 源码比字体新就清掉, 否则图标缺字
$iconFont = Join-Path $root "build/flutter_assets/fonts/MaterialIcons-Regular.otf"
$newestDart = Get-ChildItem (Join-Path $root "lib") -Recurse -Filter *.dart |
  Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($newestDart -and (-not (Test-Path $iconFont) -or
    $newestDart.LastWriteTime -gt (Get-Item $iconFont).LastWriteTime)) {
  Remove-Item (Join-Path $root ".dart_tool/flutter_build") -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item (Join-Path $root "build/flutter_assets") -Recurse -Force -ErrorAction SilentlyContinue
}
& $Flutter build windows --release
if ($LASTEXITCODE -ne 0) { throw "flutter build failed" }

$src = Join-Path $root "build/windows/x64/runner/Release"
if (-not (Test-Path (Join-Path $src "avoxkit.exe"))) {
  throw "avoxkit.exe not found at $src"
}
$running = Get-Process avoxkit -ErrorAction SilentlyContinue
if ($running) {
  throw "avoxkit.exe is running; close it before packaging"
}

if ($Msix -or $Store) {
  if ($Msix -and $Store) { throw "-Msix 与 -Store 互斥: 侧载签名包与商店免签包分开出" }
  if ($Msix -and -not (Test-Path (Join-Path $root "build/avoxkit-store.pfx"))) {
    throw "缺 build/avoxkit-store.pfx: 先跑 powershell -ExecutionPolicy Bypass -File script/msix_sign.ps1"
  }
  # msix:create 内部会重跑 flutter build, 属预期; 收尾交互提示自动喂 n
  $dart = "D:/Work/flutter/bin/dart.bat"
  if (-not (Test-Path $dart)) { $cmd = Get-Command dart -ErrorAction SilentlyContinue; if (-not $cmd) { throw "dart not found" }; $dart = $cmd.Source }
  $flag = ""
  if ($Store) { $flag = " --store" }
  Push-Location $root
  try {
    cmd /c "echo n | `"$dart`" run msix:create$flag"
    if ($LASTEXITCODE -ne 0) { throw "msix:create failed" }
  } finally { Pop-Location }
  $msixPath = Join-Path $src "avoxkit.msix"
  if (-not (Test-Path $msixPath)) { throw "avoxkit.msix not found at $src" }
  Write-Host ("msix: {0} ({1:N1} MB)" -f $msixPath, ((Get-Item $msixPath).Length/1MB))
}

# 先拷到临时目录再整体换入: 直接删 dist 重建时, 用户在窗口期启动会
# 撞上 "avoxkit_native.dll not found" (error 126)
$distPath = [IO.Path]::GetFullPath((Join-Path $root $Dist))
$staging = "$distPath.staging-" + [guid]::NewGuid().ToString("N")
New-Item -ItemType Directory -Force -Path $staging | Out-Null
# robocopy 比 Copy-Item 稳: 目录/锁文件竞态下不会静默留下旧 DLL
& robocopy $src $staging /E /COPY:DAT /R:2 /W:1 /NFL /NDL /NJH /NJS | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy failed: $LASTEXITCODE" }

# 锁文件/竞态会让复制留下旧产物; 关键文件时间戳不一致直接失败
$required = @(
  "avoxkit.exe",
  "avoxkit_native.dll",
  "avox.dll",
  "libgcc_s_seh-1.dll",
  "plugins\avox_sherpa.dll",
  "plugins\sherpa-onnx-c-api.dll",
  "plugins\onnxruntime.dll",
  "plugins\avox_cv.dll",
  "plugins\avox_onnx.dll",
  "plugins\avox_opencv.dll",
  "plugins\opencv_world4130.dll",
  "assets\glsl\scene.comp.spv",
  "data\app.so"
)
foreach ($name in $required) {
  $srcFile = Join-Path $src $name
  $distFile = Join-Path $staging $name
  if (-not (Test-Path $distFile)) { throw "package is missing $name" }
  if ((Get-Item $distFile).LastWriteTime -lt (Get-Item $srcFile).LastWriteTime) {
    throw "package $name is stale; close avoxkit and rebuild"
  }
  $srcHash = (Get-FileHash $srcFile -Algorithm SHA256).Hash
  $distHash = (Get-FileHash $distFile -Algorithm SHA256).Hash
  if ($srcHash -ne $distHash) { throw "package $name hash mismatch" }
}

if (Test-Path $distPath) { Remove-Item -Recurse -Force $distPath -ErrorAction Stop }
Move-Item -Path $staging -Destination $distPath -ErrorAction Stop

Write-Host ""
Write-Host "portable build: $Dist"
Write-Output (Join-Path $Dist "avoxkit.exe")
