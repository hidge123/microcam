export const DEFAULT_PROMPT = `请根据 {{date}} 的电脑活动生成一篇中文日记。语气自然、克制，重点描述完成的事情、投入的时间和一天的节奏，不要逐条罗列日志，也不要编造活动中没有体现的事实。

今日有效使用时间：{{active_time}}

应用用时：
{{app_breakdown}}

活动摘要：
{{activity_summary}}`;

export const DEFAULT_SETTINGS = Object.freeze({
  recordingEnabled: true,
  idleMinutes: 5,
  retentionDays: 30,
  autoGenerate: true,
  generationHour: 0,
  generationMinute: 5,
  aiBaseURL: "https://api.openai.com/v1",
  aiModel: "gpt-5-mini",
  temperature: 0.7,
  maxTokens: 1600,
  timeoutSeconds: 120,
  promptTemplate: DEFAULT_PROMPT,
  aiDataSharingConfirmed: false,
  launchAtLogin: false,
  onboardingComplete: false,
  capturePolicies: {},
  autoAttemptedDays: []
});

export const SENSITIVE_EXECUTABLES = new Set([
  "1password.exe",
  "bitwarden.exe",
  "keepass.exe",
  "keepassxc.exe",
  "credentialuibroker.exe",
  "credentialmanager.exe"
]);

export function normalizeSettings(value = {}) {
  const retention = Number(value.retentionDays);
  return {
    ...DEFAULT_SETTINGS,
    ...value,
    recordingEnabled: value.recordingEnabled !== false,
    idleMinutes: clampInteger(value.idleMinutes, 1, 30, 5),
    retentionDays: [0, 7, 30, 90].includes(retention) ? retention : 30,
    autoGenerate: value.autoGenerate !== false,
    generationHour: clampInteger(value.generationHour, 0, 23, 0),
    generationMinute: clampInteger(value.generationMinute, 0, 59, 5),
    temperature: clampNumber(value.temperature, 0, 2, 0.7),
    maxTokens: clampInteger(value.maxTokens, 128, 8192, 1600),
    timeoutSeconds: clampNumber(value.timeoutSeconds, 15, 300, 120),
    capturePolicies: isPlainObject(value.capturePolicies) ? value.capturePolicies : {},
    autoAttemptedDays: Array.isArray(value.autoAttemptedDays)
      ? [...new Set(value.autoAttemptedDays.filter((day) => /^\d{4}-\d{2}-\d{2}$/.test(day)))].slice(-120)
      : []
  };
}

function clampInteger(value, minimum, maximum, fallback) {
  const number = Number(value);
  return Number.isFinite(number)
    ? Math.min(maximum, Math.max(minimum, Math.round(number)))
    : fallback;
}

function clampNumber(value, minimum, maximum, fallback) {
  const number = Number(value);
  return Number.isFinite(number) ? Math.min(maximum, Math.max(minimum, number)) : fallback;
}

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}
