# Avoxkit 隐私政策 / Privacy Policy

生效日期：2026-10-31

Avoxkit 是一个本地优先（local-first）的 macOS 音视频工具箱。

## 我们收集什么

**不收集任何个人数据。** Avoxkit 没有账号系统、没有登录、没有云端服务，也不含广告或第三方分析 SDK。

## 文件如何处理

- 你选择的音视频和图片只在这台电脑上读取和处理，不会上传到任何服务器。
- 处理结果写入你指定的位置；Mac App Store 版本默认写入应用容器内的 `Documents/Avoxkit`（在 Finder 中显示为 App 的本地文稿目录）。
- 应用不读取与你选择的任务无关的文件。

## 系统权限

- **屏幕录制**：仅在你主动开始录屏时使用，画面只写入本地文件。
- **麦克风**：仅在你打开麦克风开关并开始录屏时使用，音频只写入本地文件。
- 你可以随时在「系统设置 → 隐私与安全性」中撤销权限；撤销后录屏功能不可用，其它功能不受影响。

## 网络访问

Avoxkit 只在你使用「提取字幕」或「图像修复」且本地模型尚未安装时访问网络，从公开模型仓库下载模型文件（ONNX 权重和词表）。下载请求不包含你的音视频内容或个人信息。模型下载完成后，这些功能可完全离线使用。格式转换、截取片段、提取音频不需要网络。

## 数据留存与删除

应用不保存你的使用记录到服务器。任务历史只保存在本机应用数据目录；卸载 App 或删除其容器目录即删除全部本地数据。

## 儿童隐私

Avoxkit 不面向儿童收集任何数据，也不包含广告或内购。

## 变更

本政策更新时会修改本页面的生效日期。

## 联系方式

如有隐私相关问题，请发邮件至 mfjt55@163.com，或在 https://github.com/xxxzhou/avoxkit/issues 提交 issue。

---

## English summary

Avoxkit is a local-first macOS audio/video toolbox. It collects no personal data, has no account system, no cloud service, no ads and no third-party analytics. Files you select are processed only on your Mac and are never uploaded. Screen Recording and Microphone permissions are used only while you record, and the output stays in local files. Network access happens only to download optional on-device model weights for subtitles/image repair; the requests contain no media or personal data. Contact: mfjt55@163.com.
