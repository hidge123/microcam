import { EventEmitter } from "node:events";
import { spawn } from "node:child_process";
import readline from "node:readline";

export class WindowsCollector extends EventEmitter {
  constructor(scriptPath) {
    super();
    this.scriptPath = scriptPath;
    this.child = null;
    this.stopping = false;
  }

  start() {
    if (this.child) return;
    if (process.platform !== "win32") {
      queueMicrotask(() => this.emit("unsupported"));
      return;
    }
    this.stopping = false;
    this.child = spawn("powershell.exe", [
      "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", this.scriptPath
    ], { windowsHide: true, stdio: ["ignore", "pipe", "pipe"] });

    const lines = readline.createInterface({ input: this.child.stdout, crlfDelay: Infinity });
    lines.on("line", (line) => {
      try {
        const snapshot = JSON.parse(line);
        if (snapshot && typeof snapshot === "object") this.emit("snapshot", snapshot);
      } catch {
        this.emit("error", new Error("Windows 活动采集器返回了无效数据"));
      }
    });
    this.child.stderr.resume();
    this.child.once("error", () => this.emit("error", new Error("无法启动 Windows 活动采集器")));
    this.child.once("exit", () => {
      this.child = null;
      lines.close();
      if (!this.stopping) this.emit("error", new Error("Windows 活动采集器意外停止"));
    });
  }

  stop() {
    this.stopping = true;
    this.child?.kill();
    this.child = null;
  }
}
