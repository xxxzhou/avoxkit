# AGENTS.md — avoxkit 会话公约

公开仓(AGPL-3.0)、引流产品。姊妹仓: `D:/Work/github/avox`(引擎, AGPL)、
`D:/Work/github/panvox`(私有付费播放器)。三层漏斗: avoxkit(公开, 流量)→
avox(公开, 背书)→ panvox(商店, 收钱)。改任何东西前先读一遍本文件。

## 身份与边界

- 本仓**只依赖 avox 公共仓**。引擎缺口(mp3 编码、无损剪切 API、字幕写出、
  离线烧录口等)一律在 avox 仓改, 不在本仓 fork 引擎、不打引擎补丁包。
- **不复制 panvox 私有代码**: `pvx_*` shim、Flutter 页面、文档都属于 panvox 仓
  (All rights reserved)。本仓自建 `ak_*` C ABI(见 docs/architecture.md),
  只借鉴思路不搬代码。调研底稿在
  `D:/Work/github/panvox-site/docs/seo/revenue/free-avox-tool-research.md`
  (跨仓, 用绝对路径引)。
- 对外文稿/落地页/发布归 panvox-site 仓 `docs/seo/`, 本仓 README 只放产品事实。

## 许可证红线

- 全仓 AGPL-3.0; 分发即开源, 不接受闭源衍生。
- 出厂 ffmpeg 必须 **gpl flavor + libmp3lame**; 含 nonfree/fdk-aac 的产物
  **任何渠道不可分发**(avox `build_ffmpeg.py` GPL_MARKS 红线), 出厂前跑 `--verify`。

## 文案口径

- 定位=**常规音视频工具**(转换/压缩/提取音频/字幕/无损剪切), 不做剪映式
  多轨剪辑; 对外不说「编辑器」。
- 三句话钉死: 免费(无会员无水印)、本地(文件不上传)、无账号(不登录不收集)。
- 未实现不上 UI; 屏显只代表当前真实行为。
- 术语用「识别/未识别」, 不用「刮削」。

## 工程口径

- 注释从简: 二行内, 只写关键的「为什么」。
- 改文件前重读最新内容(多会话并行); 提交只提本会话改动, 除非明说
  「提交所有更改」。
- Flutter SDK 在 `D:/Work/flutter`(不在 PATH)。构建中断后清
  `.dart_tool/flutter_build` 再重建。
- 与 panvox 相同的坑预设: 改 shim 签名必同步头文件; 陈旧增量缓存会让
  图标/资源出鬼。
