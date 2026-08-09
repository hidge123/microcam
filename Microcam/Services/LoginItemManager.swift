import Foundation
import ServiceManagement

@MainActor
final class LoginItemManager: ObservableObject {
    @Published private(set) var status: SMAppService.Status = SMAppService.mainApp.status
    @Published private(set) var lastError: String?

    var isEnabled: Bool { status == .enabled }

    var statusText: String {
        switch status {
        case .enabled: "已启用"
        case .notRegistered: "未启用"
        case .requiresApproval: "等待在系统设置中批准"
        case .notFound: "当前应用位置不支持登录启动"
        @unknown default: "状态未知"
        }
    }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) {
        lastError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
