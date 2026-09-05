import test from "node:test";
import assert from "node:assert/strict";
import { normalizeSettings } from "../src/core/defaults.js";

test("normalizes untrusted settings", () => {
  const settings = normalizeSettings({ idleMinutes: 999, generationHour: -1, retentionDays: 8, maxTokens: "2048" });
  assert.equal(settings.idleMinutes, 30);
  assert.equal(settings.generationHour, 0);
  assert.equal(settings.retentionDays, 30);
  assert.equal(settings.maxTokens, 2048);
});
