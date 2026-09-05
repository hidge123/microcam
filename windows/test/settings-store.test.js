import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { SecureStore } from "../src/main/secure-store.js";
import { SettingsStore } from "../src/main/settings-store.js";

const protector = {
  encryptString(value) {
    return Buffer.from(value, "utf8").map((byte) => byte ^ 0xa5);
  },
  decryptString(value) {
    return Buffer.from(value).map((byte) => byte ^ 0xa5).toString("utf8");
  }
};

test("sensitive settings are kept out of the plaintext settings file", (context) => {
  const directory = mkdtempSync(path.join(os.tmpdir(), "microcam-settings-test-"));
  context.after(() => rmSync(directory, { recursive: true, force: true }));
  const securePath = path.join(directory, "secure.json");
  const settingsPath = path.join(directory, "settings.json");
  const secureStore = new SecureStore(securePath, protector);
  const settings = new SettingsStore(settingsPath, secureStore);

  settings.update({
    apiKey: "secret-api-key",
    customSensitiveTerms: "Project Falcon",
    customPatterns: "CASE-[0-9]+"
  });

  assert.equal(settings.snapshot().apiKeyConfigured, true);
  assert.deepEqual(settings.snapshot().customSensitiveTerms, ["Project Falcon"]);
  assert.equal(readFileSync(settingsPath, "utf8").includes("secret-api-key"), false);
  assert.equal(readFileSync(settingsPath, "utf8").includes("Project Falcon"), false);
  assert.equal(readFileSync(securePath, "utf8").includes("secret-api-key"), false);
  assert.equal(readFileSync(securePath, "utf8").includes("Project Falcon"), false);
});

test("validation failure does not partially update the API key", (context) => {
  const directory = mkdtempSync(path.join(os.tmpdir(), "microcam-settings-atomic-test-"));
  context.after(() => rmSync(directory, { recursive: true, force: true }));
  const secureStore = new SecureStore(path.join(directory, "secure.json"), protector);
  const settings = new SettingsStore(path.join(directory, "settings.json"), secureStore);
  settings.update({ apiKey: "original-key" });

  assert.throws(
    () => settings.update({ apiKey: "replacement-key", customPatterns: "(" }),
    /正则/u
  );
  assert.equal(settings.aiConfiguration().apiKey, "original-key");
});

test("changing the AI destination invalidates prior sharing confirmation", (context) => {
  const directory = mkdtempSync(path.join(os.tmpdir(), "microcam-settings-endpoint-test-"));
  context.after(() => rmSync(directory, { recursive: true, force: true }));
  const secureStore = new SecureStore(path.join(directory, "secure.json"), protector);
  const settings = new SettingsStore(path.join(directory, "settings.json"), secureStore);
  settings.update({ aiDataSharingConfirmed: true });
  assert.equal(settings.value.aiDataSharingConfirmed, true);
  settings.update({ aiBaseURL: "https://example.com/v1", aiDataSharingConfirmed: true });
  assert.equal(settings.value.aiDataSharingConfirmed, false);
});
