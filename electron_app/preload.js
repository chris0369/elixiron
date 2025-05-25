const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('electronAPI', {
  connectWebsocket: () => ipcRenderer.invoke('connect-websocket'),
  sendWsMessage: (message) => ipcRenderer.invoke('send-ws-message', message),
  
  // Listeners for messages from main process
  onWsMessage: (callback) => ipcRenderer.on('ws-message', (_event, value) => callback(value)),
  onWsStatus: (callback) => ipcRenderer.on('ws-status', (_event, value) => callback(value)),

  // It's good practice to provide a way to remove listeners
  removeAllWsMessageListeners: () => ipcRenderer.removeAllListeners('ws-message'),
  removeAllWsStatusListeners: () => ipcRenderer.removeAllListeners('ws-status'),
});

console.log('Preload script (preload.js) loaded [Simplified].'); 