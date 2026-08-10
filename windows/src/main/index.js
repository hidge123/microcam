import { app, BrowserWindow, dialog, ipcMain, Menu, nativeImage, powerMonitor, safeStorage, Tray } from "electron";
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { CryptoBox } from "../core/crypto-box.js";
import { SecureStore } from "./secure-store.js";
import { SettingsStore } from "./settings-store.js";
import { MicrocamDatabase } from "./database.js";
import { WindowsCollector } from "./windows-collector.js";
import { ActivityMonitor } from "./activity-monitor.js";
import { AppController } from "./app-controller.js";

const moduleDirectory = path.dirname(fileURLToPath(import.meta.url));
let mainWindow = null;
let tray = null;
let controller = null;
let quitting = false;

if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on("second-instance", () => showMainWindow());
  app.whenReady().then(startApplication).catch((error) => {
    dialog.showErrorBox("Microcam 无法启动", error.message);
    app.quit();
  });
}

app.on("window-all-closed", () => {
  // Microcam remains active in the notification area.
});

app.on("before-quit", () => {
  quitting = true;
  controller?.stop();
});

async function startApplication() {
  app.setAppUserModelId("com.hidge123.microcam");
  if (!safeStorage.isEncryptionAvailable()) {
    throw new Error("Windows DPAPI 当前不可用，Microcam 不会在缺少系统密钥保护时保存隐私数据");
  }

  const dataDirectory = app.getPath("userData");
  mkdirSync(dataDirectory, { recursive: true });
  const secureStore = new SecureStore(path.join(dataDirectory, "secure-store.json"), safeStorage);
  let databaseKey = secureStore.get("database-key");
  if (!databaseKey) {
    databaseKey = CryptoBox.generateKey().toString("base64");
    secureStore.set("database-key", databaseKey);
  }
  const cryptoBox = new CryptoBox(Buffer.from(databaseKey, "base64"));
  const settingsStore = new SettingsStore(path.join(dataDirectory, "settings.json"), secureStore);
  const database = new MicrocamDatabase(path.join(dataDirectory, "microcam.sqlite"), cryptoBox);
  const monitorScript = app.isPackaged
    ? path.join(process.resourcesPath, "platform", "win32-monitor.ps1")
    : path.join(moduleDirectory, "..", "platform", "win32-monitor.ps1");
  const collector = new WindowsCollector(monitorScript);
  const monitor = new ActivityMonitor({ settingsStore, database, collector });
  controller = new AppController({ settingsStore, database, monitor });
  controller.on("changed", broadcastState);

  createWindow();
  createTray();
  registerIPC();
  registerPowerEvents(monitor);
  applyLoginItemSettings(settingsStore.value.launchAtLogin);
  controller.start();
  if (!process.argv.includes("--hidden") || !settingsStore.value.onboardingComplete) showMainWindow();
}

function createWindow() {
  mainWindow = new BrowserWindow({
    title: "Microcam",
    width: 1080,
    height: 720,
    minWidth: 860,
    minHeight: 600,
    show: false,
    autoHideMenuBar: true,
    backgroundColor: "#f4f1ea",
    icon: iconPath(),
    webPreferences: {
      preload: path.join(moduleDirectory, "preload.cjs"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true
    }
  });
  mainWindow.loadFile(path.join(moduleDirectory, "..", "renderer", "index.html"));
  mainWindow.on("close", (event) => {
    if (!quitting) {
      event.preventDefault();
      mainWindow.hide();
    }
  });
}

function createTray() {
  const image = nativeImage.createFromPath(iconPath()).resize({ width: 20, height: 20 });
  tray = new Tray(image);
  tray.setToolTip("Microcam");
  tray.on("double-click", showMainWindow);
  updateTrayMenu();
}

function updateTrayMenu() {
  if (!tray || !controller) return;
  const monitor = controller.monitor.snapshot();
  const paused = monitor.state === "paused";
  const label = statusLabel(monitor);
  tray.setContextMenu(Menu.buildFromTemplate([
    { label, enabled: false },
    { type: "separator" },
    { label: "打开 Microcam", click: showMainWindow },
    paused
      ? { label: "恢复记录", click: () => controller.monitor.resume() }
      : {
          label: "暂停记录",
          submenu: [
            { label: "15 分钟", click: () => controller.monitor.pause(15) },
            { label: "1 小时", click: () => controller.monitor.pause(60) },
            { label: "直到手动恢复", click: () => controller.monitor.pause(null) }
          ]
        },
    { type: "separator" },
    { label: "退出 Microcam", click: () => app.quit() }
  ]));
}

function registerIPC() {
  ipcMain.handle("microcam:get-state", () => controller.state());
  ipcMain.handle("microcam:update-settings", (_event, patch) => {
    const settings = controller.updateSettings(patch);
    applyLoginItemSettings(settings.launchAtLogin);
    return settings;
  });
  ipcMain.handle("microcam:set-policy", (_event, { appId, policy }) => controller.setCapturePolicy(appId, policy));
  ipcMain.handle("microcam:pause", (_event, minutes) => controller.monitor.pause(minutes));
  ipcMain.handle("microcam:resume", () => controller.monitor.resume());
  ipcMain.handle("microcam:test-ai", () => controller.testAI());
  ipcMain.handle("microcam:generate-diary", (_event, day) => controller.generateDiary(day));
  ipcMain.handle("microcam:delete-day", (_event, { day, kind }) => controller.deleteDay(day, kind));
  ipcMain.handle("microcam:reset-all", () => {
    controller.resetAll();
    applyLoginItemSettings(false);
  });
  ipcMain.handle("microcam:export-diary", async (_event, day) => {
    const diary = controller.database.diaryFor(day);
    if (!diary?.content) throw new Error("没有可导出的日记");
    const result = await dialog.showSaveDialog(mainWindow, {
      title: "导出日记",
      defaultPath: `Microcam-${day}.md`,
      filters: [{ name: "Markdown", extensions: ["md"] }]
    });
    if (result.canceled || !result.filePath) return false;
    writeFileSync(result.filePath, diary.content, "utf8");
    return true;
  });
}

function registerPowerEvents(monitor) {
  for (const event of ["suspend", "lock-screen", "shutdown"]) {
    powerMonitor.on(event, () => monitor.suspend());
  }
  for (const event of ["resume", "unlock-screen"]) {
    powerMonitor.on(event, () => monitor.resumeFromSuspend());
  }
}

function broadcastState() {
  updateTrayMenu();
  if (mainWindow && !mainWindow.isDestroyed()) mainWindow.webContents.send("microcam:state-changed");
}

function showMainWindow() {
  if (!mainWindow) return;
  mainWindow.show();
  mainWindow.focus();
}

function iconPath() {
  return app.isPackaged
    ? path.join(process.resourcesPath, "assets", "icon.png")
    : path.join(moduleDirectory, "..", "..", "..", "Microcam", "Assets.xcassets", "AppIcon.appiconset", "appicon-256.png");
}

function applyLoginItemSettings(openAtLogin) {
  app.setLoginItemSettings({
    openAtLogin,
    path: process.execPath,
    args: ["--hidden"]
  });
}

function statusLabel(monitor) {
  switch (monitor.state) {
    case "recording": return monitor.currentApp ? `正在记录：${monitor.currentApp}` : "正在记录";
    case "paused": return "已暂停";
    case "idle": return "空闲中";
    case "excluded": return "当前应用已排除";
    case "platform-unsupported": return "采集仅在 Windows 上运行";
    case "error": return monitor.error ?? "记录异常";
    default: return "记录已停止";
  }
}
