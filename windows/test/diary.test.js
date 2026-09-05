import test from "node:test";
import assert from "node:assert/strict";
import { aggregateDiary, automaticDiaryDue, renderPrompt } from "../src/core/diary.js";
import { localDayString } from "../src/core/time.js";

test("aggregates a segment across local hour boundaries", () => {
  const start = new Date(2026, 7, 8, 9, 45).getTime();
  const end = new Date(2026, 7, 8, 10, 15).getTime();
  const payload = aggregateDiary([{
    startAt: start, endAt: end, appName: "Editor", sanitizedTitle: "[文件路径]", appId: "editor.exe"
  }], "2026-08-08");
  assert.equal(payload.activeMinutes, 30);
  assert.deepEqual(payload.activities.map((row) => [row.hour, row.minutes]), [["09:00", 15], ["10:00", 15]]);
});

test("renders supported prompt variables and rejects unknown ones", () => {
  const payload = { date: "2026-08-08", activeMinutes: 60, applicationBreakdown: { Editor: 60 }, activities: [] };
  assert.match(renderPrompt("{{date}} {{activity_summary}}", payload), /2026-08-08 无活动/u);
  assert.throws(() => renderPrompt("{{unknown}} {{activity_summary}}", payload), /不支持/u);
});

test("automatic schedule starts on the following day", () => {
  const day = localDayString(new Date(2026, 7, 8, 12));
  assert.equal(automaticDiaryDue(day, 0, 5, new Date(2026, 7, 9, 0, 4)), false);
  assert.equal(automaticDiaryDue(day, 0, 5, new Date(2026, 7, 9, 0, 5)), true);
});
