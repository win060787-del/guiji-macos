# 构建与验证 / Build and verification

## 环境

使用 Apple 芯片 Mac、macOS 14 或更新版本，以及支持 Swift 6 的 Xcode。源码快照保留 Swift 本地依赖、arm64 OCR 库及六个模型。普通构建无需配置 API Key。

```bash
cd Demo
swift build
swift test
bash scripts/package.sh
```

本地包默认输出到 `dist/归记.app`。可通过 `NOVA_OUTPUT_DIR` 将输出放到独立目录。该包使用临时本地签名，适合开发自测。发行签名需要自己的 Apple 开发者团队和证书。

## 验证路径

| 改动 | 建议验证 |
| --- | --- |
| 本地化 | 英文和中文首次引导，示例 README 与文件名，系统菜单显示名称 |
| 编辑 | 保存后重开，切换文件时保护草稿，外部改动时拒绝覆盖 |
| 转换 | 英文 DOCX/XLSX/PPTX/PDF/PNG 样例，扫描 PDF 和 OCR 回退 |
| 权限 | 用户选择文件夹后重启恢复访问，校验签名包的沙箱权限 |
| 凭证 | 用合成数据检查有效期、作废、重启和本机 socket 清理 |

默认测试会跳过显式启用的真实钥匙串、压力测试和素材捕获用例。只在独立测试环境中使用合成数据运行 opt-in 测试。各项开关以对应测试源码为准。

```bash
swift test --filter testEnglishSampleDocumentsConvertInEnglish
swift test --filter OCRFallbackTests
```

## OCR 与本地化资源

- OCR 供应链固定版本与哈希见 `Demo/Packaging/NativeOCR/manifest.json`。更换引擎或模型时，先更新来源与校验值，再通过 `python3 scripts/build-native-ocr.py --cmake /path/to/cmake` 重新构建。
- 修改 `Demo/design/localization/` 中的翻译源，执行 `python3 scripts/generate-localizations.py`。该流程依赖本机 Swift 工具链。
- 英文示例与中文示例使用不同目录。升级测试时保留用户编辑的旧示例。

## 发行

`Demo/NovaContext.xcodeproj` 是签名发行入口。项目内的归档脚本针对原发行团队配置。使用自己的团队构建分支版本时，请先检查签名身份、Bundle ID、权限与隐私清单。

发行前核对解包后的名称、版本、可执行架构、内置模型哈希、第三方许可、签名和安装包内容，并从外部网络验证支持与隐私页面。
