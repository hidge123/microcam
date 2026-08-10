# Microcam

Microcam 是一个隐私优先的桌面状态栏应用，目前包含 macOS 菜单栏版和正在验证的 Windows 通知区域版。它低功耗记录前台应用、使用时长和经过本地脱敏的窗口标题，并在每天结束后通过用户自己的 OpenAI 兼容接口生成日记。

## 隐私边界

- 原始窗口标题仅短暂存在于内存，经过规则脱敏后才可进入后续流程。
- 脱敏标题和日记正文使用 AES-GCM 加密后存入本地 SQLite；macOS 使用登录钥匙串保护密钥，Windows 使用当前用户的 DPAPI 保护密钥。
- AI 只接收按小时、应用和脱敏标题聚合的摘要。
- 不记录键盘内容、鼠标内容、截图、URL、网页正文或文件内容。
- 不申请屏幕录制、输入监听、摄像头、麦克风、自动化、位置或完全磁盘访问。
- 没有遥测、广告或崩溃信息上传。

macOS 的窗口标题采集需要用户明确授予“辅助功能”权限。Windows 版通过 Win32 用户界面 API 读取当前窗口，不要求管理员权限。密码管理器和系统密码工具在两个平台上都默认不采集窗口标题。

## 功能

- 菜单栏常驻、暂停/恢复记录、可选登录启动。
- 应用切换和窗口标题事件驱动监听，30 秒低频兜底检查。
- 5 分钟默认空闲阈值，可配置为 1–30 分钟。
- 按应用选择“应用与标题”“仅记录时长”或“完全排除”。
- 内置邮箱、电话、IP、URL、路径、账号和疑似密钥脱敏，支持自定义敏感词与正则。
- OpenAI Chat Completions 兼容 API，可配置 Base URL、模型和生成参数。
- 可编辑日记提示词，支持活动预览、自动生成、手动重试与 Markdown 导出。
- 活动默认保留 30 天；日记长期保留，可分别清除或彻底重置。

## macOS 构建要求

- 当前项目目标：arm64、macOS 26.0 及以上。
- 与当前 macOS SDK 匹配的完整 Xcode。
- 不需要第三方 Swift 包或管理员权限。

安装匹配的 Xcode 后执行：

```bash
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
xcodebuild -version
xcodebuild -project Microcam.xcodeproj -scheme Microcam -configuration Debug build
```

也可以直接用 Xcode 打开 `Microcam.xcodeproj`。为了让辅助功能授权和登录启动保持稳定，请把构建后的 `Microcam.app` 放在 `/Applications` 后再授权。项目使用本机 ad-hoc 签名，仅面向本机开发使用。

## Windows 构建要求

Windows 版位于 `windows/`，采用 Electron 43、Node.js 内置 SQLite 和一个只调用 Win32 API 的本地 PowerShell 采集器。推荐在 Windows 11 x64/arm64 上安装：

- Git for Windows；
- Node.js 24 LTS 或更高版本（需包含 npm）；
- Windows PowerShell 5.1（Windows 自带）；
- 可选：Visual Studio 2022 Build Tools，用于排查安装包或未来加入原生模块，本版日常构建不强制需要。

```powershell
cd windows
npm ci
npm test
npm run lint
npm start
```

生成未签名的 NSIS 安装包和便携版：

```powershell
npm run dist:win
```

详细环境、调试和签名说明见 [`docs/WINDOWS_SETUP.md`](docs/WINDOWS_SETUP.md)，Windows 手动验收项目见 [`docs/WINDOWS_TEST_PLAN.md`](docs/WINDOWS_TEST_PLAN.md)。未签名构建可运行，但 Windows SmartScreen 会显示“未知发布者”警告；正式公开发布前应配置 OV/EV 代码签名证书或 Azure Trusted Signing。

## AI 配置

Base URL 应包含兼容 API 的版本路径，例如：

```text
https://api.example.com/v1
http://127.0.0.1:11434/v1
```

Microcam 会请求 `{Base URL}/chat/completions`。远程地址必须使用 HTTPS；只有 `localhost`、`127.0.0.0/8` 和 `::1` 可以使用 HTTP。API Key 可留空以支持本地模型服务。

提示词支持以下变量：

- `{{date}}`
- `{{active_time}}`
- `{{app_breakdown}}`
- `{{activity_summary}}`（必需）

## 项目结构

- `Microcam/App`：应用生命周期和主状态模型。
- `Microcam/Monitoring`：前台应用、辅助功能、空闲和睡眠事件采集。
- `Microcam/Privacy`、`Security`、`Persistence`：脱敏、钥匙串、加密和 SQLite。
- `Microcam/AI`：活动聚合、提示词和 Chat Completions 客户端。
- `Microcam/Views`：菜单栏、首次引导和主窗口。
- `MicrocamTests`：脱敏、时间边界、API 校验和密文落盘测试。
- `windows/src/core`：Windows 版可独立测试的脱敏、AES-GCM、日记聚合和 AI 客户端。
- `windows/src/main`：Electron 主进程、DPAPI 安全存储、SQLite、活动监控与托盘生命周期。
- `windows/src/platform`：Win32 前台窗口与空闲时间采集器。
- `windows/src/renderer`：启用上下文隔离和严格 CSP 的本地界面。

## 已知限制

- 基于规则的脱敏无法自动识别所有人名或语义隐私；建议为敏感应用选择“仅记录时长/完全排除”，并在发送前查看预览。
- 部分应用不会通过 macOS 辅助功能接口暴露窗口标题，此时只记录应用与时长。
- 菜单栏模式不安装崩溃拉起守护进程；崩溃后需要手动重新打开，或等待下次登录启动。
- 首版不包含截图理解、完整 URL、浏览器扩展、统计图表或跨设备同步。
- Windows 版目前通过一个常驻 PowerShell 子进程每 2 秒读取轻量 Win32 状态；需在真实 Windows 设备上完成长期功耗和兼容性验收后再视为稳定版。

## License

MIT
