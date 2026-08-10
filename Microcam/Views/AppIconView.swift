import AppKit
import SwiftUI

@MainActor
private final class AppIconProvider {
    static let shared = AppIconProvider()

    private let cache = NSCache<NSString, NSImage>()
    private var unavailableBundleIDs: Set<String> = []

    private init() {
        cache.countLimit = 64
        cache.totalCostLimit = 8 * 1_024 * 1_024
    }

    func icon(for bundleID: String, size: CGFloat) -> NSImage? {
        guard !bundleID.isEmpty else { return nil }
        let pixelSize = min(128, max(32, Int(ceil(size * 2))))
        let key = "\(bundleID)#\(pixelSize)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        if unavailableBundleIDs.contains(bundleID) { return nil }

        let sourceIcon = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.icon
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map {
                NSWorkspace.shared.icon(forFile: $0.path)
            }

        if let sourceIcon, let icon = thumbnail(sourceIcon, pointSize: size, pixelSize: pixelSize) {
            cache.setObject(icon, forKey: key, cost: pixelSize * pixelSize * 4)
            return icon
        } else {
            // PID fallbacks are short lived and would otherwise grow the negative cache
            // indefinitely over a long-running session.
            if !bundleID.hasPrefix("pid."), unavailableBundleIDs.count < 128 {
                unavailableBundleIDs.insert(bundleID)
            }
        }
        return nil
    }

    private func thumbnail(_ source: NSImage, pointSize: CGFloat, pixelSize: Int) -> NSImage? {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelSize,
            pixelsHigh: pixelSize,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        source.draw(
            in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        let result = NSImage(size: NSSize(width: pointSize, height: pointSize))
        result.addRepresentation(bitmap)
        return result
    }
}

struct AppIconView: View {
    let bundleID: String
    var size: CGFloat = 30

    var body: some View {
        Group {
            if let icon = AppIconProvider.shared.icon(for: bundleID, size: size) {
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
