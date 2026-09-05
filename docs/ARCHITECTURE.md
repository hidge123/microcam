# Microcam 跨平台架构

## 边界

仓库保留现有 `Microcam/` SwiftUI/AppKit 应用，Windows 实现放在 `windows/`。两个平台当前共享隐私协议、数据库语义、AI 请求格式和验收标准，而不强行共享 UI 或系统 API 代码。

原因是前台应用、窗口标题、空闲状态、安全凭据和状态栏生命周期都由平台提供：macOS 使用 `NSWorkspace`、Accessibility、Keychain 和 SwiftUI；Windows 使用 Win32、DPAPI、通知区域和 Electron。把这些层硬抽象为同一份源码会增加权限与发布风险，实际复用价值很低。

## 数据流

```text
Win32 snapshot (in memory)
  -> executable filename + display name
  -> raw window title -> Redactor -> sanitized title
  -> ActivityMonitor (idle/pause/policy/midnight split)
  -> AES-256-GCM
  -> local SQLite
  -> hourly/application aggregation
  -> explicit destination confirmation
  -> user's OpenAI-compatible /chat/completions endpoint
```

原始窗口标题不进入日志、设置文件、数据库或渲染进程。应用 ID 使用可执行文件名而不是完整路径，避免把 Windows 用户目录写入数据库。

## Windows 进程模型

- Electron 主进程拥有数据库、DPAPI、安全设置、网络和系统托盘能力。
- 沙箱化渲染进程只能调用 `preload.cjs` 暴露的窄 IPC API，不能使用 Node.js、文件系统或网络。
- 常驻 PowerShell 子进程调用 `GetForegroundWindow`、`GetWindowText`、`GetWindowThreadProcessId` 和 `GetLastInputInfo`。它不申请管理员权限，不捕获输入内容，也不写磁盘。
- 休眠、锁屏、退出和午夜边界都会关闭当前活动片段；30 秒检查点限制异常退出时的数据损失。

## 本地加密

Windows 版首次启动生成随机 256 位数据库主密钥。Electron `safeStorage` 在 Windows 上使用 DPAPI 对主密钥、API Key 和自定义脱敏规则分别加密。窗口标题与日记正文使用主密钥和独立随机 nonce 做 AES-256-GCM 加密后进入 SQLite。

DPAPI 的边界是“同一 Windows 登录用户”，不是“同一应用进程”。同一用户权限下的恶意程序仍可能攻击运行中的应用；Microcam 不声称可以抵御已经控制用户会话的恶意软件。

## 后续可共享部分

当两个平台行为通过验收后，可把脱敏测试向量、提示词模板、AI Endpoint 规则和数据库迁移规范提取到 `spec/`，由 Swift 和 JavaScript 测试同时读取。现阶段优先保证 Windows 端可独立构建和验证，避免为了源码复用改坏已经工作的 macOS 目标。
