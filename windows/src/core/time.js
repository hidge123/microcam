export function localDayString(value = new Date()) {
  const date = value instanceof Date ? value : new Date(value);
  return [date.getFullYear(), date.getMonth() + 1, date.getDate()]
    .map((part, index) => (index === 0 ? String(part).padStart(4, "0") : String(part).padStart(2, "0")))
    .join("-");
}

export function parseLocalDay(day) {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(day);
  if (!match) return null;
  const date = new Date(Number(match[1]), Number(match[2]) - 1, Number(match[3]));
  return localDayString(date) === day ? date : null;
}

export function dayBounds(day) {
  const start = parseLocalDay(day);
  if (!start) return null;
  const end = new Date(start);
  end.setDate(end.getDate() + 1);
  return { start: start.getTime(), end: end.getTime() };
}

export function previousLocalDay(value = new Date()) {
  const date = new Date(value);
  date.setHours(0, 0, 0, 0);
  date.setDate(date.getDate() - 1);
  return localDayString(date);
}

export function formatDuration(minutes) {
  const rounded = Math.max(0, Math.round(minutes));
  const hours = Math.floor(rounded / 60);
  const remainder = rounded % 60;
  if (hours === 0) return `${remainder} 分钟`;
  if (remainder === 0) return `${hours} 小时`;
  return `${hours} 小时 ${remainder} 分钟`;
}
