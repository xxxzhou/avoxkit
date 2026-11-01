# Windows 商店发布(执行手册)

状态:2026-10-31 建立 · 打法与坑账沿用内部商店手册, 本文只记 avoxkit 差异
关联: 商店元数据包/分级备注在内部产品仓, 不入本仓

## 0. 口径与红线(先读)

- **三句话**: 免费(无会员无水印)、本地(文件不上传)、无账号(不登录不收集)。
  商店文案全部从 `docs/features.md` 裁剪, 不新增承诺。
- **免费应用**: 无加载项、无内购、无付款/税务配置。
- **市场不含中国大陆**(首版, ICP 未办; 后续放开的决策挂在 §5)。
- **文案红线**: 不提内部仓/姊妹产品; 不写「编辑器」; 不列未实现功能; 素材不用占位图。
- **AGPL 源可用(提审前置, 待用户拍板)**: 商店分发即 AGPL 意义上的「传播」,
  需提供对应源码。本仓已公开, 历史仍含内部内容, 内部信息清理另行挂账。
  提审前二选一: ①描述直接放公开仓链接(推荐, 与定位一致);
  ②书面源码提供路径。未落前描述里的「AGPL-3.0」行保持但不放仓链接。

## 1. 大盘

| 项 | 状态 |
|---|---|
| Partner Center 建品 | ✅ **已建品(2026-10-31)**: 产品 ID `9N3LFW34PTC5`, 保留名 **Avoxkit**, 直链 https://apps.microsoft.com/detail/9N3LFW34PTC5 |
| 包身份回读 | ✅ 与 pubspec 逐字一致: Name `zhouxin.Avoxkit` · Publisher `CN=31E15229-A9B5-4A96-B8F3-8F02865815FF` · DisplayName `zhouxin`(PFN `zhouxin.Avoxkit_vqrz1jd4ztkvw`) |
| Submission 1 草稿 | ✅ id `1152921505702284306`(2026-10-31); **属性✅完成 · 年龄分级✅完成(IARC 3+ 全族: ESRB E/PEGI 3/USK 0/DJCTQ L) · 定价✅完成(USD 0 档, 240 市场) · 认证说明✅Successfully saved**; 提交选项=过审立即发布(默认) |
| Store 一览 | ✅ 文案全落: `中文(简体)`(languageid 262)+`英语(美国)`(languageid 4) 双语 描述/功能10条/简短描述/版权/开发者 已保存; **`中文(简体)(中国)` 行已删**(无 ISBN, 留着堵提交); ⬜ **未完成=只差截图(≥1张/语言, 用户手传)** |
| MSIX 上传包 | ✅ 已出并核验: `build\windows\x64\runner\Release\avoxkit.msix` 61.1 MB, sha256 `21bfffd9…`, Identity 0.1.0.0, **无签名(store 上传包免签, 商店侧签)**, 磁贴=品牌图; ⬜ **未上传(用户手传)** |
| MSIX 打包链 | ✅ pubspec `msix_config` + `script/build_windows.ps1 -Msix/-Store` + `script/msix_sign.ps1`(证书=同 Publisher 复用, 已入信任链); 侧载冒烟包解包+验签全绿(2026-10-31) |
| 磁贴母版 | ✅ `windows/runner/resources/app_icon_1024.png`(由现有 ico 逐像素提取重绘, 10.1.1.11 规避) |
| 商店元数据包 | ✅ 内部产品仓维护(双语一览+IARC+认证备注, 不入本仓) |
| 隐私页 | ✅ 起革 `xxxzhou.github.io/avoxkit-privacy.html` + `-zh.html`(本地, **未推送上线**) |
| 市场/中国大陆 | ✅ 按内部已上架产品实际配置走**全球 240 市场**; 中国区因无 ISBN 自动不可售(市场选择器 DOM 不反映勾选态, 逐市场排除不可靠); 后续走 ISBN/ICP 激活 |
| 提审 | ❌ 等: 用户传包+传截图 → 「提交进行认证」按钮解锁 → 提交 |

## 2. Partner Center 操作(差异项)

全流程打法(建品/保留名/身份/一览/分级/定价/提审/坑)照内部商店手册 §2, 此处只列 avoxkit 差异:

1. 建品: 新产品 → **MSIX 或 PWA 应用** → 保留名 **`Avoxkit`**。
2. 身份: 产品管理→产品标识, 回读 Name/Publisher/PublisherDisplayName。
   Name 大概率 `zhouxin.Avoxkit`, **以回读为准**改 pubspec。
3. 一览: 先填 zh-cn(元数据包 §2); en-us 槽随包语言出现——但本包只声明
   zh-cn, 需在「添加/删除语言」手动加 en-us(微软一览语言与包语言独立,
   内部产品批量加语言已实证; 若服务静默吞语言, 重加+回概述核对 Complete)。
4. 分级: IARC 问卷照分级文档 §1; **生成式 AI 必须如实勾**(图像修复)。
5. 定价: 免费档 0 USD, 市场全球排除中国大陆; 无需付款档案。
6. 提交选项: 尽快发布。

## 3. MSIX 打包 SOP

```bash
# 0) 杀掉在跑实例(Release DLL 会被锁)
taskkill //IM avoxkit.exe //F
# 1) 侧载冒烟包(首次先造证书, 管理员 PowerShell 更稳: 公钥入 Root+TrustedPeople)
powershell -ExecutionPolicy Bypass -File script/msix_sign.ps1
powershell -ExecutionPolicy Bypass -File script/build_windows.ps1 -Msix
#    商店上传包(免签): -Store 代替 -Msix
# 2) 装机冒烟
powershell -Command "Add-AppxPackage -Path 'build\windows\x64\runner\Release\avoxkit.msix'"
```

- 证书: `build/avoxkit-store.pfx`(gitignore, 不入仓), 主题=CN=31E15229…(与包
  身份一致, 同一开发者账号的 Publisher); 本机已有同主题证书时脚本
  自动复用。装包 0x800B0109=公钥没进 TrustedPeople/Root。
- 包内容: `build/windows/x64/runner/Release` 全量进包(avox.dll/ffmpeg kit/
  plugins/glsl 由 native CMake 后置拷贝保障; -Msix 内部重跑 flutter build 属
  预期, dist 校验逻辑在其后所以不受影响)。
- **第 4 段版本号恒 0**; 同全名不同内容会被商店拒收(内部实证)。
- 模型不入包(按需下载), 包体积 ~61 MB 正常。
- 元数据不得留模板串: pubspec `description` 已是真实描述, manifest Description
  同源; 改描述时两处一起看。

## 4. 提审清单(2026-10-31 实况)

- [x] Partner Center 建品 + 保留名 Avoxkit(9N3LFW34PTC5)
- [x] 产品标识回读 = pubspec 值, 无需改
- [x] zh-hans + en-us 一览全字段文本(说明/功能/短描述/版权/开发者)
- [x] IARC 问卷(生成式 AI 如实申报=联机内容「是」+子题全否) → 3+ 全族
- [x] 定价 0 档 USD + 240 市场(中国区无 ISBN 自动不可售)
- [x] 认证说明(其他测试信息页, Successfully saved; **保存钮激活后角色翻成 link**, 按 link 点)
- [ ] **用户**: 传包 `build\windows\x64\runner\Release\avoxkit.msix`(程序包页, 61.1 MB)
- [ ] **用户**: 双语截图各 ≥1 张(建议 4-6 张, 1366×768+, 清单见元数据包 §6)
- [ ] **用户**: 隐私页两个 html 推送上线(github.io 仓)
- [ ] **用户**: 侧载冒烟(可选): `Add-AppxPackage` 装侧载包起一遍
- [ ] **决策**: AGPL 源可用落地(§0; 本仓已公开, 差仓链接或书面路径)
- [ ] 提交进行认证(按钮在包+截图齐后解锁) → 盯认证结果

## 5. 挂账与触发器

- **版本号决策**: 现按 pubspec `0.1.0+1` 出 `0.1.0.0`; 若商店首版想标 1.0.0.0
  (内部惯例), 同步改 pubspec version + features.md 版本行 + 重出包, 三处一致。
- **ICP/中国大陆**: 需要时参考内部 ICP 例外流程。
- **多语言一览**: 首版只 zh/en; 13 语铺开稿走「导入文件夹」打法,
  届时再备 CSV。
- **LLM 翻译字幕**(已定形态未实现): 实现后才能进文案; 届时 IARC 生成式 AI
  问卷答案要复核(新增文本生成)。
