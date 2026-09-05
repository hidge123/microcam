import test from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { ActivityMonitor } from "../src/main/activity-monitor.js";

test("monitor redacts a raw title before handing a segment to persistence", () => {
  const collector = new EventEmitter();
  collector.start = () => {};
  collector.stop = () => {};
  const saved = [];
  let identifier = 0;
  const database = {
    createSegment: (value) => ({ id: String(identifier += 1), ...value }),
    saveSegment: (segment) => saved.push(structuredClone(segment))
  };
  const settingsStore = {
    value: { recordingEnabled: true, idleMinutes: 5, capturePolicies: {} },
    snapshot: () => ({ customSensitiveTerms: [], customPatterns: [] }),
    policyFor: () => null
  };
  const monitor = new ActivityMonitor({ settingsStore, database, collector });
  const start = new Date(2026, 7, 8, 10).getTime();
  collector.emit("snapshot", {
    executable: "editor.exe", appName: "Editor", title: "alice@example.com — notes", idleSeconds: 0, capturedAt: start
  });
  collector.emit("snapshot", {
    executable: "browser.exe", appName: "Browser", title: "Home", idleSeconds: 0, capturedAt: start + 5_000
  });
  assert.equal(saved.length, 1);
  assert.equal(saved[0].sanitizedTitle, "[邮箱] — notes");
  assert.equal(JSON.stringify(saved).includes("alice@example.com"), false);
});

test("monitor closes activity at the configured idle boundary", () => {
  const collector = new EventEmitter();
  collector.start = () => {};
  collector.stop = () => {};
  const saved = [];
  const database = {
    createSegment: (value) => ({ id: "segment", ...value }),
    saveSegment: (segment) => saved.push(structuredClone(segment))
  };
  const settingsStore = {
    value: { recordingEnabled: true, idleMinutes: 1, capturePolicies: {} },
    snapshot: () => ({ customSensitiveTerms: [], customPatterns: [] }),
    policyFor: () => "durationOnly"
  };
  const monitor = new ActivityMonitor({ settingsStore, database, collector });
  const start = new Date(2026, 7, 8, 10).getTime();
  collector.emit("snapshot", { executable: "editor.exe", appName: "Editor", title: "", idleSeconds: 0, capturedAt: start });
  collector.emit("snapshot", { executable: "editor.exe", appName: "Editor", title: "", idleSeconds: 70, capturedAt: start + 70_000 });
  assert.equal(saved[0].endAt, start + 60_000);
  assert.equal(monitor.snapshot().state, "idle");
});
