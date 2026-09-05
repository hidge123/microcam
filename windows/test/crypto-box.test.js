import test from "node:test";
import assert from "node:assert/strict";
import { CryptoBox } from "../src/core/crypto-box.js";

test("AES-GCM round trips without storing plaintext", () => {
  const box = new CryptoBox(Buffer.alloc(32, 7));
  const sealed = box.seal("private window title");
  assert.equal(sealed.includes(Buffer.from("private window title")), false);
  assert.equal(box.open(sealed), "private window title");
});

test("AES-GCM rejects tampered ciphertext", () => {
  const box = new CryptoBox(Buffer.alloc(32, 9));
  const sealed = box.seal("diary");
  sealed[sealed.length - 1] ^= 1;
  assert.throws(() => box.open(sealed));
});
