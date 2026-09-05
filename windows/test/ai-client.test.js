import test from "node:test";
import assert from "node:assert/strict";
import { endpointFor } from "../src/core/ai-client.js";

test("builds an OpenAI-compatible chat completions endpoint", () => {
  assert.equal(endpointFor("https://api.example.com/v1/").href, "https://api.example.com/v1/chat/completions");
  assert.equal(endpointFor("https://api.example.com/v1/chat/completions").href, "https://api.example.com/v1/chat/completions");
  assert.equal(endpointFor("https://api.example.com/v1/chat/completions/").href, "https://api.example.com/v1/chat/completions");
});

test("allows loopback HTTP and rejects remote HTTP", () => {
  assert.equal(endpointFor("http://127.0.0.1:11434/v1").protocol, "http:");
  assert.throws(() => endpointFor("http://example.com/v1"), /必须使用 HTTPS/u);
  assert.throws(() => endpointFor("https://user:secret@example.com/v1"), /不应包含/u);
});
