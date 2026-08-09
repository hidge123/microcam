import Combine
import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    private enum Key {
        static let recordingEnabled = "recordingEnabled"
        static let idleMinutes = "idleMinutes"
        static let retentionDays = "retentionDays"
        static let autoGenerate = "autoGenerate"
        static let generationHour = "generationHour"
        static let generationMinute = "generationMinute"
        static let aiBaseURL = "aiBaseURL"
        static let aiModel = "aiModel"
        static let temperature = "temperature"
        static let maxTokens = "maxTokens"
        static let timeout = "timeout"
        static let promptTemplate = "promptTemplate"
        static let aiDataSharingConfirmed = "aiDataSharingConfirmed"
        static let policies = "capturePolicies"
        static let onboardingComplete = "onboardingComplete"
        static let lastAutoAttemptDay = "lastAutoAttemptDay"
    }

    private let defaults: UserDefaults

    @Published var recordingEnabled: Bool {
        didSet { defaults.set(recordingEnabled, forKey: Key.recordingEnabled) }
    }
    @Published var idleMinutes: Int {
        didSet { defaults.set(min(max(idleMinutes, 1), 30), forKey: Key.idleMinutes) }
    }
    @Published var retentionDays: Int {
        didSet { defaults.set(retentionDays, forKey: Key.retentionDays) }
    }
    @Published var autoGenerate: Bool {
        didSet { defaults.set(autoGenerate, forKey: Key.autoGenerate) }
    }
    @Published var generationHour: Int {
        didSet { defaults.set(generationHour, forKey: Key.generationHour) }
    }
    @Published var generationMinute: Int {
        didSet { defaults.set(generationMinute, forKey: Key.generationMinute) }
    }
    @Published var aiBaseURL: String {
        didSet {
            defaults.set(aiBaseURL, forKey: Key.aiBaseURL)
            if aiBaseURL != oldValue { aiDataSharingConfirmed = false }
        }
    }
    @Published var aiModel: String {
        didSet { defaults.set(aiModel, forKey: Key.aiModel) }
    }
    @Published var temperature: Double {
        didSet { defaults.set(temperature, forKey: Key.temperature) }
    }
    @Published var maxTokens: Int {
        didSet { defaults.set(maxTokens, forKey: Key.maxTokens) }
    }
    @Published var timeout: TimeInterval {
        didSet { defaults.set(timeout, forKey: Key.timeout) }
    }
    @Published var promptTemplate: String {
        didSet { defaults.set(promptTemplate, forKey: Key.promptTemplate) }
    }
    @Published var aiDataSharingConfirmed: Bool {
        didSet { defaults.set(aiDataSharingConfirmed, forKey: Key.aiDataSharingConfirmed) }
    }
    @Published var apiKey: String
    @Published var customSensitiveTerms: [String]
    @Published var customPatterns: [String]
    @Published private(set) var capturePolicies: [String: AppCapturePolicy]
    @Published var onboardingComplete: Bool {
        didSet { defaults.set(onboardingComplete, forKey: Key.onboardingComplete) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.recordingEnabled: true,
            Key.idleMinutes: 5,
            Key.retentionDays: 30,
            Key.autoGenerate: true,
            Key.generationHour: 0,
            Key.generationMinute: 5,
            Key.aiBaseURL: "https://api.openai.com/v1",
            Key.aiModel: "gpt-5-mini",
            Key.temperature: 0.7,
            Key.maxTokens: 1600,
            Key.timeout: 120.0,
            Key.promptTemplate: MicrocamDefaults.promptTemplate,
            Key.aiDataSharingConfirmed: false,
            Key.onboardingComplete: false
        ])

        recordingEnabled = defaults.bool(forKey: Key.recordingEnabled)
        idleMinutes = min(max(defaults.integer(forKey: Key.idleMinutes), 1), 30)
        let storedRetention = defaults.integer(forKey: Key.retentionDays)
        retentionDays = [0, 7, 30, 90].contains(storedRetention) ? storedRetention : 30
        autoGenerate = defaults.bool(forKey: Key.autoGenerate)
        generationHour = min(max(defaults.integer(forKey: Key.generationHour), 0), 23)
        generationMinute = min(max(defaults.integer(forKey: Key.generationMinute), 0), 59)
        aiBaseURL = defaults.string(forKey: Key.aiBaseURL) ?? "https://api.openai.com/v1"
        aiModel = defaults.string(forKey: Key.aiModel) ?? "gpt-5-mini"
        temperature = min(max(defaults.double(forKey: Key.temperature), 0), 2)
        maxTokens = min(max(defaults.integer(forKey: Key.maxTokens), 128), 8192)
        timeout = min(max(defaults.double(forKey: Key.timeout), 15), 300)
        promptTemplate = defaults.string(forKey: Key.promptTemplate) ?? MicrocamDefaults.promptTemplate
        aiDataSharingConfirmed = defaults.bool(forKey: Key.aiDataSharingConfirmed)
        onboardingComplete = defaults.bool(forKey: Key.onboardingComplete)

        if
            let policyData = defaults.data(forKey: Key.policies),
            let rawPolicies = try? JSONDecoder().decode([String: String].self, from: policyData)
        {
            capturePolicies = rawPolicies.reduce(into: [:]) { result, item in
                result[item.key] = AppCapturePolicy(rawValue: item.value)
            }
        } else {
            capturePolicies = [:]
        }

        apiKey = (try? KeychainStore.string(for: .apiKey)) ?? ""
        if
            let data = try? KeychainStore.data(for: .redactionTerms),
            let payload = try? JSONDecoder().decode(RedactionSecrets.self, from: data)
        {
            customSensitiveTerms = payload.terms
            customPatterns = payload.patterns
        } else {
            customSensitiveTerms = []
            customPatterns = []
        }
    }

    var aiConfiguration: AIConfiguration {
        AIConfiguration(
            baseURL: aiBaseURL,
            apiKey: apiKey,
            model: aiModel,
            temperature: temperature,
            maxTokens: maxTokens,
            timeout: timeout
        )
    }

    var redactor: Redactor {
        Redactor(customTerms: customSensitiveTerms, customPatterns: customPatterns)
    }

    var promptValidationMessage: String? {
        promptTemplate.contains("{{activity_summary}}") ? nil : "提示词必须包含 {{activity_summary}}"
    }

    func policy(for bundleID: String) -> AppCapturePolicy {
        if let explicit = capturePolicies[bundleID] { return explicit }
        return MicrocamDefaults.sensitiveBundleIDs.contains(bundleID) ? .durationOnly : .title
    }

    func setPolicy(_ policy: AppCapturePolicy, for bundleID: String) {
        capturePolicies[bundleID] = policy
        persistPolicies()
    }

    func saveAISecret() throws {
        if apiKey.isEmpty {
            try KeychainStore.delete(.apiKey)
        } else {
            try KeychainStore.set(apiKey, for: .apiKey)
        }
        defaults.removeObject(forKey: Key.lastAutoAttemptDay)
    }

    func saveRedactionSecrets() throws {
        let data = try JSONEncoder().encode(RedactionSecrets(
            terms: customSensitiveTerms,
            patterns: customPatterns
        ))
        try KeychainStore.set(data, for: .redactionTerms)
    }

    func resetPrompt() {
        promptTemplate = MicrocamDefaults.promptTemplate
        aiDataSharingConfirmed = false
    }

    func markAutoAttempt(for day: String) {
        defaults.set(day, forKey: Key.lastAutoAttemptDay)
    }

    func hasAutoAttempted(day: String) -> Bool {
        defaults.string(forKey: Key.lastAutoAttemptDay) == day
    }

    func restoreDefaults() {
        recordingEnabled = true
        idleMinutes = 5
        retentionDays = 30
        autoGenerate = true
        generationHour = 0
        generationMinute = 5
        aiBaseURL = "https://api.openai.com/v1"
        aiModel = "gpt-5-mini"
        temperature = 0.7
        maxTokens = 1600
        timeout = 120
        promptTemplate = MicrocamDefaults.promptTemplate
        apiKey = ""
        customSensitiveTerms = []
        customPatterns = []
        capturePolicies = [:]
        onboardingComplete = false
        defaults.removeObject(forKey: Key.policies)
        defaults.removeObject(forKey: Key.lastAutoAttemptDay)
    }

    private func persistPolicies() {
        let raw = capturePolicies.mapValues(\.rawValue)
        if let data = try? JSONEncoder().encode(raw) {
            defaults.set(data, forKey: Key.policies)
        }
    }
}

private struct RedactionSecrets: Codable {
    let terms: [String]
    let patterns: [String]
}
