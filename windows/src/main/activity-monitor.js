import { EventEmitter } from "node:events";
import os from "node:os";
import { Redactor } from "../core/redactor.js";
import { SENSITIVE_EXECUTABLES } from "../core/defaults.js";
import { dayBounds, localDayString } from "../core/time.js";

const CHECKPOINT_INTERVAL = 30_000;

export class ActivityMonitor extends EventEmitter {
  constructor({ settingsStore, database, collector }) {
    super();
    this.settingsStore = settingsStore;
    this.database = database;
    this.collector = collector;
    this.current = null;
    this.manualPause = false;
    this.pauseUntil = null;
    this.sessionSuspended = false;
    this.lastPersistedAt = null;
    this.lastCheckpoint = 0;
    this.state = process.platform === "win32" ? "stopped" : "platform-unsupported";
    this.error = null;
    this.redactor = null;
    this.refreshRedactor();
    collector.on("snapshot", (snapshot) => this.#handleSnapshot(snapshot));
    collector.on("error", (error) => this.#setError(error.message));
    collector.on("unsupported", () => this.#setState("platform-unsupported"));
  }

  start() {
    this.collector.start();
    if (process.platform === "win32") this.#setState("recording");
  }

  stop() {
    this.collector.stop();
    this.closeCurrent(Date.now());
    this.#setState("stopped");
  }

  suspend() {
    this.sessionSuspended = true;
    this.closeCurrent(Date.now());
    this.#setState("suspended");
  }

  resumeFromSuspend() {
    this.sessionSuspended = false;
    if (!this.manualPause && !this.pauseUntil) this.#setState("recording");
  }

  pause(minutes = null) {
    this.manualPause = minutes === null;
    this.pauseUntil = minutes === null ? null : Date.now() + Math.max(1, Number(minutes)) * 60_000;
    this.closeCurrent(Date.now());
    this.#setState("paused");
  }

  resume() {
    this.manualPause = false;
    this.pauseUntil = null;
    this.#setState(this.settingsStore.value.recordingEnabled ? "recording" : "stopped");
  }

  refreshRedactor() {
    const settings = this.settingsStore.snapshot();
    this.redactor = new Redactor({
      customTerms: settings.customSensitiveTerms,
      customPatterns: settings.customPatterns,
      username: os.userInfo().username
    });
  }

  snapshot() {
    return {
      state: this.state,
      currentApp: this.current?.appName ?? null,
      pauseUntil: this.pauseUntil,
      lastRecordedAt: this.lastPersistedAt,
      error: this.error
    };
  }

  closeCurrent(requestedEnd) {
    if (!this.current) return;
    const segment = this.current;
    this.current = null;
    segment.endAt = Math.max(segment.startAt, Math.min(requestedEnd, Date.now()));
    if (segment.endAt > segment.startAt) this.#persist(segment);
  }

  #handleSnapshot(snapshot) {
    const now = Number(snapshot.capturedAt) || Date.now();
    const settings = this.settingsStore.value;
    if (this.pauseUntil && now >= this.pauseUntil) this.resume();

    if (this.sessionSuspended) return;

    if (!settings.recordingEnabled) {
      this.closeCurrent(now);
      this.#setState("stopped");
      return;
    }
    if (this.manualPause || this.pauseUntil) {
      this.closeCurrent(now);
      this.#setState("paused");
      return;
    }
    if (snapshot.unavailable || !snapshot.executable) {
      this.closeCurrent(now);
      this.#setState("unavailable");
      return;
    }

    if (this.current && localDayString(this.current.startAt) !== localDayString(now)) {
      const boundary = dayBounds(localDayString(this.current.startAt)).end;
      this.closeCurrent(boundary);
    }

    const idleSeconds = Math.max(0, Number(snapshot.idleSeconds) || 0);
    const thresholdSeconds = settings.idleMinutes * 60;
    if (idleSeconds >= thresholdSeconds) {
      const idleBoundary = now - ((idleSeconds - thresholdSeconds) * 1000);
      this.closeCurrent(idleBoundary);
      this.#setState("idle");
      return;
    }

    const appId = String(snapshot.executable).toLowerCase();
    const appName = String(snapshot.appName || snapshot.executable).slice(0, 160);
    const configuredPolicy = this.settingsStore.policyFor(appId);
    const policy = configuredPolicy ?? (SENSITIVE_EXECUTABLES.has(appId) ? "durationOnly" : "title");
    if (policy === "exclude") {
      this.closeCurrent(now);
      this.#setState("excluded");
      return;
    }

    // The raw title is scoped to this expression and never logged or persisted.
    const sanitizedTitle = policy === "title" ? this.redactor.redact(snapshot.title) : null;
    const changed = !this.current || this.current.appId !== appId ||
      this.current.capturePolicy !== policy || this.current.sanitizedTitle !== sanitizedTitle;
    if (changed) {
      this.closeCurrent(now);
      this.current = this.database.createSegment({
        startAt: now,
        endAt: now,
        appId,
        appName,
        sanitizedTitle,
        capturePolicy: policy
      });
    } else {
      this.current.endAt = now;
    }

    if (now - this.lastCheckpoint >= CHECKPOINT_INTERVAL && this.current.endAt > this.current.startAt) {
      this.#persist(this.current);
    }
    this.error = null;
    this.#setState("recording");
  }

  #persist(segment) {
    try {
      this.database.saveSegment(segment);
      this.lastPersistedAt = Date.now();
      this.lastCheckpoint = this.lastPersistedAt;
      this.emit("persisted");
    } catch {
      this.#setError("活动日志写入失败");
    }
  }

  #setError(message) {
    this.error = message;
    this.#setState("error");
  }

  #setState(value) {
    if (this.state === value) return;
    this.state = value;
    this.emit("changed", this.snapshot());
  }
}
