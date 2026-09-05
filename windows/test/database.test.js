import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { CryptoBox } from "../src/core/crypto-box.js";
import { MicrocamDatabase } from "../src/main/database.js";

test("database stores private fields as ciphertext", () => {
  const directory = mkdtempSync(path.join(os.tmpdir(), "microcam-db-test-"));
  const file = path.join(directory, "microcam.sqlite");
  const database = new MicrocamDatabase(file, new CryptoBox(Buffer.alloc(32, 3)));
  const startAt = new Date(2026, 7, 8, 10).getTime();
  database.saveSegment(database.createSegment({
    startAt, endAt: startAt + 60_000, appId: "editor.exe", appName: "Editor",
    sanitizedTitle: "private-redacted-title", capturePolicy: "title"
  }));
  database.saveDiary({ day: "2026-08-08", status: "succeeded", content: "private-diary-body", model: "test" });
  assert.equal(database.fetchSegments("2026-08-08")[0].sanitizedTitle, "private-redacted-title");
  assert.equal(database.diaryFor("2026-08-08").content, "private-diary-body");
  database.close();
  const bytes = readFileSync(file);
  assert.equal(bytes.includes(Buffer.from("private-redacted-title")), false);
  assert.equal(bytes.includes(Buffer.from("private-diary-body")), false);
  rmSync(directory, { recursive: true, force: true });
});

test("deleting one day preserves portions of a legacy cross-midnight segment", (context) => {
  const directory = mkdtempSync(path.join(os.tmpdir(), "microcam-delete-test-"));
  const database = new MicrocamDatabase(path.join(directory, "microcam.sqlite"), new CryptoBox(Buffer.alloc(32, 4)));
  context.after(() => {
    database.close();
    rmSync(directory, { recursive: true, force: true, maxRetries: 3, retryDelay: 100 });
  });
  database.saveSegment(database.createSegment({
    startAt: new Date(2026, 7, 7, 23, 50).getTime(),
    endAt: new Date(2026, 7, 9, 0, 10).getTime(),
    appId: "editor.exe",
    appName: "Editor",
    sanitizedTitle: "redacted",
    capturePolicy: "title"
  }));
  database.deleteActivities("2026-08-08");
  assert.equal(database.fetchSegments("2026-08-08").length, 0);
  assert.equal(database.fetchSegments("2026-08-07")[0].endAt, new Date(2026, 7, 8).getTime());
  assert.equal(database.fetchSegments("2026-08-09")[0].startAt, new Date(2026, 7, 9).getTime());
});
