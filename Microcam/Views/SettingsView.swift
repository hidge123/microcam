import AppKit
import SwiftUI

private enum SettingsPage: String, CaseIterable, Identifiable {
    case general = "通用"
    case privacy = "隐私"
    case ai = "AI"
    case prompt = "提示词"

    var id: String { rawValue }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings: SettingsStore
    @ObservedObject private var monitor: ActivityMonitor
    @ObservedObject private var loginItemManager: LoginItemManager
    @State private var page: SettingsPage = .general

    init(model: AppModel) {
        self.model = model
        settings = model.settings
        monitor = model.monitor
        loginItemManager = model.loginItemManager
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("设置").font(.largeTitle.bold())
            Picker("设置页面", selection: $page) {
                ForEach(SettingsPage.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch page {
                case .general:
                    GeneralSettings(model: model)
                case .privacy:
                    PrivacySettings(model: model)
                case .ai:
                    AISettings(model: model)
                case .prompt:
                    PromptSettings(model: model)
                }
            }
        }
        .padding(28)
    }
}

private struct GeneralSettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings: SettingsStore
    @ObservedObject private var login: LoginItemManager

    init(model: AppModel) {
        self.model = model
        settings = model.settings
        login = model.loginItemManager
    }

    var body: some View {
        Form {
            Section {
                Toggle("启用活动记录", isOn: $settings.recordingEnabled)
                Stepper("空闲 \(settings.idleMinutes) 分钟后停止计时", value: $settings.idleMinutes, in: 1...30)
                Picker("活动日志保留", selection: $settings.retentionDays) {
                    Text("7 天").tag(7)
                    Text("30 天").tag(30)
                    Text("90 天").tag(90)
                    Text("永久").tag(0)
                }
            } header: {
                SettingsSectionHeader(
                    title: "活动记录",
                    help: "空闲时间只读取系统提供的“距上次输入时长”，不会监听键盘或鼠标内容。达到阈值后停止累计，恢复操作时重新开始。活动日志保留期限不会影响已生成的日记。"
                )
            }

            Section {
                Toggle("自动生成前一天日记", isOn: $settings.autoGenerate)
                    .disabled(!settings.aiDataSharingConfirmed)
                DatePicker("生成时间", selection: generationTime, displayedComponents: .hourAndMinute)
                    .disabled(!settings.autoGenerate)
                if !settings.aiDataSharingConfirmed {
                    Text("请先在 AI 设置中确认脱敏数据的发送目标。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                SettingsSectionHeader(
                    title: "每日生成",
                    help: "到达设定时间后生成前一个完整的本地日历日。如果电脑当时处于休眠状态，Microcam 会在下次唤醒后补生成最近一个有活动记录但尚未生成的日期。"
                )
            }

            Section {
                Toggle("登录时启动 Microcam", isOn: Binding(
                    get: { login.isEnabled },
                    set: { login.setEnabled($0) }
                ))
                LabeledContent("系统状态", value: login.statusText)
                if let error = login.lastError {
                    Text(error).foregroundStyle(.red).font(.caption)
                }
                if login.status == .requiresApproval {
                    Button("打开登录项系统设置") { login.openSystemSettings() }
                }
            } header: {
                SettingsSectionHeader(
                    title: "登录与后台",
                    help: "关闭主窗口后 Microcam 会继续在菜单栏运行；只有从菜单栏选择“退出 Microcam”才会停止。登录启动使用 macOS 的主应用登录项，不安装守护进程或特权帮助程序。"
                )
            }
        }
        .formStyle(.grouped)
    }

    private var generationTime: Binding<Date> {
        Binding {
            let calendar = Calendar.autoupdatingCurrent
            let start = calendar.startOfDay(for: Date())
            return calendar.date(bySettingHour: settings.generationHour, minute: settings.generationMinute, second: 0, of: start) ?? start
        } set: { date in
            let components = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: date)
            settings.generationHour = components.hour ?? 0
            settings.generationMinute = components.minute ?? 5
        }
    }
}

private struct PrivacySettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings: SettingsStore
    @ObservedObject private var monitor: ActivityMonitor
    @State private var sensitiveTerms: String
    @State private var customPatterns: String
    @State private var previewInput = "示例：alex@example.com 正在编辑 /Users/alex/Secret/project.md"
    @State private var deletingActivities = false
    @State private var deletingDiaries = false
    @State private var resettingAll = false

    init(model: AppModel) {
        self.model = model
        settings = model.settings
        monitor = model.monitor
        _sensitiveTerms = State(initialValue: model.settings.customSensitiveTerms.joined(separator: "\n"))
        _customPatterns = State(initialValue: model.settings.customPatterns.joined(separator: "\n"))
    }

    var body: some View {
        ScrollView {
            Form {
                Section {
                    Label(
                        monitor.accessibilityGranted ? "已授权读取当前窗口标题" : "未授权；仅记录应用名称与时长",
                        systemImage: monitor.accessibilityGranted ? "checkmark.shield" : "shield.slash"
                    )
                    HStack {
                        Button("启用窗口标题采集") { monitor.requestAccessibilityPermission() }
                        Button("刷新权限状态") { Task { await monitor.refreshAccessibilityStatus() } }
                        Button("打开辅助功能系统设置") {
                            monitor.watchForAccessibilityPermissionChange()
                            openAccessibilitySettings()
                        }
                    }
                } header: {
                    SettingsSectionHeader(title: "辅助功能权限", help: accessibilityHelp)
                }

                Section {
                    if model.knownApplications.isEmpty {
                        Text("记录到应用后，可在这里逐个设置标题采集、仅记录时长或完全排除。")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.knownApplications, id: \.bundleID) { application in
                            HStack(spacing: 16) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(application.name).fontWeight(.medium)
                                    if application.name != application.bundleID {
                                        Text(application.bundleID)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Picker("采集策略", selection: Binding(
                                    get: { settings.policy(for: application.bundleID) },
                                    set: { settings.setPolicy($0, for: application.bundleID) }
                                )) {
                                    ForEach(AppCapturePolicy.allCases) { policy in
                                        Text(policy.localizedName).tag(policy)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 150)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                } header: {
                    SettingsSectionHeader(
                        title: "应用采集策略",
                        help: "“应用与标题”记录应用时长及本地脱敏后的窗口标题；“仅记录时长”不读取或保存标题；“完全排除”不会生成该应用的活动段。密码管理器、系统密码和钥匙串默认仅记录时长。"
                    )
                }

                Section {
                    Text("敏感词（每行一个，按普通文本匹配）")
                    TextEditor(text: $sensitiveTerms).font(.system(.body, design: .monospaced)).frame(minHeight: 80)
                    Text("自定义正则（每行一个）")
                    TextEditor(text: $customPatterns).font(.system(.body, design: .monospaced)).frame(minHeight: 80)
                    if invalidPatternCount > 0 {
                        Label("有 \(invalidPatternCount) 条正则无效，保存后会被忽略", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    Button("安全保存脱敏规则") {
                        settings.customSensitiveTerms = nonEmptyLines(sensitiveTerms)
                        settings.customPatterns = nonEmptyLines(customPatterns)
                        model.saveRedactionSettings()
                    }
                } header: {
                    SettingsSectionHeader(
                        title: "自定义脱敏",
                        help: "敏感词按普通文本逐项替换；自定义正则用于处理更复杂的模式。规则只在本机运行，保存时会加密存入钥匙串。无效正则会被忽略。"
                    )
                }

                Section {
                    TextField("输入测试标题", text: $previewInput)
                    LabeledContent("结果") {
                        Text(model.sanitizedPreview(for: previewInput))
                            .textSelection(.enabled)
                    }
                } header: {
                    SettingsSectionHeader(
                        title: "脱敏预览",
                        help: "输入仅用于实时测试当前脱敏规则。预览在本机内存中完成，不会写入活动数据库，也不会发送到网络。"
                    )
                }

                Section {
                    HStack {
                        Button("删除全部活动", role: .destructive) { deletingActivities = true }
                        Button("删除全部日记", role: .destructive) { deletingDiaries = true }
                        Button("彻底重置", role: .destructive) { resettingAll = true }
                    }
                } header: {
                    SettingsSectionHeader(
                        title: "数据管理",
                        help: "删除操作会在确认后永久执行，无法撤销。删除活动不会删除日记；删除日记不会删除活动。彻底重置会同时清除设置和钥匙串机密。已经导出到其他位置的 Markdown 文件不受影响。"
                    )
                }
            }
            .formStyle(.grouped)
        }
        .alert("删除全部活动？", isPresented: $deletingActivities) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { Task { await model.deleteAllActivities() } }
        }
        .alert("删除全部日记？", isPresented: $deletingDiaries) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { Task { await model.deleteAllDiaries() } }
        }
        .alert("彻底重置 Microcam？", isPresented: $resettingAll) {
            Button("取消", role: .cancel) {}
            Button("重置", role: .destructive) { Task { await model.resetAllData() } }
        } message: {
            Text("活动、日记、AI Key、自定义脱敏词和所有设置都会被清除。")
        }
    }

    private var invalidPatternCount: Int {
        nonEmptyLines(customPatterns).filter { (try? NSRegularExpression(pattern: $0)) == nil }.count
    }

    private var accessibilityHelp: String {
        var value = "此权限只用于读取当前前台应用的焦点窗口标题。Microcam 不读取输入内容、不控制其他应用，也不截取屏幕；拒绝后仍会记录应用名称与使用时长。"
        #if DEBUG
        value += "\n\n如果本版本使用“Sign to Run Locally”，重新编译后可能需要再次授权。使用稳定的 Apple Development 签名后通常只需授权一次。"
        #endif
        return value
    }

    private func nonEmptyLines(_ value: String) -> [String] {
        value.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct AISettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings: SettingsStore

    init(model: AppModel) {
        self.model = model
        settings = model.settings
    }

    var body: some View {
        Form {
            Section {
                TextField("Base URL", text: $settings.aiBaseURL, prompt: Text("https://host/v1"))
                SecureField("API Key（本地模型可留空）", text: $settings.apiKey)
                TextField("模型名", text: $settings.aiModel)
                LabeledContent("发送目标") {
                    Text(endpointHost).foregroundStyle(.secondary)
                }
                Toggle("我确认自动生成时向上述主机发送脱敏活动摘要", isOn: $settings.aiDataSharingConfirmed)
            } header: {
                SettingsSectionHeader(
                    title: "OpenAI 兼容接口",
                    help: "Base URL 应包含版本路径，例如 https://host/v1。Microcam 固定请求其 /chat/completions 接口。远程地址必须使用 HTTPS，只有本机 loopback 地址允许 HTTP。测试连接不发送活动数据；生成日记只发送脱敏并按小时聚合的摘要。"
                )
            }

            Section {
                HStack {
                    Text("Temperature")
                    Slider(value: $settings.temperature, in: 0...2, step: 0.1)
                    Text(settings.temperature.formatted(.number.precision(.fractionLength(1)))).monospacedDigit().frame(width: 32)
                }
                Stepper("最大输出 Token：\(settings.maxTokens)", value: $settings.maxTokens, in: 128...8192, step: 128)
                Stepper("超时：\(Int(settings.timeout)) 秒", value: $settings.timeout, in: 15...300, step: 15)
            } header: {
                SettingsSectionHeader(
                    title: "生成参数",
                    help: "Temperature 越低，输出越稳定克制；越高则表达更多样。最大输出 Token 限制日记长度。超时表示单次网络请求最多等待多久，不包含后续自动重试时间。"
                )
            }

            Section {
                Button(model.isGenerating ? "测试中…" : "保存 API Key 并测试连接") {
                    Task { await model.testAIConnection() }
                }
                .disabled(model.isGenerating || !settings.aiConfiguration.isConfigured)
            }
        }
        .formStyle(.grouped)
    }

    private var endpointHost: String {
        URLComponents(string: settings.aiBaseURL)?.host ?? "无效地址"
    }
}

private struct PromptSettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings: SettingsStore

    init(model: AppModel) {
        self.model = model
        settings = model.settings
    }

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("日记提示词").font(.headline)
                    SettingsHelpButton(
                        title: "提示词变量",
                        text: "支持 {{date}}、{{active_time}}、{{app_breakdown}} 和 {{activity_summary}}。其中 {{activity_summary}} 是必需项；它会被替换为脱敏后的活动摘要。"
                    )
                    Spacer()
                    Button("恢复默认") {
                        settings.resetPrompt()
                        model.refreshPromptPreview()
                    }
                }
                TextEditor(text: $settings.promptTemplate)
                    .font(.system(.body, design: .monospaced))
                    .padding(8)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                if let error = settings.promptValidationMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 12) {
                Text("今日数据预览").font(.headline)
                ScrollView {
                    Text(model.promptPreview)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
            .frame(maxWidth: .infinity)
        }
        .onChange(of: settings.promptTemplate) { _, _ in model.refreshPromptPreview() }
    }
}

private struct SettingsSectionHeader: View {
    let title: String
    let help: String

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            SettingsHelpButton(title: title, text: help)
        }
    }
}

private struct SettingsHelpButton: View {
    let title: String
    let text: String
    @State private var showingHelp = false

    var body: some View {
        Button {
            showingHelp.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
                .imageScale(.medium)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("查看“\(title)”说明")
        .accessibilityLabel("\(title)说明")
        .popover(isPresented: $showingHelp, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.headline)
                Text(text)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(16)
            .frame(width: 320, alignment: .leading)
        }
    }
}
