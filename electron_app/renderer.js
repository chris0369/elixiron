const connectButton = document.getElementById('connectWs');
const disconnectButton = document.getElementById('disconnectWs');
const sendMessageButton = document.getElementById('sendMessage');
const refreshFileListButton = document.getElementById('refreshFileList');
const messageList = document.getElementById('messageList');
const fileListElement = document.getElementById('fileList');
const statusIndicator = document.getElementById('statusIndicator');

let ws = null;

function updateStatus(message, type) {
    statusIndicator.textContent = message;
    statusIndicator.className = 'status-indicator';
    if (type === 'connected') {
        statusIndicator.classList.add('status-connected');
    } else if (type === 'disconnected') {
        statusIndicator.classList.add('status-disconnected');
    } else if (type === 'error') {
        statusIndicator.classList.add('status-error');
    }
}

function addMessageToList(message, sender) {
    const listItem = document.createElement('li');
    listItem.textContent = message;
    listItem.classList.add(sender === 'client' ? 'client-msg' : 'server-msg');
    if (sender === 'error') {
        listItem.classList.add('error-msg');
    }
    messageList.appendChild(listItem);
    messageList.scrollTop = messageList.scrollHeight;
}

function updateFileList(files) {
    fileListElement.innerHTML = '';
    if (files && files.length > 0) {
        files.forEach(file => {
            const listItem = document.createElement('li');
            listItem.textContent = file;
            fileListElement.appendChild(listItem);
        });
    } else {
        const listItem = document.createElement('li');
        listItem.textContent = 'No files found or directory is empty.';
        fileListElement.appendChild(listItem);
    }
}

function connectWebSocket() {
    if (ws && (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING)) {
        addMessageToList('Already connected or connecting.', 'client');
        return;
    }

    ws = new WebSocket('ws://localhost:4001/ws');
    updateStatus('Connecting...', 'neutral');
    addMessageToList('Attempting to connect to ws://localhost:4001/ws', 'client');

    ws.onopen = () => {
        updateStatus('Connected', 'connected');
        addMessageToList('WebSocket connection opened.', 'server');
    };

    ws.onmessage = (event) => {
        addMessageToList(`Server: ${event.data}`, 'server');
        try {
            const parsedMessage = JSON.parse(event.data);
            if (parsedMessage.type === 'connection_ack') {
                console.log('Connection Acknowledged:', parsedMessage.payload);
            } else if (parsedMessage.type === 'echo_response') {
                console.log('Echo from server:', parsedMessage.payload);
            } else if (parsedMessage.type === 'file_list_response') {
                console.log('Files from server:', parsedMessage.path, parsedMessage.files);
                updateFileList(parsedMessage.files);
            } else if (parsedMessage.type === 'file_list_error') {
                console.error('Error listing files:', parsedMessage.error);
                addMessageToList(`Error listing files on path '${parsedMessage.path}': ${parsedMessage.error}`, 'error');
                updateFileList([]);
            }
        } catch (e) {
            console.warn('Received non-JSON message or failed to parse. Original message:', event.data, 'Error:', e);
            addMessageToList(`Error processing message from server: ${e.message}. Raw data: ${event.data}`, 'error');
        }
    };

    ws.onerror = (error) => {
        updateStatus('Connection Error', 'error');
        addMessageToList(`WebSocket error: ${error.message || 'Unknown error'}`, 'error');
        console.error('WebSocket error:', error);
    };

    ws.onclose = (event) => {
        updateStatus('Disconnected', 'disconnected');
        addMessageToList(`WebSocket connection closed. Code: ${event.code}, Reason: ${event.reason || 'No reason given'}`, 'server');
        ws = null;
    };
}

function disconnectWebSocket() {
    if (ws) {
        ws.close();
        addMessageToList('Disconnecting...', 'client');
    } else {
        addMessageToList('Not connected.', 'client');
    }
}

function sendSampleMessage() {
    if (ws && ws.readyState === WebSocket.OPEN) {
        const message = { action: "echo_json", content: "Hello from Electron!", timestamp: new Date().toISOString() };
        const jsonMessage = JSON.stringify(message);
        ws.send(jsonMessage);
        addMessageToList(`Client: ${jsonMessage}`, 'client');
    } else {
        addMessageToList('WebSocket is not connected. Cannot send message.', 'error');
    }
}

function requestFileList(path = '.') {
    if (ws && ws.readyState === WebSocket.OPEN) {
        const message = { action: "list_files", path: path };
        const jsonMessage = JSON.stringify(message);
        ws.send(jsonMessage);
        addMessageToList(`Client: Requesting file list for path: '${path}'`, 'client');
        fileListElement.innerHTML = '<li>Loading file list...</li>';
    } else {
        addMessageToList('WebSocket is not connected. Cannot request file list.', 'error');
        fileListElement.innerHTML = '<li>WebSocket not connected.</li>';
    }
}

connectButton.addEventListener('click', connectWebSocket);
disconnectButton.addEventListener('click', disconnectWebSocket);
sendMessageButton.addEventListener('click', sendSampleMessage);
refreshFileListButton.addEventListener('click', () => requestFileList('.'));

updateStatus('Disconnected', 'disconnected');

console.log('Renderer script (renderer.js) loaded and initialized [Simplified].'); 