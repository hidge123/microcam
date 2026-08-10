import AppKit
@preconcurrency import ApplicationServices
import Combine
import CoreGraphics
import Foundation

@MainActor
final class ActivityMonitor: NSObject, ObservableObject, @unchecked Sendable {
    @Published private(set) var displayState: MonitorDisplayState = .stopped
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()
    private(set) var currentSegment: ActivitySegment?
    @Published private(set) var pauseUntil: Date?
    @Published private(set) var lastRecordedAt: Date?
    @Published private(set) var lastPersistenceError: String?

    var isPaused: Bool {
        if case .paused = displayState { return true }
        return false
    }

    var onDidPersist: (@MainActor () -> Void)?
    var onWake: (@MainActor () -> Void)?
    var onPeriodicMaintenance: (@MainActor () -> Void)?

    private let settings: SettingsStore
    private let store: SQLiteStore
    private var timer: Timer?
    private var accessibilityRefreshTask: Task<Void, Never>?
    private var lastAccessibilityCheck = Date.distantPast
    private var lastTitleFallbackCheck = Date.distantPast
    private var isStarted = false
    private var sessionSuspended = false
    private var manuallyPaused = false

    private var axObserver: AXObserver?
    private var axApplication: AXUIElement?
    private var axWindow: AXUIElement?
    private var observedPID: pid_t?

    init(settings: SettingsStore, store: SQLiteStore) {
        self.settings = settings
        self.store = store
        super.init()
    }

    func start() async {
        guard !isStarted else { return }
        isStarted = true
        installWorkspaceObservers()

        // Application switches and window-title changes are event driven. This timer is
        // only a low-frequency safety net for idle detection, midnight splitting and
        // crash-recovery checkpoints.
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.tick()
            }
        }
        timer.tolerance = 15
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        accessibilityGranted = AXIsProcessTrusted()
        await evaluateCurrentActivity(forceTransition: true)
    }

    func stop() async {
        guard isStarted else { return }
        isStarted = false
        timer?.invalidate()
        timer = nil
        accessibilityRefreshTask?.cancel()
        accessibilityRefreshTask = nil
        removeWorkspaceObservers()
        removeAccessibilityObserver()
        await closeCurrent(at: Date())
        setDisplayState(.stopped)
    }

    func pause(for interval: TimeInterval?) async {
        manuallyPaused = interval == nil
        pauseUntil = interval.map { Date().addingTimeInterval($0) }
        await closeCurrent(at: Date())
        setDisplayState(.paused(until: pauseUntil))
    }

    func resume() async {
        manuallyPaused = false
        pauseUntil = nil
        await evaluateCurrentActivity(forceTransition: true)
    }

    func requestAccessibilityPermission() {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        // The system prompt is asynchronous. Watch briefly only after an explicit user action
        // so the UI reacts immediately without adding a permanent high-frequency poll.
        watchForAccessibilityPermissionChange()
    }

    func watchForAccessibilityPermissionChange() {
        accessibilityRefreshTask?.cancel()
        accessibilityRefreshTask = Task { @MainActor [weak self] in
            for _ in 0..<60 {
                guard let self, !Task.isCancelled else { return }
                await refreshAccessibilityStatus()
                if accessibilityGranted { return }
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
        }
    }

    func refreshAccessibilityStatus() async {
        lastAccessibilityCheck = Date()
        let newValue = AXIsProcessTrusted()
        guard newValue != accessibilityGranted else { return }
        accessibilityGranted = newValue
        await evaluateCurrentActivity(forceTransition: true)
    }

    fileprivate func accessibilityEventReceived(focusedWindowChanged: Bool) async {
        guard isStarted else { return }
        if focusedWindowChanged {
            configureAccessibilityObserver(for: NSWorkspace.shared.frontmostApplication, force: true)
        }
        await evaluateCurrentActivity(forceTransition: false)
    }

    private func tick() async {
        guard isStarted else { return }
        let now = Date()

        if let pauseUntil, now >= pauseUntil {
            self.pauseUntil = nil
        }
        if now.timeIntervalSince(lastAccessibilityCheck) >= 300 {
            lastAccessibilityCheck = now
            await refreshAccessibilityStatus()
        }
        let shouldRefreshTitle = now.timeIntervalSince(lastTitleFallbackCheck) >= 300
        if shouldRefreshTitle { lastTitleFallbackCheck = now }
        await evaluateCurrentActivity(
            forceTransition: false,
            refreshWindowTitle: shouldRefreshTitle
        )
        onPeriodicMaintenance?()
    }

    private func evaluateCurrentActivity(
        forceTransition: Bool,
        refreshWindowTitle: Bool = true
    ) async {
        let now = Date()

        guard settings.recordingEnabled else {
            await closeCurrent(at: now)
            setDisplayState(.stopped)
            return
        }
        guard !sessionSuspended else { return }
        if manuallyPaused || pauseUntil != nil {
            await closeCurrent(at: now)
            setDisplayState(.paused(until: pauseUntil))
            return
        }

        await splitAtMidnightIfNeeded(now: now)

        let anyInputEvent = CGEventType(rawValue: UInt32.max) ?? .null
        let idleSeconds = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: anyInputEvent
        )
        let threshold = TimeInterval(settings.idleMinutes * 60)
        if idleSeconds >= threshold {
            let idleBoundary = now.addingTimeInterval(-(idleSeconds - threshold))
            await closeCurrent(at: idleBoundary)
            setDisplayState(.idle)
            return
        }

        guard let application = NSWorkspace.shared.frontmostApplication else {
            await closeCurrent(at: now)
            setDisplayState(.idle)
            return
        }
        let bundleID = application.bundleIdentifier ?? "pid.\(application.processIdentifier)"
        let appName = application.localizedName ?? "未知应用"
        let requestedPolicy = settings.policy(for: bundleID)

        if requestedPolicy == .exclude {
            await closeCurrent(at: now)
            setDisplayState(.recording(appName: "已排除 \(appName)"))
            removeAccessibilityObserver()
            return
        }

        let effectivePolicy: AppCapturePolicy = requestedPolicy == .title && !accessibilityGranted
            ? .durationOnly
            : requestedPolicy

        if effectivePolicy == .title {
            configureAccessibilityObserver(for: application)
        } else {
            removeAccessibilityObserver()
        }

        // The raw title is scoped to this expression and is never persisted or logged.
        let canReuseCurrentTitle = !refreshWindowTitle
            && currentSegment?.bundleID == bundleID
            && currentSegment?.capturePolicy == effectivePolicy
        let sanitizedTitle: String?
        if effectivePolicy != .title {
            sanitizedTitle = nil
        } else if canReuseCurrentTitle {
            sanitizedTitle = currentSegment?.sanitizedTitle
        } else {
            lastTitleFallbackCheck = now
            sanitizedTitle = settings.redactor.redact(readFocusedWindowTitle(for: application))
        }

        let changed = forceTransition ||
            currentSegment?.bundleID != bundleID ||
            currentSegment?.sanitizedTitle != sanitizedTitle ||
            currentSegment?.capturePolicy != effectivePolicy

        if changed {
            await closeCurrent(at: now)
            let start = max(now.addingTimeInterval(-idleSeconds), Calendar.autoupdatingCurrent.startOfDay(for: now))
            currentSegment = ActivitySegment(
                id: UUID(),
                startAt: start,
                endAt: now,
                bundleID: bundleID,
                appName: appName,
                sanitizedTitle: sanitizedTitle,
                capturePolicy: effectivePolicy
            )
        } else {
            currentSegment?.endAt = now
        }

        if let currentSegment {
            do {
                try await store.save(currentSegment)
                markPersistenceSucceeded(at: now)
                onDidPersist?()
            } catch {
                // No private values are included in user-facing or system logs.
                setPersistenceError(error.localizedDescription)
                setDisplayState(.stopped)
                return
            }
        }

        setDisplayState(
            requestedPolicy == .title && !accessibilityGranted
                ? .permissionLimited
                : .recording(appName: appName)
        )
    }

    private func closeCurrent(at requestedEnd: Date) async {
        guard var segment = currentSegment else { return }
        let end = max(segment.startAt, min(requestedEnd, Date()))
        segment.endAt = end
        currentSegment = nil
        guard segment.activeSeconds > 0 else { return }
        do {
            try await store.save(segment)
            markPersistenceSucceeded(at: Date())
            onDidPersist?()
        } catch {
            setPersistenceError(error.localizedDescription)
            setDisplayState(.stopped)
        }
    }

    private func setDisplayState(_ newValue: MonitorDisplayState) {
        guard displayState != newValue else { return }
        displayState = newValue
    }

    private func markPersistenceSucceeded(at date: Date) {
        if lastPersistenceError != nil { lastPersistenceError = nil }
        if lastRecordedAt == nil || date.timeIntervalSince(lastRecordedAt ?? .distantPast) >= 60 {
            lastRecordedAt = date
        }
    }

    private func setPersistenceError(_ message: String) {
        guard lastPersistenceError != message else { return }
        lastPersistenceError = message
    }

    private func splitAtMidnightIfNeeded(now: Date) async {
        guard let segment = currentSegment else { return }
        let startOfToday = Calendar.autoupdatingCurrent.startOfDay(for: now)
        guard segment.startAt < startOfToday else { return }
        await closeCurrent(at: startOfToday)
    }

    private func readFocusedWindowTitle(for application: NSRunningApplication) -> String? {
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &windowValue
        ) == .success, let windowValue else { return nil }

        let window = unsafeDowncast(windowValue, to: AXUIElement.self)
        var titleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window,
            kAXTitleAttribute as CFString,
            &titleValue
        ) == .success else { return nil }
        return titleValue as? String
    }

    private func configureAccessibilityObserver(for application: NSRunningApplication?, force: Bool = false) {
        guard
            accessibilityGranted,
            let application,
            force || observedPID != application.processIdentifier
        else { return }

        removeAccessibilityObserver()
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        var observer: AXObserver?
        guard AXObserverCreate(
            application.processIdentifier,
            microcamAccessibilityCallback,
            &observer
        ) == .success, let observer else { return }

        let context = Unmanaged.passUnretained(self).toOpaque()
        _ = AXObserverAddNotification(
            observer,
            appElement,
            kAXFocusedWindowChangedNotification as CFString,
            context
        )

        var windowValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &windowValue
        ) == .success, let windowValue {
            let window = unsafeDowncast(windowValue, to: AXUIElement.self)
            _ = AXObserverAddNotification(
                observer,
                window,
                kAXTitleChangedNotification as CFString,
                context
            )
            axWindow = window
        }

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
        axApplication = appElement
        axObserver = observer
        observedPID = application.processIdentifier
    }

    private func removeAccessibilityObserver() {
        if let axObserver {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(axObserver),
                .commonModes
            )
        }
        axObserver = nil
        axApplication = nil
        axWindow = nil
        observedPID = nil
    }

    private func installWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(applicationActivated), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(sessionResigned), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(sessionBecameActive), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(systemWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(systemDidWake), name: NSWorkspace.didWakeNotification, object: nil)
        center.addObserver(self, selector: #selector(screensDidSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(screensDidWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(microcamBecameActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    private func removeWorkspaceObservers() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self, name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    @objc private func applicationActivated(_: Notification) {
        Task { @MainActor [weak self] in
            await self?.evaluateCurrentActivity(forceTransition: true)
        }
    }

    @objc private func microcamBecameActive(_: Notification) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await refreshAccessibilityStatus()
            await evaluateCurrentActivity(forceTransition: false)
        }
    }

    @objc private func sessionResigned(_: Notification) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            sessionSuspended = true
            await closeCurrent(at: Date())
        }
    }

    @objc private func sessionBecameActive(_: Notification) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            sessionSuspended = false
            await evaluateCurrentActivity(forceTransition: true)
            onWake?()
        }
    }

    @objc private func systemWillSleep(_: Notification) { sessionResigned(Notification(name: NSWorkspace.willSleepNotification)) }
    @objc private func screensDidSleep(_: Notification) { sessionResigned(Notification(name: NSWorkspace.screensDidSleepNotification)) }
    @objc private func systemDidWake(_: Notification) { sessionBecameActive(Notification(name: NSWorkspace.didWakeNotification)) }
    @objc private func screensDidWake(_: Notification) { sessionBecameActive(Notification(name: NSWorkspace.screensDidWakeNotification)) }
}

private func microcamAccessibilityCallback(
    _: AXObserver,
    _: AXUIElement,
    notification: CFString,
    refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let monitor = Unmanaged<ActivityMonitor>.fromOpaque(refcon).takeUnretainedValue()
    let focusedWindowChanged = CFEqual(
        notification,
        kAXFocusedWindowChangedNotification as CFString
    )
    Task { @MainActor in
        await monitor.accessibilityEventReceived(focusedWindowChanged: focusedWindowChanged)
    }
}
