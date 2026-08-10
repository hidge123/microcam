const root = document.querySelector("#app");
let state = null;
let activePage = "overview";
let refreshing = false;
let settingsDirty = false;

window.microcam.onStateChanged(() => {
  if (activePage !== "settings" || !settingsDirty) refresh();
});
refresh();

async function refresh() {
  if (refreshing) return;
  refreshing = true;
  try {
    state = await window.microcam.getState();
    render();
  } catch (error) {
    root.innerHTML = `<div class="loading failed">${escapeHTML(error.message)}</div>`;
  } finally {
    refreshing = false;
  }
}

function render() {
  const pages = {
    overview: renderOverview,
    activity: renderActivity,
    diaries: renderDiaries,
    settings: renderSettings
  };
  root.innerHTML = `
    <div class="shell">
      <aside class="sidebar">
        <div class="brand"><div class="brand-mark">M</div><div><strong>Microcam</strong><small>Windows · 隐私优先</small></div></div>
        <nav class="nav">
          ${navButton("overview", "今日概览")}
          ${navButton("activity", "活动记录")}
          ${navButton("diaries", "我的日记")}
          ${navButton("settings", "设置")}
        </nav>
        <div class="privacy-note">不记录按键、鼠标内容、截图、URL 或文件正文。窗口标题先脱敏，再加密落盘。</div>
      </aside>
      <section class="content">${pages[activePage]()}</section>
    </div>
    ${state.settings.onboardingComplete ? "" : renderOnboarding()}
  `;
  bindEvents();
}

function navButton(page, label) {
  return `<button data-page="${page}" class="${activePage === page ? "active" : ""}">${label}</button>`;
}

function renderOverview() {
  const today = state.days.find((day) => day.isToday);
  const monitor = monitorPresentation(state.monitor);
  const total = today?.activeSeconds ?? 0;
  return `
    ${pageHeader("今天", "活动在本机脱敏并加密，AI 只会收到聚合摘要。", pauseActions())}
    ${messageHTML()}
    <div class="grid stats">
      <div class="card"><div class="stat-label">记录状态</div><div class="stat-value status-row"><span class="status-dot ${monitor.tone}"></span>${escapeHTML(monitor.label)}</div><div class="stat-detail">${state.monitor.lastRecordedAt ? `最近写入 ${formatClock(state.monitor.lastRecordedAt)}` : "等待首条活动"}</div></div>
      <div class="card"><div class="stat-label">今日有效使用</div><div class="stat-value">${formatSeconds(total)}</div><div class="stat-detail">${today?.segmentCount ?? 0} 个活动片段</div></div>
      <div class="card"><div class="stat-label">应用数量</div><div class="stat-value">${today?.applications.length ?? 0}</div><div class="stat-detail">空闲时间不会计入</div></div>
    </div>
    <div class="grid two-column">
      <div class="card"><h2>最近活动</h2>${recentSegments()}</div>
      <div class="card"><h2>应用用时</h2>${applicationBars(today?.applications ?? [])}</div>
    </div>`;
}

function renderActivity() {
  return `
    ${pageHeader("活动记录", "这里只显示已经脱敏的标题；原始标题不会写入本地存储。")}
    ${messageHTML()}
    ${state.days.length ? state.days.map((day) => `
      <article class="card day-card">
        <div class="day-header"><div><h2>${escapeHTML(day.day)}${day.isToday ? " · 今天" : ""}</h2><div class="day-meta">${formatSeconds(day.activeSeconds)} · ${day.segmentCount} 个片段 · ${day.applications.length} 个应用</div></div><button class="button danger small" data-delete-activity="${day.day}">删除活动</button></div>
        <div class="app-chips">${day.applications.slice(0, 12).map((app) => `<span class="chip">${escapeHTML(app.appName)} · ${formatSeconds(app.activeSeconds)}</span>`).join("")}</div>
      </article>`).join("") : empty("尚无活动记录")}`;
}

function renderDiaries() {
  const diaryMap = new Map(state.diaries.map((diary) => [diary.day, diary]));
  const days = [...new Set([...state.days.map((day) => day.day), ...state.diaries.map((diary) => diary.day)])].sort().reverse();
  return `
    ${pageHeader("我的日记", "一天结束后，可手动生成或按计划自动生成日记。")}
    ${messageHTML()}
    ${days.length ? days.map((day) => {
      const diary = diaryMap.get(day);
      const activity = state.days.find((item) => item.day === day);
      const canGenerate = Boolean(activity && !activity.isToday);
      return `<article class="card diary-card">
        <div class="day-header"><div><h2>${escapeHTML(day)}</h2><div class="day-meta">${activity ? formatSeconds(activity.activeSeconds) : "活动明细已过期"} · ${diaryStatus(diary, activity)}</div></div>
          <div class="actions">
            ${diary?.content ? `<button class="button small" data-export-diary="${day}">导出 Markdown</button>` : ""}
            ${canGenerate ? `<button class="button primary small" data-generate-diary="${day}" ${state.generatingDay ? "disabled" : ""}>${diary?.content ? "重新生成" : "生成日记"}</button>` : ""}
            ${diary ? `<button class="button danger small" data-delete-diary="${day}">删除</button>` : ""}
          </div>
        </div>
        ${diary?.content ? `<div class="diary-content">${escapeHTML(diary.content)}</div>` : diary?.status === "failed" ? `<p class="failed">生成失败（${escapeHTML(diary.errorCode ?? "unknown")}），可检查 AI 设置后重试。</p>` : ""}
      </article>`;
    }).join("") : empty("还没有可生成日记的日期")}`;
}

function renderSettings() {
  const settings = state.settings;
  const applications = knownApplications();
  return `
    ${pageHeader("设置", "配置记录方式、自动生成时间和你自己的 OpenAI 兼容接口。", `<button class="button primary" type="submit" form="settings-form">保存设置</button>`)}
    ${messageHTML()}
    <form id="settings-form">
      <section class="card form-section"><h2>记录</h2><div class="form-grid">
        ${checkbox("recording-enabled", "启用活动记录", settings.recordingEnabled)}
        ${checkbox("launch-at-login", "登录 Windows 后自动启动", settings.launchAtLogin)}
        ${numberField("idle-minutes", "空闲阈值（分钟）", settings.idleMinutes, 1, 30)}
        ${selectField("retention-days", "活动保留时间", settings.retentionDays, [[0,"永久"],[7,"7 天"],[30,"30 天"],[90,"90 天"]])}
        <div class="field full"><label for="sensitive-terms">自定义敏感词（每行一个）</label><textarea id="sensitive-terms" autocomplete="off">${escapeHTML(settings.customSensitiveTerms.join("\n"))}</textarea></div>
        <div class="field full"><label for="custom-patterns">自定义正则（每行一个）</label><textarea id="custom-patterns" autocomplete="off">${escapeHTML(settings.customPatterns.join("\n"))}</textarea><div class="help">正则只在本机用于标题脱敏。无效表达式不会保存。</div></div>
      </div></section>
      <section class="card form-section"><h2>AI 日记</h2><div class="form-grid">
        <div class="field full"><label for="ai-base-url">Base URL</label><input id="ai-base-url" type="url" value="${escapeAttribute(settings.aiBaseURL)}" spellcheck="false"></div>
        <div class="field"><label for="ai-model">模型</label><input id="ai-model" value="${escapeAttribute(settings.aiModel)}" spellcheck="false"></div>
        <div class="field"><label for="api-key">API Key</label><input id="api-key" type="password" value="" placeholder="${settings.apiKeyConfigured ? "已安全保存；留空则不修改" : "可留空用于本地模型"}" autocomplete="new-password"></div>
        ${numberField("temperature", "Temperature", settings.temperature, 0, 2, "0.1")}
        ${numberField("max-tokens", "最大输出 Tokens", settings.maxTokens, 128, 8192)}
        ${numberField("timeout", "超时（秒）", settings.timeoutSeconds, 15, 300)}
        <div class="field"><label>自动生成时间</label><div class="actions"><input id="generation-hour" type="number" min="0" max="23" value="${settings.generationHour}" aria-label="小时"><input id="generation-minute" type="number" min="0" max="59" value="${settings.generationMinute}" aria-label="分钟"></div></div>
        ${checkbox("auto-generate", "自动生成上一完整日期", settings.autoGenerate)}
        ${checkbox("sharing-confirmed", "我确认脱敏活动摘要将发送到上述 Base URL", settings.aiDataSharingConfirmed, "full")}
        <div class="field full"><label for="prompt-template">日记提示词</label><textarea id="prompt-template" class="prompt">${escapeHTML(settings.promptTemplate)}</textarea><div class="help">必须包含 {{activity_summary}}；还支持 {{date}}、{{active_time}}、{{app_breakdown}}。</div></div>
        <div class="field full"><div class="actions"><button class="button" type="button" id="test-ai">保存并测试连接</button><button class="button danger" type="button" id="clear-api-key">清除 API Key</button></div></div>
      </div></section>
      <section class="card form-section"><h2>按应用记录策略</h2>${applications.length ? applications.map((app) => `
        <div class="policy-row"><div><div class="row-title">${escapeHTML(app.appName)}</div><div class="row-subtitle">${escapeHTML(app.appId)}</div></div><select data-policy-app="${escapeAttribute(app.appId)}"><option value="title" ${app.policy === "title" ? "selected" : ""}>应用与标题</option><option value="durationOnly" ${app.policy === "durationOnly" ? "selected" : ""}>仅记录时长</option><option value="exclude" ${app.policy === "exclude" ? "selected" : ""}>完全排除</option></select></div>`).join("") : empty("记录过应用后可在这里调整策略")}</section>
      <section class="card form-section"><h2>危险操作</h2><p class="help">彻底重置会清除活动、日记、API Key、脱敏规则与所有设置，无法恢复。</p><button class="button danger" type="button" id="reset-all">彻底重置 Microcam</button></section>
    </form>`;
}

function pageHeader(title, subtitle, actions = "") {
  return `<header class="page-header"><div><h1>${title}</h1><p>${subtitle}</p></div>${actions ? `<div class="actions">${actions}</div>` : ""}</header>`;
}

function pauseActions() {
  if (state.monitor.state === "paused") return `<button class="button primary" data-resume>恢复记录</button>`;
  return `<button class="button" data-pause="15">暂停 15 分钟</button><button class="button" data-pause="60">暂停 1 小时</button><button class="button" data-pause="manual">一直暂停</button>`;
}

function recentSegments() {
  if (!state.todaySegments.length) return empty("开始使用应用后，活动会显示在这里");
  return `<div class="list">${state.todaySegments.map((segment) => `<div class="list-row"><div class="time">${formatClock(segment.startAt)}–${formatClock(segment.endAt)}</div><div><div class="row-title">${escapeHTML(segment.appName)}</div><div class="row-subtitle">${escapeHTML(segment.sanitizedTitle ?? "仅记录时长")}</div></div><div class="duration">${formatSeconds((segment.endAt - segment.startAt) / 1000)}</div></div>`).join("")}</div>`;
}

function applicationBars(applications) {
  if (!applications.length) return empty("暂无今日用时")
  const maximum = Math.max(...applications.map((app) => app.activeSeconds), 1);
  return applications.slice(0, 8).map((app) => `<div class="bar-row"><div class="bar-label"><span>${escapeHTML(app.appName)}</span><span>${formatSeconds(app.activeSeconds)}</span></div><div class="bar-track"><div class="bar-fill" style="width:${Math.max(3, app.activeSeconds / maximum * 100)}%"></div></div></div>`).join("");
}

function knownApplications() {
  const values = new Map();
  for (const day of state.days) for (const app of day.applications) values.set(app.appId, { ...app });
  for (const appId of Object.keys(state.settings.capturePolicies)) if (!values.has(appId)) values.set(appId, { appId, appName: appId });
  return [...values.values()].map((app) => ({
    ...app,
    policy: state.settings.capturePolicies[app.appId] ?? (isSensitive(app.appId) ? "durationOnly" : "title")
  })).sort((a, b) => a.appName.localeCompare(b.appName));
}

function isSensitive(appId) {
  return ["1password.exe", "bitwarden.exe", "keepass.exe", "keepassxc.exe", "credentialuibroker.exe", "credentialmanager.exe"].includes(appId);
}

function renderOnboarding() {
  return `<div class="modal-backdrop"><section class="modal"><h1>欢迎使用 Microcam</h1><p>Microcam 会在 Windows 通知区域后台运行。它只记录前台应用、有效使用时长和已经脱敏的窗口标题。</p><div class="principles"><div class="principle"><strong>先脱敏</strong>原始标题只短暂存在内存，不会写入磁盘。</div><div class="principle"><strong>本机加密</strong>密钥由当前 Windows 用户的 DPAPI 保护。</div><div class="principle"><strong>由你发送</strong>只有确认 AI 目标后才发送聚合摘要。</div></div><p>密码管理器默认仅记录时长。你可以随时暂停记录、排除应用或彻底清除数据。</p><div class="actions"><button class="button primary" id="finish-onboarding">了解并开始</button></div></section></div>`;
}

function bindEvents() {
  document.querySelectorAll("[data-page]").forEach((button) => button.addEventListener("click", () => { activePage = button.dataset.page; settingsDirty = false; render(); }));
  document.querySelectorAll("[data-pause]").forEach((button) => button.addEventListener("click", async () => { await window.microcam.pause(button.dataset.pause === "manual" ? null : Number(button.dataset.pause)); await refresh(); }));
  document.querySelector("[data-resume]")?.addEventListener("click", async () => { await window.microcam.resume(); await refresh(); });
  document.querySelector("#finish-onboarding")?.addEventListener("click", async () => { await window.microcam.updateSettings({ onboardingComplete: true }); await refresh(); });
  document.querySelectorAll("[data-generate-diary]").forEach((button) => button.addEventListener("click", () => runAction(() => window.microcam.generateDiary(button.dataset.generateDiary))));
  document.querySelectorAll("[data-export-diary]").forEach((button) => button.addEventListener("click", () => runAction(() => window.microcam.exportDiary(button.dataset.exportDiary))));
  document.querySelectorAll("[data-delete-activity]").forEach((button) => button.addEventListener("click", () => confirmDelete("删除这一天的活动明细？", () => window.microcam.deleteDay(button.dataset.deleteActivity, "activity"))));
  document.querySelectorAll("[data-delete-diary]").forEach((button) => button.addEventListener("click", () => confirmDelete("删除这篇日记？", () => window.microcam.deleteDay(button.dataset.deleteDiary, "diary"))));
  document.querySelectorAll("[data-policy-app]").forEach((select) => select.addEventListener("change", () => runAction(() => window.microcam.setPolicy(select.dataset.policyApp, select.value))));
  document.querySelector("#settings-form")?.addEventListener("submit", (event) => { event.preventDefault(); runAction(saveSettings); });
  document.querySelector("#settings-form")?.addEventListener("input", () => { settingsDirty = true; });
  document.querySelector("#test-ai")?.addEventListener("click", () => runAction(async () => { await saveSettings(); await window.microcam.testAI(); }));
  document.querySelector("#clear-api-key")?.addEventListener("click", () => confirmDelete("清除已保存的 API Key？", () => window.microcam.updateSettings({ apiKey: "" })));
  document.querySelector("#reset-all")?.addEventListener("click", () => confirmDelete("彻底清除所有本地数据与设置？此操作无法恢复。", () => window.microcam.resetAll()));
}

async function saveSettings() {
  const apiKey = document.querySelector("#api-key").value;
  const patch = {
    recordingEnabled: document.querySelector("#recording-enabled").checked,
    launchAtLogin: document.querySelector("#launch-at-login").checked,
    idleMinutes: Number(document.querySelector("#idle-minutes").value),
    retentionDays: Number(document.querySelector("#retention-days").value),
    customSensitiveTerms: document.querySelector("#sensitive-terms").value,
    customPatterns: document.querySelector("#custom-patterns").value,
    aiBaseURL: document.querySelector("#ai-base-url").value,
    aiModel: document.querySelector("#ai-model").value,
    temperature: Number(document.querySelector("#temperature").value),
    maxTokens: Number(document.querySelector("#max-tokens").value),
    timeoutSeconds: Number(document.querySelector("#timeout").value),
    generationHour: Number(document.querySelector("#generation-hour").value),
    generationMinute: Number(document.querySelector("#generation-minute").value),
    autoGenerate: document.querySelector("#auto-generate").checked,
    aiDataSharingConfirmed: document.querySelector("#sharing-confirmed").checked,
    promptTemplate: document.querySelector("#prompt-template").value,
    ...(apiKey ? { apiKey } : {})
  };
  await window.microcam.updateSettings(patch);
  settingsDirty = false;
}

async function runAction(operation) {
  try { await operation(); } catch (error) { window.alert(error.message); }
  await refresh();
}

async function confirmDelete(question, operation) {
  if (window.confirm(question)) await runAction(operation);
}

function checkbox(id, label, checked, extraClass = "") {
  return `<label class="check ${extraClass}"><input id="${id}" type="checkbox" ${checked ? "checked" : ""}>${label}</label>`;
}

function numberField(id, label, value, min, max, step = "1") {
  return `<div class="field"><label for="${id}">${label}</label><input id="${id}" type="number" min="${min}" max="${max}" step="${step}" value="${value}"></div>`;
}

function selectField(id, label, value, options) {
  return `<div class="field"><label for="${id}">${label}</label><select id="${id}">${options.map(([key, name]) => `<option value="${key}" ${Number(value) === key ? "selected" : ""}>${name}</option>`).join("")}</select></div>`;
}

function monitorPresentation(monitor) {
  switch (monitor.state) {
    case "recording": return { label: monitor.currentApp ? `正在记录 ${monitor.currentApp}` : "正在记录", tone: "good" };
    case "paused": return { label: "已暂停", tone: "warn" };
    case "idle": return { label: "空闲中", tone: "warn" };
    case "excluded": return { label: "当前应用已排除", tone: "warn" };
    case "platform-unsupported": return { label: "请在 Windows 上验证采集", tone: "warn" };
    case "error": return { label: monitor.error ?? "记录异常", tone: "bad" };
    default: return { label: "记录已停止", tone: "bad" };
  }
}

function diaryStatus(diary, activity) {
  if (activity?.isToday) return "记录中";
  if (!diary) return activity ? "待生成" : "无活动";
  return { succeeded: "已生成", failed: "生成失败", pending: "生成中" }[diary.status] ?? diary.status;
}

function messageHTML() {
  return state.operationMessage ? `<div class="message">${escapeHTML(state.operationMessage)}</div>` : "";
}

function empty(text) { return `<div class="empty">${escapeHTML(text)}</div>`; }
function formatClock(value) { return new Date(value).toLocaleTimeString("zh-CN", { hour: "2-digit", minute: "2-digit" }); }
function formatSeconds(value) {
  const minutes = Math.max(0, Math.round(Number(value) / 60));
  const hours = Math.floor(minutes / 60);
  return hours ? `${hours} 小时${minutes % 60 ? ` ${minutes % 60} 分` : ""}` : `${minutes} 分钟`;
}
function escapeHTML(value) { return String(value ?? "").replace(/[&<>"']/gu, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;", "'": "&#39;" })[character]); }
function escapeAttribute(value) { return escapeHTML(value).replace(/`/gu, "&#96;"); }
