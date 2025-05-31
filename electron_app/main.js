const { app, BrowserWindow, ipcMain } = require('electron');
const path = require('node:path');
const WebSocket = require('ws');

let mainWindow;
let wsClient;
const ELIXIR_WS_URL = 'ws://127.0.0.1:4001/ws'; // Simplified URL

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 800,
    height: 600,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      enableRemoteModule: false,
    },
  });

  mainWindow.loadFile('index.html');


  mainWindow.on('closed', () => {
    mainWindow = null;
  });
}

// Simplified connectWebSocket - no channelId
function connectWebSocket() {
  if (wsClient && (wsClient.readyState === WebSocket.OPEN || wsClient.readyState === WebSocket.CONNECTING)) {
    console.log('MAIN: Closing existing WebSocket connection before reconnecting.');
    wsClient.close();
  }
  
  console.log(`MAIN: Attempting to connect to WebSocket: ${ELIXIR_WS_URL}`);
  wsClient = new WebSocket(ELIXIR_WS_URL);

  wsClient.onopen = () => {
    console.log(`MAIN: WebSocket connected to ${ELIXIR_WS_URL}`);
    if (mainWindow && !mainWindow.isDestroyed()) {
      mainWindow.webContents.send('ws-status', { status: 'connected' });
    }
  };

  wsClient.onmessage = (event) => {
    const rawData = event.data.toString();
    console.log(`MAIN_WS_ONMESSAGE: Raw data received:`, rawData);
    try {
      const message = JSON.parse(rawData);
      if (mainWindow && !mainWindow.isDestroyed()) {
        mainWindow.webContents.send('ws-message', message); 
      }
    } catch (error) {
      console.error('MAIN_WS_ONMESSAGE: Error parsing WebSocket message as JSON:', error);
      console.error('MAIN_WS_ONMESSAGE: Raw message was:', rawData);
      if (mainWindow && !mainWindow.isDestroyed()) {
        mainWindow.webContents.send('ws-message', { type: 'raw_error', payload: rawData, error: error.message });
      }
    }
  };

  wsClient.onerror = (error) => {
    console.error(`MAIN: WebSocket error:`, error.message);
    if (mainWindow && !mainWindow.isDestroyed()) {
      mainWindow.webContents.send('ws-status', { status: 'error', message: error.message });
    }
  };

  wsClient.onclose = (event) => {
    console.log(`MAIN: WebSocket disconnected. Code: ${event.code}, Reason: ${event.reason}`);
    if (mainWindow && !mainWindow.isDestroyed()) {
      mainWindow.webContents.send('ws-status', { status: 'disconnected', code: event.code, reason: event.reason });
    }
  };
}

app.whenReady().then(() => {
  createWindow();
  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) {
      createWindow();
    }
  });
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') {
    app.quit();
  }
  if (wsClient) {
    console.log('MAIN: Closing WebSocket connection on window-all-closed.');
    wsClient.close();
  }
});

// Renamed IPC handler for connecting - no channelId
ipcMain.handle('connect-websocket', () => { 
  console.log('IPC: connect-websocket received');
  try {
    connectWebSocket();
    return { success: true };
  } catch (error) {
    console.error('IPC: Failed to initiate WebSocket connection:', error);
    return { success: false, error: error.message };
  }
});

ipcMain.handle('send-ws-message', (_event, messageText) => {
  if (wsClient && wsClient.readyState === WebSocket.OPEN) {
    console.log('IPC: send-ws-message:', messageText);
    wsClient.send(messageText);
    return { success: true };
  } else {
    console.error('IPC: WebSocket not open. Cannot send message.');
    return { success: false, error: 'WebSocket connection is not open.' };
  }
});

// Removed rename-channel IPC handler

console.log('Main process (main.js) loaded [Simplified].'); 