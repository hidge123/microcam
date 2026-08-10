const BUILT_IN_RULES = [
  [/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/giu, "[邮箱]"],
  [/https?:\/\/[^\s]+/giu, "[网址]"],
  [/(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])/gu, "[IP]"],
  [/(?<![0-9A-F:])(?:[0-9A-F]{1,4}:){2,7}[0-9A-F]{1,4}(?![0-9A-F:])/giu, "[IP]"],
  [/(?:[A-Z]:\\Users\\[^\\\s]+|\\\\[^\\\s]+\\[^\\\s]+)(?:\\[^\s\\]+)+/giu, "[文件路径]"],
  [/(?:\/Users\/[^/\s]+|~)(?:\/[^\s/]+)+/gu, "[文件路径]"],
  [/(?<!\d)(?:\+?\d[\s().-]?){7,15}(?!\d)/gu, "[电话]"],
  [/\b\d{8,}\b/gu, "[编号]"],
  [/\b(?:sk|pk|api|token|key)[-_][A-Za-z0-9_-]{8,}\b/giu, "[密钥]"],
  [/\b[A-Za-z0-9_=-]{32,}\b/gu, "[疑似令牌]"]
];

export class Redactor {
  constructor({ customTerms = [], customPatterns = [], username = "", maximumLength = 240 } = {}) {
    this.maximumLength = maximumLength;
    this.rules = BUILT_IN_RULES.map(([regex, replacement]) => [cloneRegex(regex), replacement]);

    if (username.trim()) {
      this.rules.push([new RegExp(escapeRegExp(username.trim()), "giu"), "[用户名]"]);
    }
    for (const term of customTerms) {
      if (typeof term === "string" && term.trim()) {
        this.rules.push([new RegExp(escapeRegExp(term.trim()), "giu"), "[自定义敏感词]"]);
      }
    }
    for (const pattern of customPatterns) {
      if (typeof pattern !== "string" || !pattern.trim()) continue;
      try {
        this.rules.push([new RegExp(pattern, "giu"), "[自定义隐藏]"]);
      } catch {
        // Invalid custom rules are ignored; validation is surfaced in the settings UI.
      }
    }
  }

  redact(input) {
    if (typeof input !== "string" || input.length === 0) return null;
    let value = input.slice(0, this.maximumLength * 4);
    for (const [regex, replacement] of this.rules) value = value.replace(regex, replacement);
    value = value.replace(/\s+/gu, " ").trim();
    return value.length > 0 ? value.slice(0, this.maximumLength) : null;
  }
}

export function validateCustomPatterns(patterns) {
  const errors = [];
  for (const pattern of patterns ?? []) {
    if (typeof pattern !== "string" || !pattern.trim()) continue;
    try {
      new RegExp(pattern, "giu");
    } catch (error) {
      errors.push(`正则 ${pattern} 无效：${error.message}`);
    }
  }
  return errors;
}

function cloneRegex(regex) {
  return new RegExp(regex.source, regex.flags);
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
}
