import { createCipheriv, createDecipheriv, randomBytes } from "node:crypto";

const FORMAT_VERSION = 1;
const IV_BYTES = 12;
const TAG_BYTES = 16;

export class CryptoBox {
  constructor(key) {
    if (!Buffer.isBuffer(key) || key.length !== 32) {
      throw new TypeError("CryptoBox requires a 32-byte key");
    }
    this.key = Buffer.from(key);
  }

  static generateKey() {
    return randomBytes(32);
  }

  seal(value) {
    if (value === null || value === undefined) return null;
    const iv = randomBytes(IV_BYTES);
    const cipher = createCipheriv("aes-256-gcm", this.key, iv);
    const ciphertext = Buffer.concat([cipher.update(String(value), "utf8"), cipher.final()]);
    const tag = cipher.getAuthTag();
    return Buffer.concat([Buffer.from([FORMAT_VERSION]), iv, tag, ciphertext]);
  }

  open(value) {
    if (value === null || value === undefined) return null;
    const input = Buffer.from(value);
    if (input.length < 1 + IV_BYTES + TAG_BYTES || input[0] !== FORMAT_VERSION) {
      throw new Error("加密字段格式无效");
    }
    const iv = input.subarray(1, 1 + IV_BYTES);
    const tag = input.subarray(1 + IV_BYTES, 1 + IV_BYTES + TAG_BYTES);
    const ciphertext = input.subarray(1 + IV_BYTES + TAG_BYTES);
    const decipher = createDecipheriv("aes-256-gcm", this.key, iv);
    decipher.setAuthTag(tag);
    return Buffer.concat([decipher.update(ciphertext), decipher.final()]).toString("utf8");
  }
}
