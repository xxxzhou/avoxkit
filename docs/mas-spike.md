# macOS 沙盒 / Mac App Store 提交（mas 分支）

状态：2026-10-31 进行中。本地可出带 Apple Distribution 签名、描述文件与沙盒
entitlements 的 `.pkg`；**待 ASC 网页建 App 记录后上传**。

## 目标

1. 沙盒 entitlements 下启动、文件选择（powerbox）、录屏、模型下载可用；
2. 输出从“源文件旁”改到 app 容器；
3. 用正式分发证书出可上传 Mac App Store 的包。

## 构建

分发包（Apple Distribution + 内嵌描述文件）：

```bash
MAS=1 ./script/build_macos.sh
productbuild --component dist/avoxkit-macos-arm64-mas/avoxkit.app /Applications \
  --sign "3rd Party Mac Developer Installer: Xin Zhou (Y96Y9F6CFS)" \
  --keychain "$HOME/Library/Keychains/avoxkit-signing.keychain-db" dist/avoxkit.pkg
```

本地 QA / 截图包（自签 `panvox-dev`，不带 Team 标识，能直接启动）：

```bash
MAS=1 CODESIGN_IDENTITY=panvox-dev MAS_PROFILE= \
  DIST="$PWD/dist/avoxkit-mas-demo" DEMO=1 ./script/build_macos.sh
```

> 分发签名带 `CS_RESTRICT`，直接 `open` 会 `RBSRequestErrorDomain 163`；
> 这是 App Store 包的正常行为，验收走 `.pkg` 安装/商店安装，不要用本地双击判断。

## 凭证与签名（不进仓库）

- 证书：`Apple Distribution: Xin Zhou (Y96Y9F6CFS)`、
  `3rd Party Mac Developer Installer: Xin Zhou (Y96Y9F6CFS)`。
- 描述文件：`Avoxkit Mac App Store`（MAC_APP_STORE）。
- 签名钥匙串：`~/Library/Keychains/avoxkit-signing.keychain-db`；
  密码在 `~/.appstoreconnect/avoxkit/keychain-password`；
  证书/CSR/描述文件同目录。
- Bundle ID：`dev.avox.avoxkit`（UNIVERSAL，seed `Y96Y9F6CFS`）。

## 改动

- `Release-MAS.entitlements`：沙盒、网络、用户选择文件、bookmark、麦克风，
  外加描述文件授权的 `application-identifier` / `team-identifier` / keychain group。
- `build_macos.sh`：`MAS=1` 用 MAS entitlements、切容器输出、嵌描述文件、
  用签名钥匙串；`DEMO=1` 打开自动示例（仅截图/审核演示）。
- `app_paths.dart` / `sample_media.dart`：沙盒输出统一到容器 `Documents/Avoxkit`；
  内置 8 秒示例片段，转换页「试用示例」一键载入。
- `PrivacyInfo.xcprivacy`：无收集、无追踪；声明 UserDefaults 与文件时间戳。
- 截图：`Screenshots/mas/01-convert.png`、`02-record.png`、`03-about.png`，
  均 2560×1600。

## 已验证（2026-10-31）

- `codesign --verify --deep --strict` 通过；Authority 到 Apple Root CA；
  TeamIdentifier `Y96Y9F6CFS`；`flags=0x10000(runtime)`。
- entitlements 与描述文件一致；`Contents/embedded.provisionprofile` 存在。
- `productbuild` 签名成功；`altool --validate-app` 仅因 App 记录未建而报
  `Unable to find Apple ID for Bundle ID`，说明包本身可进入上传校验。
- 自签沙盒包：启动正常，容器、`Documents/Avoxkit`、模型/工作目录、录屏路径正确；
  示例自动载入后转换成功，产物落在容器 `Documents/Avoxkit`。
- `flutter analyze` 0 issue；`flutter test` 98/98。

## 剩余

1. ASC 网页建 App 记录（API Key 无 `apps CREATE` 权限）：
   macOS、名称 Avoxkit、简体中文、Bundle ID `dev.avox.avoxkit`、SKU `avoxkit.mas`。
2. 上传 `.pkg`，等 `processingState=VALID`；挂到版本。
3. 元数据：分类（摄影与录像）、年龄分级、隐私/支持 URL、审核备注、截图。
4. 提审三段流；4.3 说明按「不同品类 + 不同 UI 范式 + 独立代码库」写进 Notes。
5. 模型运行时下载（230/290 MB）在 2.4.5(iv) 属数据非代码，Notes 明确
   “on-device inference, no executable code downloaded”；若被追问再改内置。
6. YOLO26-Seg 权重是第三方 AGPL-3.0；商店包未内置，只按需下载，后续换
   Apache/MIT 模型或取得商业授权。
7. FFmpeg LGPL 静态链进 `avoxkit_native.dylib`；商店版先按 LGPL §6 提供
   可重链接对象/源码（`SOURCE-OFFER.md`），后续再考虑拆 dylib。
