# macOS 沙盒 / Mac App Store 最小验证（mas 分支）

状态：2026-10-31 起步，只验证可行性，**未提交 App Store**。

## 目标

在不改现有 DMG 发布链的前提下，验证三件事：

1. 沙盒 entitlements 能否正常启动 app；
2. 模型下载（网络）、文件选择（powerbox）、录屏（麦克风）在沙盒下是否可用；
3. 输出路径从“源文件旁”改到 app 容器是否可行。

## 构建

```bash
MAS=1 CODESIGN_IDENTITY=panvox-dev ./script/build_macos.sh
```

产物：`dist/avoxkit-macos-arm64-mas/avoxkit.app`（自签、沙盒），不覆盖 DMG 包。

## 改动

- `macos/Runner/Release-MAS.entitlements`：`app-sandbox`、`network.client`、
  `files.user-selected.read-write`、`files.bookmarks.app-scope`、`device.audio-input`。
- `script/build_macos.sh`：`MAS=1` 时使用该 entitlements，并加
  `--dart-define=AVOXKIT_SANDBOX=true`，输出到独立 `dist/` 目录。
- `lib/core/app_paths.dart`：沙盒下建议输出到
  `~/Library/Containers/dev.avox.avoxkit/Data/Documents/Avoxkit`；
  convert / clip / subtitle / repair 与批量输出统一切到该根。
- 录屏页本来就用 `$HOME/Videos/Avoxkit 录屏`；沙盒下 `HOME` 是容器，无需改。

## 已验证（2026-10-31）

- `codesign --entitlements`：5 项都在，`app-sandbox=true`。
- 启动：app 进程正常，avox 引擎 init 全过（fdk / Vulkan / ffmpeg / sherpa 等）。
- 容器：`~/Library/Containers/dev.avox.avoxkit/Data` 生成；
  `Application Support/dev.avox.avoxkit/{models,work}` 正常；
  `Documents/Avoxkit` 由 `AppPaths.init` 创建；
  录屏页输出路径显示容器内 `Videos/Avoxkit 录屏`。

## 仍需验证 / 改造

1. 手动在「转换 / 裁剪 / 字幕 / 修复 / 批量」各选一个文件，确认产物落在
   `Documents/Avoxkit` 且任务成功。本轮 GUI 自动化未跑（Terminal 没有辅助访问权限）。
2. 用户自选输出目录的持久化：`file_selector` 只保证本次会话的 powerbox 授权；
   跨启动要补 security-scoped bookmark（原生 `NSOpenPanel` + bookmarkData）。
3. 模型下载：230/290 MB 运行时下载，2.4.5(iv) 有风险；内置默认模型或改为可选增强。
4. FFmpeg LGPL：目前静态链进 `avoxkit_native.dylib`；MAS 版建议拆成独立 dylib，
   或提供可重链接对象文件，满足 LGPL §6。
5. YOLO26-Seg 权重是 Ultralytics AGPL-3.0（第三方）；若要完全干净的商店包，
   换 Apache/MIT 模型，或取得商业授权。
6. MAS 打包：注册 Bundle ID `dev.avox.avoxkit`、建 ASC macOS app record、
   Apple Distribution / 3rd Party Mac Developer 证书 + 描述文件、应用级隐私清单、
   2560×1600 截图、Review Notes。
7. 4.3：账号 6/9 个 app 仍在 `UNRESOLVED_ISSUES`，建议等结论再提交。

## 结论

沙盒启动、容器、模型目录、录屏路径可行；输出改容器是可行解。剩下两个产品决策：
**用户自选输出目录是否做持久化 bookmark**，以及**模型是否内置**。当前不提交 App Store。
