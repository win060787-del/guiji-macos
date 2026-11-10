# 归记多语言适配

支持简体中文、繁体中文、英语、西语、土耳其语、日语。默认匹配 macOS 首选语言列表；无支持项时回退英语。引导先选语言；设置与工具栏外观菜单支持随时切换。切换不重建 WorkspaceModel，不改变正文、路径、凭证值与持久化枚举。

## 翻译来源与生成

- `keys.json`：原始中文模板的稳定顺序；保留索引，不重新提取覆盖。
- `translations.tsv`：索引、英语、西语、土耳其语、日语。`\n` 表示换行。
- `additions.json`：新增模板的六语言译文。
- 繁体中文使用本机 Foundation ICU 汉转繁，并应用台湾常用术语替换。
- `manuals.json`、`legal.json`：非中文离线文档来源；简中文档位于应用 Documentation 根目录，繁中由它生成。
- `store.json`：新增商店语言的名称、描述、关键词等；已有简中、英语文案保留在 metadata；繁中从简中生成并覆盖独立关键词。
- `captions.json`：六语言上线图标题和副标题。

运行 `python3 scripts/generate-localizations.py` 生成运行时目录及本地化文档和商店草稿。不得直接修改生成后的目录和文档。运行 `python3 scripts/localize-source.py` 检查所有 L 调用都存在于目录中。模板使用 `%@` 与独立参数，避免将用户文件名或正文当成翻译键。

## 验证

- 原有核心回归 99 项，3 项按原条件跳过，无失败；包含 10 万索引/搜索和授权服务回归。
- 新增 5 项本地化测试：系统匹配/英文回退、全量目录覆盖、插值保真、繁中术语、持久化标识兼容。
- 两项引导流程测试，验证语言先行与四步流程。
- Finder 打开/编辑/保存不扫描同级文件的测试通过。
- 新增通知状态语言切换测试，验证不重新载入凭证库也能显示当前语言。
- opt-in SwiftUI 真实组件渲染：6 个语言，每种 5 张，共 30 张；2880×1800、不含透明通道。素材使用虚构项目与凭证，不含真实密钥；自定义项目名和正文不会自动翻译。
- 商店名称/副标题/描述等长度及关键词 100 UTF-8 字节限制已本地检查。规则参考 https://developer.apple.com/help/app-store-connect/manage-app-information/localize-app-information/ 。未宣称关键词流量或竞争度。

## 交付边界

本地验证包：`~/Library/Caches/NovaContextRelease/Localized/归记.app`，0.1.0 (21)，arm64、ad-hoc 签名；不是 App Store 发行包。

本轮本机界面工具因 ScreenCaptureKit 音视频采集失败而无法控制应用，未完成已安装版本的鼠标交互回归，也未替换正在运行的旧版本。SwiftUI 页面渲染不等同于真机安装、沙箱权限或通知送达验证。

未撤回或更改已有 build 20 的送审记录；新语言工程、文案和截图尚未上传 App Store Connect。新 App Store 构建需使用新的构建号重新归档、签名、上传并关联，不可复用旧包冒充已包含多语言。
