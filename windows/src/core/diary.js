import { dayBounds, formatDuration, localDayString } from "./time.js";

const SUPPORTED_PLACEHOLDERS = new Set(["date", "active_time", "app_breakdown", "activity_summary"]);

export function aggregateDiary(segments, day) {
  const bounds = dayBounds(day);
  if (!bounds) throw new Error("日期格式无效");

  const grouped = new Map();
  const applicationSeconds = new Map();
  let totalSeconds = 0;

  for (const segment of segments) {
    let cursor = Math.max(Number(segment.startAt), bounds.start);
    const segmentEnd = Math.min(Number(segment.endAt), bounds.end);
    if (!(cursor < segmentEnd)) continue;

    while (cursor < segmentEnd) {
      const hourStart = new Date(cursor);
      hourStart.setMinutes(0, 0, 0);
      const hourEnd = new Date(hourStart);
      hourEnd.setHours(hourEnd.getHours() + 1);
      const sliceEnd = Math.min(segmentEnd, hourEnd.getTime());
      const seconds = Math.max(0, (sliceEnd - cursor) / 1000);
      const hour = `${String(hourStart.getHours()).padStart(2, "0")}:00`;
      const activity = segment.sanitizedTitle || "未记录窗口标题";
      const key = JSON.stringify([hour, segment.appName, activity]);
      grouped.set(key, (grouped.get(key) ?? 0) + seconds);
      applicationSeconds.set(segment.appName, (applicationSeconds.get(segment.appName) ?? 0) + seconds);
      totalSeconds += seconds;
      cursor = sliceEnd;
    }
  }

  const activities = [...grouped.entries()]
    .map(([key, seconds]) => {
      const [hour, application, activity] = JSON.parse(key);
      return { hour, application, activity, minutes: Math.max(1, Math.round(seconds / 60)) };
    })
    .sort((a, b) => a.hour.localeCompare(b.hour) || a.application.localeCompare(b.application) || a.activity.localeCompare(b.activity))
    .slice(0, 500);

  return {
    date: day,
    activeMinutes: Math.round(totalSeconds / 60),
    applicationBreakdown: Object.fromEntries(
      [...applicationSeconds.entries()].map(([name, seconds]) => [name, Math.round(seconds / 60)])
    ),
    activities
  };
}

export function renderPrompt(template, payload) {
  if (!template.includes("{{activity_summary}}")) {
    throw new Error("提示词必须包含 {{activity_summary}}");
  }
  for (const match of template.matchAll(/\{\{\s*([a-zA-Z0-9_]+)\s*\}\}/gu)) {
    if (!SUPPORTED_PLACEHOLDERS.has(match[1])) throw new Error(`不支持提示词变量：{{${match[1]}}}`);
  }

  const appBreakdown = Object.entries(payload.applicationBreakdown)
    .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
    .map(([name, minutes]) => `- ${name}：${formatDuration(minutes)}`)
    .join("\n");
  let activitySummary = payload.activities
    .map((row) => `- ${row.hour} · ${row.application} · ${row.activity}（${row.minutes} 分钟）`)
    .join("\n");
  if (activitySummary.length > 12_000) activitySummary = `${activitySummary.slice(0, 12_000)}\n- [摘要因长度限制已截断]`;

  return template
    .replaceAll("{{date}}", payload.date)
    .replaceAll("{{active_time}}", formatDuration(payload.activeMinutes))
    .replaceAll("{{app_breakdown}}", appBreakdown || "无活动")
    .replaceAll("{{activity_summary}}", activitySummary || "无活动");
}

export function automaticDiaryDue(day, hour, minute, now = new Date()) {
  const [year, month, date] = day.split("-").map(Number);
  const due = new Date(year, month - 1, date + 1, hour, minute, 0, 0);
  return localDayString(due) !== day && now.getTime() >= due.getTime();
}
