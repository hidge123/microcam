import { chmodSync, existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import path from "node:path";
import { DEFAULT_SETTINGS, normalizeSettings } from "../core/defaults.js";
import { validateCustomPatterns } from "../core/redactor.js";

const EDITABLE_KEYS = new Set([
  "recordingEnabled", "idleMinutes", "retentionDays", "autoGenerate",
  "generationHour", "generationMinute", "aiBaseURL", "aiModel", "temperature",
  "maxTokens", "timeoutSeconds", "promptTemplate", "aiDataSharingConfirmed",
  "launchAtLogin", "onboardingComplete", "capturePolicies", "autoAttemptedDays"
]);

export class SettingsStore {
  constructor(filePath, secureStore) {
    this.filePath = filePath;
    this.secureStore = secureStore;
    this.value = this.#read();
  }

  snapshot() {
    const rules = this.#readRedactionRules();
    return {
      ...structuredClone(this.value),
      apiKeyConfigured: Boolean(this.secureStore.get("ai-api-key")),
      customSensitiveTerms: rules.terms,
      customPatterns: rules.patterns
    };
  }

  aiConfiguration() {
    return {
      baseURL: this.value.aiBaseURL,
      apiKey: this.secureStore.get("ai-api-key") ?? "",
      model: this.value.aiModel,
      temperature: this.value.temperature,
      maxTokens: this.value.maxTokens,
      timeoutSeconds: this.value.timeoutSeconds
    };
  }

  update(patch) {
    const next = { ...this.value };
    for (const [key, value] of Object.entries(patch ?? {})) {
      if (EDITABLE_KEYS.has(key)) next[key] = value;
    }
    if (typeof patch?.aiBaseURL === "string" && patch.aiBaseURL !== this.value.aiBaseURL) {
      next.aiDataSharingConfirmed = false;
    }
    if (typeof patch?.promptTemplate === "string" && !patch.promptTemplate.includes("{{activity_summary}}")) {
      throw new Error("提示词必须包含 {{activity_summary}}");
    }
    if (Object.hasOwn(patch ?? {}, "apiKey")) this.secureStore.set("ai-api-key", patch.apiKey);
    if (Object.hasOwn(patch ?? {}, "customSensitiveTerms") || Object.hasOwn(patch ?? {}, "customPatterns")) {
      const current = this.#readRedactionRules();
      const terms = normalizeLines(patch.customSensitiveTerms ?? current.terms);
      const patterns = normalizeLines(patch.customPatterns ?? current.patterns);
      const errors = validateCustomPatterns(patterns);
      if (errors.length) throw new Error(errors[0]);
      this.secureStore.set("redaction-rules", JSON.stringify({ terms, patterns }));
    }
    this.value = normalizeSettings(next);
    this.#write();
    return this.snapshot();
  }

  policyFor(executable) {
    const key = executable.toLowerCase();
    return this.value.capturePolicies[key] ?? null;
  }

  reset() {
    this.value = structuredClone(DEFAULT_SETTINGS);
    this.secureStore.set("ai-api-key", null);
    this.secureStore.set("redaction-rules", null);
    this.#write();
  }

  #readRedactionRules() {
    try {
      const parsed = JSON.parse(this.secureStore.get("redaction-rules") ?? "{}");
      return {
        terms: normalizeLines(parsed.terms),
        patterns: normalizeLines(parsed.patterns)
      };
    } catch {
      return { terms: [], patterns: [] };
    }
  }

  #read() {
    if (!existsSync(this.filePath)) return structuredClone(DEFAULT_SETTINGS);
    try {
      return normalizeSettings(JSON.parse(readFileSync(this.filePath, "utf8")));
    } catch {
      throw new Error("设置文件已损坏");
    }
  }

  #write() {
    mkdirSync(path.dirname(this.filePath), { recursive: true });
    const temporaryPath = `${this.filePath}.tmp`;
    writeFileSync(temporaryPath, `${JSON.stringify(this.value, null, 2)}\n`, { mode: 0o600 });
    renameSync(temporaryPath, this.filePath);
    try { chmodSync(this.filePath, 0o600); } catch { /* Windows ACLs are managed by the OS. */ }
  }
}

function normalizeLines(value) {
  if (Array.isArray(value)) {
    return [...new Set(value.map(String).map((item) => item.trim()).filter((item) => item && item.length <= 256))].slice(0, 100);
  }
  if (typeof value === "string") return normalizeLines(value.split(/\r?\n/u));
  return [];
}
