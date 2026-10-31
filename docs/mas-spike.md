# macOS 沙盒 / Mac App Store 提交（mas 分支）

状态：2026-10-31 **已重新提审（15 语言）**。ASC App ID `6829203879`，版本 `0.1.0 (build 2)`，
`WAITING_FOR_REVIEW`（提交时间 2026-10-31T13:39:48Z）。首版 build 1 为中文单语，
已撤回；build 2 带 15 个商店 locale 重新提交。

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

## 多语言（2026-10-31）

与 panvox 同一组 15 个商店 locale：`zh-Hans / en-US / zh-Hant / ja / ko / fr-FR /
de-DE / es-ES / it / pt-PT / pt-BR / ru / id / th / vi`。

- UI：以中文原文为 key 的轻量 i18n（`lib/core/i18n.dart` 的 `tr()/T`），
  14 份 `assets/i18n/*.json`；数字归一成 `{n}`、其它变量用 `{x}` 模板匹配；
  设置页语言选择器，立即生效并写 `locale.txt` 持久化。
- 商店：15 个 locale 的名称/副标题/描述/关键词/支持 URL/隐私 URL 全量；
  每个 locale 3 张 2560×1600 截图（`Screenshots/mas/i18n/<locale>/`）。
- 取舍：机翻初稿 + 50 个核心术语人工覆盖；技术长句（编码器/容器提示）仍是
  机翻水平，后续按用户反馈迭代。

## 已提交（2026-10-31）

1. ASC 建 App 记录：macOS / Avoxkit / 简体中文 / `dev.avox.avoxkit` / SKU `avoxkit.mas`。
2. 上传 `dist/avoxkit.pkg`：build 1（中文）→ 撤回；build `d6fb4e05…`（15 语言）
   处理为 `VALID`，已挂到 0.1.0。
3. 元数据：主分类 Photo & Video、副标题、描述、关键词、支持 URL、
   隐私政策 URL（`https://github.com/xxxzhou/avoxkit/blob/main/PRIVACY.md`）、
   版权、年龄分级全「无」、App 隐私「不收集数据」并发布。
4. 截图：`APP_DESKTOP` 15 套 × 3 张 2560×1600，全部 `COMPLETE`。
5. 价格：0 价 schedule（免费）；可售区域 175 个已创建。
6. 审核备注：写了「转换 → 试用示例 → 开始转换」三步路径、模型下载属数据、
   以及本品与账号其它 App 的代码/品类/UI 隔离。
7. 三段式提审成功，状态 `WAITING_FOR_REVIEW`。

## 已知风险（等审核）

- 模型运行时下载 230/290 MB：按 2.4.5(iv) 属数据下载，Notes 已写明端侧推理、
  不下载可执行代码；若审核追问，改为内置默认模型。
- YOLO26-Seg 权重为第三方 AGPL-3.0（未内置，仅按需下载）；后续换
  Apache/MIT 模型或取得商业授权。
- FFmpeg LGPL 静态链进 `avoxkit_native.dylib`：商店版先按 LGPL §6 提供
  源码/可重链接对象（`SOURCE-OFFER.md`）。
- 中国区可能再次触发 `ICP_NUMBER_MISSING`（本地工具，先按 Apple 流程申诉）。
