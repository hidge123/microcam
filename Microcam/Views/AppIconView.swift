import AppKit
import SwiftUI

@MainActor
private final class AppIconProvider {
    static let shared = AppIconProvider()

    private let cache = NSCache<NSString, NSImage>()
    private var unavailableBundleIDs: Set<String> = []

    private init() {
        cache.countLimit = 256
    }

    func icon(for bundleID: String) -> NSImage? {
        guard !bundleID.isEmpty else { return nil }
        let key = bundleID as NSString
        if let cached = cache.object(forKey: key) { return cached }
        if unavailableBundleIDs.contains(bundleID) { return nil }

        let icon = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.icon
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map {
                NSWorkspace.shared.icon(forFile: $0.path)
            }

        if let icon {
            cache.setObject(icon, forKey: key)
        } else {
            unavailableBundleIDs.insert(bundleID)
        }
        return icon
    }
}

struct AppIconView: View {
    let bundleID: String
    var size: CGFloat = 30

    var body: some View {
        Group {
            if let icon = AppIconProvider.shared.icon(for: bundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: size * 0.55))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: size * 0.2))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
