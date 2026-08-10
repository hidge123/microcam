import { EventEmitter } from "node:events";
import { aggregateDiary, automaticDiaryDue, renderPrompt } from "../core/diary.js";
import { localDayString } from "../core/time.js";
import { AIClient } from "../core/ai-client.js";

export class AppController extends EventEmitter {
  constructor({ settingsStore, database, monitor }) {
    super();
    this.settingsStore = settingsStore;
    this.database = database;
    this.monitor = monitor;
    this.aiClient = new AIClient();
    this.operationMessage = null;
    this.generatingDay = null;
    this.refreshTimer = null;
    this.schedulerTimer = null;
    this.stopped = false;
    monitor.on("changed", () => this.emit("changed"));
    monitor.on("persisted", () => this.#scheduleRefresh());
  }

  start() {
    this.stopped = false;
    this.database.cleanup(this.settingsStore.value.retentionDays);
    this.monitor.start();
    this.schedulerTimer = setInterval(() => this.checkAutomaticDiary().catch(() => {}), 60_000);
    this.checkAutomaticDiary().catch(() => {});
  }

  stop() {
    if (this.stopped) return;
    this.stopped = true;
    clearInterval(this.schedulerTimer);
    clearTimeout(this.refreshTimer);
    this.monitor.stop();
    this.database.close();
  }

  state() {
    const today = localDayString();
    return {
      platform: process.platform,
      monitor: this.monitor.snapshot(),
      settings: this.settingsStore.snapshot(),
      days: this.database.listDaySummaries(),
      diaries: this.database.listDiaries(),
      todaySegments: this.database.fetchSegments(today, { limit: 8 }),
      operationMessage: this.operationMessage,
      generatingDay: this.generatingDay
    };
  }

  updateSettings(patch) {
    const settings = this.settingsStore.update(patch);
    this.monitor.refreshRedactor();
    this.database.cleanup(settings.retentionDays);
    this.emit("changed");
    return settings;
  }

  setCapturePolicy(appId, policy) {
    if (!["title", "durationOnly", "exclude"].includes(policy)) throw new Error("记录策略无效");
    const capturePolicies = { ...this.settingsStore.value.capturePolicies, [String(appId).toLowerCase()]: policy };
    return this.updateSettings({ capturePolicies });
  }

  async testAI() {
    this.operationMessage = "正在测试 AI 接口…";
    this.emit("changed");
    try {
      await this.aiClient.test(this.settingsStore.aiConfiguration());
      this.operationMessage = "AI 接口连接成功";
      return true;
    } catch (error) {
      this.operationMessage = error.message;
      throw error;
    } finally {
      this.emit("changed");
    }
  }

  async generateDiary(day, { automatic = false } = {}) {
    if (this.generatingDay) throw new Error("已有日记正在生成");
    if (day >= localDayString()) throw new Error("今天的活动日志仍在记录中，需在当天结束后生成");
    if (!this.settingsStore.value.aiDataSharingConfirmed) throw new Error("请先确认脱敏活动摘要的发送目标");
    const segments = this.database.fetchSegments(day);
    if (!segments.length) throw new Error("该日期没有可用于生成日记的活动");

    const existing = this.database.diaryFor(day);
    const configuration = this.settingsStore.aiConfiguration();
    const payload = aggregateDiary(segments, day);
    const renderedPrompt = renderPrompt(this.settingsStore.value.promptTemplate, payload);
    this.generatingDay = day;
    if (!automatic) this.operationMessage = "正在生成日记…";
    this.emit("changed");
    try {
      const content = await this.aiClient.generate(configuration, renderedPrompt, payload);
      this.database.saveDiary({
        day, status: "succeeded", content, model: configuration.model, generatedAt: Date.now()
      });
      this.operationMessage = "日记已生成";
      return this.database.diaryFor(day);
    } catch (error) {
      if (!existing) {
        this.database.saveDiary({
          day, status: "failed", model: configuration.model, errorCode: error.code ?? "unknown"
        });
      }
      this.operationMessage = `日记生成失败：${error.message}`;
      throw error;
    } finally {
      this.generatingDay = null;
      this.emit("changed");
    }
  }

  async checkAutomaticDiary() {
    const settings = this.settingsStore.value;
    if (!settings.autoGenerate || !settings.aiDataSharingConfirmed) return;
    const candidate = this.database.listDaySummaries()
      .find((day) => !day.isToday && day.activeSeconds > 0 &&
        !settings.autoAttemptedDays.includes(day.day) &&
        automaticDiaryDue(day.day, settings.generationHour, settings.generationMinute));
    if (!candidate || this.generatingDay) return;
    const autoAttemptedDays = [...settings.autoAttemptedDays, candidate.day].slice(-120);
    this.settingsStore.update({ autoAttemptedDays });
    try { await this.generateDiary(candidate.day, { automatic: true }); } catch { /* UI shows the non-sensitive error. */ }
  }

  deleteDay(day, kind) {
    if (kind === "activity" || kind === "all") this.database.deleteActivities(day);
    if (kind === "diary" || kind === "all") this.database.deleteDiary(day);
    this.emit("changed");
  }

  resetAll() {
    this.monitor.closeCurrent(Date.now());
    this.database.deleteAll();
    this.settingsStore.reset();
    this.monitor.refreshRedactor();
    this.operationMessage = "所有本地数据与设置已清除";
    this.emit("changed");
  }

  #scheduleRefresh() {
    if (this.refreshTimer) return;
    this.refreshTimer = setTimeout(() => {
      this.refreshTimer = null;
      this.emit("changed");
    }, 1_000);
  }
}
