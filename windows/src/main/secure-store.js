import { chmodSync, existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import path from "node:path";

export class SecureStore {
  constructor(filePath, protector) {
    this.filePath = filePath;
    this.protector = protector;
    this.values = this.#read();
  }

  get(name) {
    const encoded = this.values[name];
    if (!encoded) return null;
    try {
      return this.protector.decryptString(Buffer.from(encoded, "base64"));
    } catch {
      throw new Error(`无法解密安全存储项：${name}`);
    }
  }

  set(name, value) {
    if (value === null || value === undefined || value === "") {
      delete this.values[name];
    } else {
      this.values[name] = this.protector.encryptString(String(value)).toString("base64");
    }
    this.#write();
  }

  deleteAll() {
    this.values = {};
    this.#write();
  }

  #read() {
    if (!existsSync(this.filePath)) return {};
    try {
      const parsed = JSON.parse(readFileSync(this.filePath, "utf8"));
      return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {};
    } catch {
      throw new Error("安全存储文件已损坏");
    }
  }

  #write() {
    mkdirSync(path.dirname(this.filePath), { recursive: true });
    const temporaryPath = `${this.filePath}.tmp`;
    writeFileSync(temporaryPath, `${JSON.stringify(this.values, null, 2)}\n`, { mode: 0o600 });
    renameSync(temporaryPath, this.filePath);
    try { chmodSync(this.filePath, 0o600); } catch { /* Windows ACLs are managed by the OS. */ }
  }
}
