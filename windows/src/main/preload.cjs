const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("microcam", Object.freeze({
  getState: () => ipcRenderer.invoke("microcam:get-state"),
  updateSettings: (patch) => ipcRenderer.invoke("microcam:update-settings", patch),
  setPolicy: (appId, policy) => ipcRenderer.invoke("microcam:set-policy", { appId, policy }),
  pause: (minutes) => ipcRenderer.invoke("microcam:pause", minutes),
  resume: () => ipcRenderer.invoke("microcam:resume"),
  testAI: () => ipcRenderer.invoke("microcam:test-ai"),
  generateDiary: (day) => ipcRenderer.invoke("microcam:generate-diary", day),
  exportDiary: (day) => ipcRenderer.invoke("microcam:export-diary", day),
  deleteDay: (day, kind) => ipcRenderer.invoke("microcam:delete-day", { day, kind }),
  resetAll: () => ipcRenderer.invoke("microcam:reset-all"),
  onStateChanged: (callback) => {
    const listener = () => callback();
    ipcRenderer.on("microcam:state-changed", listener);
    return () => ipcRenderer.removeListener("microcam:state-changed", listener);
  }
}));
