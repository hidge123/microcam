import test from "node:test";
import assert from "node:assert/strict";
import { Redactor, validateCustomPatterns } from "../src/core/redactor.js";

test("redacts Windows paths and common private values", () => {
  const redactor = new Redactor({ username: "alice" });
  const result = redactor.redact("alice opened C:\\Users\\alice\\Secret\\plan.docx for alice@example.com at https://example.com/private");
  assert.equal(result, "[用户名] opened [文件路径] for [邮箱] at [网址]");
});

test("applies custom terms before persistence", () => {
  const redactor = new Redactor({ customTerms: ["Project Falcon"], customPatterns: ["CASE-[0-9]+"] });
  assert.equal(redactor.redact("Project Falcon CASE-123"), "[自定义敏感词] [自定义隐藏]");
});

test("reports invalid custom patterns", () => {
  assert.equal(validateCustomPatterns(["("]).length, 1);
});
