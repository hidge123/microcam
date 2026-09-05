# Windows 开发与发布环境

## 最小开发环境

推荐使用 Windows 11 的最新受支持版本，在 x64 或 arm64 真机上准备：

1. Git for Windows，并启用长路径支持。
2. Node.js 24 LTS 或更新的受支持版本；执行 `node --version` 和 `npm --version` 确认。
3. Windows PowerShell 5.1；执行 `$PSVersionTable.PSVersion` 确认。应用会用进程级 `ExecutionPolicy Bypass` 启动仓库随包分发的只读采集脚本，不修改系统执行策略。
4. 可访问 npm registry 的网络，首次执行 `npm ci` 需要下载 Electron 和 electron-builder。

本版没有第三方原生 Node 模块，因此常规构建不要求 Python、CMake 或 Visual Studio。建议安装 Visual Studio 2022 Build Tools 的“使用 C++ 的桌面开发”工作负载，便于后续原生模块或安装器诊断。

## 开发命令

```powershell
git clone git@github.com:hidge123/microcam.git
cd microcam\windows
npm ci
npm test
npm run lint
npm start
```

应用数据默认位于 `%APPDATA%\Microcam`。开发验收时不要直接复制 `secure-store.json` 到另一位用户或另一台电脑：其中的 DPAPI 密文只属于创建它的 Windows 登录用户。

## 本地打包

```powershell
cd windows
npm run dist:win
```

输出位于 `windows\dist`，包含 x64/arm64 的 NSIS 安装包和便携版。开发构建明确关闭代码签名，可用于内部验证，但安装时会出现 SmartScreen“未知发布者”提示。

## 正式发布所需身份材料

正式公开分发建议准备以下任一方案：

- 可导出的 OV/EV Authenticode `.pfx` 证书及密码，配置为 CI Secret `WIN_CSC_LINK` 和 `WIN_CSC_KEY_PASSWORD`；或
- Azure Trusted Signing 账户、证书配置文件，以及 `AZURE_TENANT_ID`、`AZURE_CLIENT_ID`、`AZURE_CLIENT_SECRET`。

证书、密码和 Azure 凭据不得提交到仓库。`.github/workflows/release-windows.yml` 在缺少签名 Secret 时会主动停止，不会发布未签名 Release。

## 推荐验证设备

- Windows 11 x64 主力机：开发、NSIS 安装/卸载和长期后台功耗。
- Windows 11 arm64 真机或官方虚拟机：arm64 安装包与兼容性。
- 标准用户账户：确认不需要管理员权限即可记录和保存数据。
- 至少一个具有管理员权限的测试账户：仅用于安装器边界测试，不要让应用以管理员身份常驻。

## 常见问题

- 采集状态显示不可用：在 PowerShell 手动执行 `src\platform\win32-monitor.ps1 -Once`，应输出一行 JSON。企业策略完全禁止 PowerShell 时，当前版本无法采集窗口状态。
- 登录启动没有生效：在“设置 → 应用 → 启动”检查 Microcam，并确认使用的是已安装版本而非临时构建目录。
- 本地模型连接失败：HTTP 只允许 `localhost`、`127.0.0.0/8` 或 `::1`，远程地址必须是 HTTPS。
- 数据无法解密：确认没有切换 Windows 用户，也没有只恢复 SQLite 而遗漏同一用户下的 `secure-store.json`。
