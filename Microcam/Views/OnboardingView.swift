import SwiftUI

struct OnboardingView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings: SettingsStore
    @ObservedObject private var monitor: ActivityMonitor
    @ObservedObject private var login: LoginItemManager
    @State private var step = 0
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel) {
        self.model = model
        settings = model.settings
        monitor = model.monitor
        login = model.loginItemManager
    }

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: pageSymbol)
                .font(.system(size: 54))
                .foregroundStyle(.tint)
            Text(pageTitle).font(.largeTitle.bold())
            pageContent
                .frame(maxWidth: 560)
            Spacer()
            HStack {
                if step > 0 { Button("上一步") { step -= 1 } }
                Spacer()
                Button("稍后完成") { finish() }
                Button(step == 3 ? "开始使用" : "下一步") {
                    if step == 3 { finish() } else { step += 1 }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(36)
        .frame(width: 680, height: 520)
        .interactiveDismissDisabled()
    }

    @ViewBuilder
    private var pageContent: some View {
        switch step {
        case 0:
            VStack(alignment: .leading, spacing: 14) {
                Text("Microcam 在本机记录前台应用的使用时长，并在每天结束后生成日记。")
                PermissionLine(symbol: "checkmark.shield", text: "窗口标题会先在内存中脱敏，再加密保存")
                PermissionLine(symbol: "keyboard", text: "不会记录键盘或鼠标内容")
                PermissionLine(symbol: "camera", text: "不会截图，也不会使用摄像头或麦克风")
                PermissionLine(symbol: "network.slash", text: "只有生成日记和测试 AI 时才访问网络")
            }
        case 1:
            VStack(alignment: .leading, spacing: 14) {
                Text("可选权限：辅助功能")
                    .font(.headline)
                Text("此权限仅用于读取当前前台应用的焦点窗口标题，以便区分“在浏览器看什么页面”或“正在编辑哪个脱敏后的文档标题”。Microcam 不会控制其他应用。")
                    .foregroundStyle(.secondary)
                Label(
                    monitor.accessibilityGranted ? "已授权" : "未授权时仍可只记录应用名称和时长",
                    systemImage: monitor.accessibilityGranted ? "checkmark.circle.fill" : "info.circle"
                )
                HStack {
                    Button("我了解用途，申请权限") { monitor.requestAccessibilityPermission() }
                    Button("刷新状态") { Task { await monitor.refreshAccessibilityStatus() } }
                }
            }
        case 2:
            VStack(alignment: .leading, spacing: 14) {
                Text("AI 数据边界").font(.headline)
                Text("只有按小时、应用和脱敏标题聚合的摘要会发送到你配置的 AI 接口。API Key 存在系统钥匙串中；测试连接不发送活动数据。")
                    .foregroundStyle(.secondary)
                PermissionLine(symbol: "eye.slash", text: "原始窗口标题永不落盘或上传")
                PermissionLine(symbol: "lock.square", text: "脱敏标题和日记正文使用 AES-GCM 加密")
                PermissionLine(symbol: "hand.raised", text: "可以随时暂停记录、排除应用或删除全部数据")
            }
        default:
            VStack(alignment: .leading, spacing: 14) {
                Text("登录启动（可选）").font(.headline)
                Text("启用后，macOS 会在你登录时打开这个菜单栏应用。不会安装守护进程，也不需要管理员权限。")
                    .foregroundStyle(.secondary)
                Toggle("登录时启动 Microcam", isOn: Binding(
                    get: { login.isEnabled },
                    set: { login.setEnabled($0) }
                ))
                Text("系统状态：\(login.statusText)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var pageTitle: String {
        ["欢迎使用 Microcam", "细致申请权限", "隐私优先的 AI 日记", "保持后台运行"][step]
    }

    private var pageSymbol: String {
        ["book.pages", "checkmark.shield", "sparkles.rectangle.stack", "menubar.rectangle"][step]
    }

    private func finish() {
        settings.onboardingComplete = true
        dismiss()
    }
}

private struct PermissionLine: View {
    let symbol: String
    let text: String

    var body: some View {
        Label(text, systemImage: symbol)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
