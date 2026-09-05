import { randomUUID } from "node:crypto";
import { chmodSync, mkdirSync } from "node:fs";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import { dayBounds, localDayString } from "../core/time.js";

export class MicrocamDatabase {
  constructor(filePath, cryptoBox) {
    mkdirSync(path.dirname(filePath), { recursive: true });
    this.database = new DatabaseSync(filePath);
    this.cryptoBox = cryptoBox;
    this.database.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA busy_timeout=5000;");
    this.#migrate();
    try { chmodSync(filePath, 0o600); } catch { /* Windows ACLs are managed by the OS. */ }
  }

  close() {
    this.database.close();
  }

  saveSegment(segment) {
    const titleCiphertext = this.cryptoBox.seal(segment.sanitizedTitle);
    this.database.prepare(`
      INSERT INTO activity_segments
        (id, start_at, end_at, active_seconds, app_id, app_name, title_ciphertext, capture_policy, created_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        start_at = excluded.start_at,
        end_at = excluded.end_at,
        active_seconds = excluded.active_seconds,
        app_id = excluded.app_id,
        app_name = excluded.app_name,
        title_ciphertext = excluded.title_ciphertext,
        capture_policy = excluded.capture_policy;
    `).run(
      segment.id,
      segment.startAt,
      segment.endAt,
      Math.max(0, (segment.endAt - segment.startAt) / 1000),
      segment.appId,
      segment.appName,
      titleCiphertext,
      segment.capturePolicy,
      Date.now()
    );
  }

  fetchSegments(day, { limit = 10_000, offset = 0 } = {}) {
    const bounds = dayBounds(day);
    if (!bounds) return [];
    const rows = this.database.prepare(`
      SELECT id, start_at, end_at, app_id, app_name, title_ciphertext, capture_policy
      FROM activity_segments
      WHERE end_at > ? AND start_at < ?
      ORDER BY start_at DESC, id DESC
      LIMIT ? OFFSET ?;
    `).all(bounds.start, bounds.end, Math.min(Math.max(limit, 1), 10_000), Math.max(offset, 0));
    return rows.map((row) => this.#decodeSegment(row, bounds));
  }

  listDaySummaries(now = new Date()) {
    const rows = this.database.prepare(`
      SELECT start_at, end_at, app_id, app_name
      FROM activity_segments WHERE end_at > start_at ORDER BY start_at ASC;
    `).all();
    const days = new Map();
    for (const row of rows) {
      let cursor = Number(row.start_at);
      const recordEnd = Number(row.end_at);
      while (cursor < recordEnd) {
        const day = localDayString(cursor);
        const bounds = dayBounds(day);
        const sliceEnd = Math.min(recordEnd, bounds.end);
        const seconds = Math.max(0, (sliceEnd - cursor) / 1000);
        const summary = days.get(day) ?? { day, activeSeconds: 0, segmentCount: 0, applications: new Map() };
        summary.activeSeconds += seconds;
        summary.segmentCount += 1;
        const app = summary.applications.get(row.app_id) ?? { appId: row.app_id, appName: row.app_name, activeSeconds: 0 };
        app.activeSeconds += seconds;
        summary.applications.set(row.app_id, app);
        days.set(day, summary);
        cursor = sliceEnd;
      }
    }
    const today = localDayString(now);
    return [...days.values()].map((summary) => ({
      day: summary.day,
      activeSeconds: summary.activeSeconds,
      segmentCount: summary.segmentCount,
      applications: [...summary.applications.values()].sort((a, b) => b.activeSeconds - a.activeSeconds || a.appName.localeCompare(b.appName)),
      isToday: summary.day === today
    })).sort((a, b) => b.day.localeCompare(a.day));
  }

  saveDiary({ day, status, content = null, model, generatedAt = null, errorCode = null }) {
    this.database.prepare(`
      INSERT INTO diary_entries (day, status, content_ciphertext, model, generated_at, error_code)
      VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(day) DO UPDATE SET
        status = excluded.status,
        content_ciphertext = excluded.content_ciphertext,
        model = excluded.model,
        generated_at = excluded.generated_at,
        error_code = excluded.error_code;
    `).run(day, status, this.cryptoBox.seal(content), model, generatedAt, errorCode);
  }

  listDiaries() {
    return this.database.prepare(`
      SELECT day, status, content_ciphertext, model, generated_at, error_code
      FROM diary_entries ORDER BY day DESC;
    `).all().map((row) => ({
      day: row.day,
      status: row.status,
      content: this.#open(row.content_ciphertext),
      model: row.model,
      generatedAt: row.generated_at,
      errorCode: row.error_code
    }));
  }

  diaryFor(day) {
    const row = this.database.prepare(`
      SELECT day, status, content_ciphertext, model, generated_at, error_code
      FROM diary_entries WHERE day = ? LIMIT 1;
    `).get(day);
    return row ? {
      day: row.day,
      status: row.status,
      content: this.#open(row.content_ciphertext),
      model: row.model,
      generatedAt: row.generated_at,
      errorCode: row.error_code
    } : null;
  }

  deleteActivities(day) {
    const bounds = dayBounds(day);
    if (!bounds) return;
    const rows = this.database.prepare(`
      SELECT id, start_at, end_at, app_id, app_name, title_ciphertext, capture_policy
      FROM activity_segments WHERE end_at > ? AND start_at < ? ORDER BY start_at ASC;
    `).all(bounds.start, bounds.end).map((row) => ({
      id: row.id,
      startAt: Number(row.start_at),
      endAt: Number(row.end_at),
      appId: row.app_id,
      appName: row.app_name,
      sanitizedTitle: this.#open(row.title_ciphertext),
      capturePolicy: row.capture_policy
    }));
    this.database.exec("BEGIN IMMEDIATE;");
    try {
      this.database.prepare("DELETE FROM activity_segments WHERE end_at > ? AND start_at < ?;").run(bounds.start, bounds.end);
      for (const segment of rows) {
        if (segment.startAt < bounds.start) this.saveSegment({ ...segment, endAt: bounds.start });
        if (segment.endAt > bounds.end) {
          this.saveSegment({
            ...segment,
            id: segment.startAt < bounds.start ? randomUUID() : segment.id,
            startAt: bounds.end
          });
        }
      }
      this.database.exec("COMMIT;");
    } catch (error) {
      this.database.exec("ROLLBACK;");
      throw error;
    }
  }

  deleteDiary(day) {
    this.database.prepare("DELETE FROM diary_entries WHERE day = ?;").run(day);
  }

  cleanup(retentionDays) {
    if (!retentionDays) return;
    const cutoff = new Date();
    cutoff.setHours(0, 0, 0, 0);
    cutoff.setDate(cutoff.getDate() - retentionDays);
    this.database.prepare("DELETE FROM activity_segments WHERE end_at < ?;").run(cutoff.getTime());
  }

  deleteAll() {
    this.database.exec("BEGIN IMMEDIATE;");
    try {
      this.database.exec("DELETE FROM activity_segments; DELETE FROM diary_entries; COMMIT; PRAGMA wal_checkpoint(TRUNCATE);");
    } catch (error) {
      this.database.exec("ROLLBACK;");
      throw error;
    }
  }

  createSegment(value) {
    return { id: randomUUID(), ...value };
  }

  #decodeSegment(row, bounds) {
    return {
      id: row.id,
      startAt: Math.max(Number(row.start_at), bounds.start),
      endAt: Math.min(Number(row.end_at), bounds.end),
      appId: row.app_id,
      appName: row.app_name,
      sanitizedTitle: this.#open(row.title_ciphertext),
      capturePolicy: row.capture_policy
    };
  }

  #open(value) {
    try {
      return this.cryptoBox.open(value);
    } catch {
      throw new Error("本地加密数据无法解密；数据可能已损坏或属于另一位 Windows 用户");
    }
  }

  #migrate() {
    this.database.exec(`
      CREATE TABLE IF NOT EXISTS activity_segments (
        id TEXT PRIMARY KEY NOT NULL,
        start_at INTEGER NOT NULL,
        end_at INTEGER NOT NULL,
        active_seconds REAL NOT NULL,
        app_id TEXT NOT NULL,
        app_name TEXT NOT NULL,
        title_ciphertext BLOB,
        capture_policy TEXT NOT NULL,
        created_at INTEGER NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_activity_time ON activity_segments(start_at, end_at);
      CREATE INDEX IF NOT EXISTS idx_activity_app ON activity_segments(app_id);
      CREATE TABLE IF NOT EXISTS diary_entries (
        day TEXT PRIMARY KEY NOT NULL,
        status TEXT NOT NULL,
        content_ciphertext BLOB,
        model TEXT NOT NULL,
        generated_at INTEGER,
        error_code TEXT
      );
      PRAGMA user_version=1;
    `);
  }
}
