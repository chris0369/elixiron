// VSCode-like File Manager Renderer
let ws = null;
let fileTree = null;
let openTabs = [];
let activeTabId = null;
let contextMenu = null;

// DOM Elements
const elements = {
  // Connection
  statusDot: document.getElementById('statusDot'),
  statusText: document.getElementById('statusText'),
  connectBtn: document.getElementById('connectBtn'),

  // File Explorer
  fileTree: document.getElementById('fileTree'),
  refreshTreeBtn: document.getElementById('refreshTreeBtn'),
  collapseAllBtn: document.getElementById('collapseAllBtn'),

  // Editor
  editorTabs: document.getElementById('editorTabs'),
  editorContent: document.getElementById('editorContent'),
  editorWelcome: document.getElementById('editorWelcome'),
  editorStatus: document.getElementById('editorStatus'),
  statusLeft: document.getElementById('statusLeft'),
  statusRight: document.getElementById('statusRight'),

  // Messages
  messagesContent: document.getElementById('messagesContent'),
  clearMessagesBtn: document.getElementById('clearMessagesBtn'),

  // Context Menu
  contextMenu: document.getElementById('contextMenu')
};

// WebSocket Connection Management
function connectWebSocket() {
  if (ws && (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING)) {
    addMessage('Already connected or connecting', 'info');
    return;
  }

  ws = new WebSocket('ws://localhost:4001/ws');
  updateConnectionStatus('connecting');
  addMessage('Connecting to ws://localhost:4001/ws...', 'info');

  ws.onopen = () => {
    updateConnectionStatus('connected');
    addMessage('WebSocket connection established', 'success');
    loadInitialFileTree();
  };

  ws.onmessage = (event) => {
    try {
      const response = JSON.parse(event.data);
      handleServerResponse(response);
    } catch (error) {
      addMessage(`Error parsing server response: ${error.message}`, 'error');
    }
  };

  ws.onerror = (error) => {
    updateConnectionStatus('error');
    addMessage(`Connection error: ${error.message || 'Unknown error'}`, 'error');
  };

  ws.onclose = (event) => {
    updateConnectionStatus('disconnected');
    addMessage(`Connection closed: ${event.code} - ${event.reason || 'No reason'}`, 'info');
    ws = null;
  };
}

function disconnectWebSocket() {
  if (ws) {
    ws.close();
    addMessage('Disconnecting...', 'info');
  }
}

function updateConnectionStatus(status) {
  const dot = elements.statusDot;
  const text = elements.statusText;
  const btn = elements.connectBtn;

  dot.className = 'status-dot';
  
  switch (status) {
    case 'connected':
      dot.classList.add('connected');
      text.textContent = 'Connected';
      btn.textContent = 'Disconnect';
      btn.onclick = disconnectWebSocket;
      btn.disabled = false;
      break;
    case 'connecting':
      text.textContent = 'Connecting...';
      btn.disabled = true;
      break;
    case 'disconnected':
      text.textContent = 'Disconnected';
      btn.textContent = 'Connect';
      btn.onclick = connectWebSocket;
      btn.disabled = false;
      break;
    case 'error':
      text.textContent = 'Error';
      btn.textContent = 'Reconnect';
      btn.onclick = connectWebSocket;
      btn.disabled = false;
      break;
  }
}

// WebSocket Message Handling
function sendWebSocketMessage(message) {
  if (ws && ws.readyState === WebSocket.OPEN) {
    const jsonMessage = JSON.stringify(message);
    ws.send(jsonMessage);
    return true;
  } else {
    addMessage('Not connected to server', 'error');
    return false;
  }
}

function handleServerResponse(response) {
  switch (response.type) {
    case 'directory_tree_response':
      handleDirectoryTreeResponse(response);
      break;
    case 'file_list_response':
      handleFileListResponse(response);
      break;
    case 'file_read_response':
      handleFileReadResponse(response);
      break;
    case 'file_create_response':
    case 'file_update_response':
      handleFileUpdateResponse(response);
      break;
    case 'file_delete_response':
      handleFileDeleteResponse(response);
      break;
    case 'directory_create_response':
      handleDirectoryCreateResponse(response);
      break;
    case 'directory_delete_response':
      handleDirectoryDeleteResponse(response);
      break;
    case 'error_response':
      handleErrorResponse(response);
      break;
    case 'connection_established':
      addMessage('Server connection established', 'success');
      break;
    default:
      addMessage(`Unknown response type: ${response.type}`, 'warning');
      console.log('Unknown response:', response);
  }
}

function handleDirectoryTreeResponse(response) {
  if (response.success) {
    fileTree = response.tree;
    renderFileTree();
    addMessage('File tree loaded successfully', 'success');
  } else {
    addMessage(`Failed to load file tree: ${response.error}`, 'error');
  }
}

function handleFileListResponse(response) {
  if (response.success) {
    // Handle file list updates (for directory expansion)
    addMessage(`Directory listing updated: ${response.path}`, 'info');
  } else {
    addMessage(`Failed to list directory: ${response.error}`, 'error');
  }
}

function handleFileReadResponse(response) {
  if (response.success) {
    const filePath = response.path || 'unknown';
    openFileInEditor(filePath, response.content);
    addMessage(`File opened: ${filePath}`, 'success');
  } else {
    addMessage(`Failed to read file: ${response.error}`, 'error');
  }
}

function handleFileUpdateResponse(response) {
  if (response.success) {
    addMessage(`File saved: ${response.path}`, 'success');
    // Mark tab as saved
    const tab = findTabByPath(response.path);
    if (tab) {
      tab.isDirty = false;
      updateTabVisual(tab);
    }
    // Refresh file tree to show any new files
    loadInitialFileTree();
  } else {
    addMessage(`Failed to save file: ${response.error}`, 'error');
  }
}

function handleFileDeleteResponse(response) {
  if (response.success) {
    addMessage(`File deleted: ${response.path}`, 'success');
    // Close tab if file was open
    const tab = findTabByPath(response.path);
    if (tab) {
      closeTab(tab.id);
    }
    // Refresh file tree
    loadInitialFileTree();
  } else {
    addMessage(`Failed to delete file: ${response.error}`, 'error');
  }
}

function handleDirectoryCreateResponse(response) {
  if (response.success) {
    addMessage(`Directory created: ${response.path}`, 'success');
    loadInitialFileTree();
  } else {
    addMessage(`Failed to create directory: ${response.error}`, 'error');
  }
}

function handleDirectoryDeleteResponse(response) {
  if (response.success) {
    addMessage(`Directory deleted: ${response.path}`, 'success');
    loadInitialFileTree();
  } else {
    addMessage(`Failed to delete directory: ${response.error}`, 'error');
  }
}

function handleErrorResponse(response) {
  addMessage(`Server error: ${response.message || response.error}`, 'error');
}

// File Tree Management
function loadInitialFileTree() {
  if (!ws || ws.readyState !== WebSocket.OPEN) {
    addMessage('Not connected - cannot load file tree', 'error');
    return;
  }

  // Don't specify a path - let the server use its configured base path
  sendWebSocketMessage({
    action: 'get_directory_tree',
    max_depth: 3
  });
}

function renderFileTree() {
  if (!fileTree) {
    elements.fileTree.innerHTML = '<div style="padding: 12px; color: var(--text-secondary);">No files to display</div>';
    return;
  }

  elements.fileTree.innerHTML = '';
  renderTreeNode(fileTree, elements.fileTree, 0);
}

function renderTreeNode(node, container, depth) {
  const item = document.createElement('div');
  item.className = `tree-item ${node.type}`;
  item.style.paddingLeft = `${12 + depth * 16}px`;
  
  // Expand/collapse button
  const expandBtn = document.createElement('div');
  expandBtn.className = 'tree-expand';
  if (node.type === 'directory' && node.children && node.children.length > 0) {
    expandBtn.classList.add('expanded');
    expandBtn.onclick = (e) => {
      e.stopPropagation();
      toggleTreeNode(item, node);
    };
  } else {
    expandBtn.classList.add('empty');
  }

  // Icon
  const icon = document.createElement('div');
  icon.className = `tree-icon ${node.type}`;
  icon.textContent = node.type === 'directory' ? '📁' : '📄';

  // Name
  const name = document.createElement('span');
  name.textContent = node.name;

  item.appendChild(expandBtn);
  item.appendChild(icon);
  item.appendChild(name);

  // Event handlers
  item.onclick = () => handleTreeItemClick(node);
  item.oncontextmenu = (e) => handleTreeItemRightClick(e, node);

  container.appendChild(item);

  // Render children
  if (node.type === 'directory' && node.children && node.children.length > 0) {
    const childrenContainer = document.createElement('div');
    childrenContainer.className = 'tree-children';
    
    node.children.forEach(child => {
      renderTreeNode(child, childrenContainer, depth + 1);
    });

    container.appendChild(childrenContainer);
  }
}

function toggleTreeNode(itemElement, node) {
  const expandBtn = itemElement.querySelector('.tree-expand');
  const childrenContainer = itemElement.nextElementSibling;

  if (expandBtn.classList.contains('expanded')) {
    expandBtn.classList.remove('expanded');
    if (childrenContainer) {
      childrenContainer.classList.add('collapsed');
    }
  } else {
    expandBtn.classList.add('expanded');
    if (childrenContainer) {
      childrenContainer.classList.remove('collapsed');
    }
  }
}

function handleTreeItemClick(node) {
  if (node.type === 'file') {
    // Open file
    requestFileContent(node.path);
  } else if (node.type === 'directory') {
    // Directory click - could expand/collapse or navigate
    // For now, let's just log it
    addMessage(`Directory selected: ${node.path}`, 'info');
  }
}

function handleTreeItemRightClick(event, node) {
  event.preventDefault();
  showContextMenu(event.clientX, event.clientY, node);
}

// Context Menu Management
function showContextMenu(x, y, node) {
  const menu = elements.contextMenu;
  menu.innerHTML = '';

  if (node.type === 'file') {
    addContextMenuItem('Open', () => requestFileContent(node.path));
    addContextMenuSeparator();
    addContextMenuItem('Delete', () => deleteFile(node.path));
  } else if (node.type === 'directory') {
    addContextMenuItem('New File...', () => createNewFile(node.path));
    addContextMenuItem('New Directory...', () => createNewDirectory(node.path));
    addContextMenuSeparator();
    addContextMenuItem('Delete Directory', () => deleteDirectory(node.path));
  }

  // Position and show menu
  menu.style.left = `${x}px`;
  menu.style.top = `${y}px`;
  menu.style.display = 'block';

  // Hide menu when clicking elsewhere
  const hideMenu = (e) => {
    if (!menu.contains(e.target)) {
      menu.style.display = 'none';
      document.removeEventListener('click', hideMenu);
    }
  };
  
  setTimeout(() => {
    document.addEventListener('click', hideMenu);
  }, 100);
}

function addContextMenuItem(text, onClick) {
  const item = document.createElement('div');
  item.className = 'context-menu-item';
  item.textContent = text;
  item.onclick = () => {
    elements.contextMenu.style.display = 'none';
    onClick();
  };
  elements.contextMenu.appendChild(item);
}

function addContextMenuSeparator() {
  const separator = document.createElement('div');
  separator.className = 'context-menu-separator';
  elements.contextMenu.appendChild(separator);
}

// File Operations
function requestFileContent(filePath) {
  sendWebSocketMessage({
    action: 'read_file',
    path: filePath,
    encoding: 'utf8'
  });
}

function saveFileContent(filePath, content) {
  sendWebSocketMessage({
    action: 'update_file',
    path: filePath,
    content: content,
    backup: true,
    atomic: true
  });
}

function createNewFile(parentPath) {
  const fileName = prompt('Enter file name:');
  if (fileName?.trim()) {
    addMessage(`Creating new file: ${fileName.trim()} in ${parentPath}`, 'info');
    sendWebSocketMessage({
      action: 'create_file',
      parent_path: parentPath,
      file_name: fileName.trim(),
      content: '',
      overwrite: false
    });
  }
}

function createNewDirectory(parentPath) {
  const dirName = prompt('Enter directory name:');
  if (dirName?.trim()) {
    addMessage(`Creating new directory: ${dirName.trim()} in ${parentPath}`, 'info');
    sendWebSocketMessage({
      action: 'create_directory',
      parent_path: parentPath,
      directory_name: dirName.trim(),
      recursive: true
    });
  }
}

function deleteFile(filePath) {
  if (confirm(`Are you sure you want to delete ${filePath}?`)) {
    sendWebSocketMessage({
      action: 'delete_file',
      path: filePath,
      backup: false
    });
  }
}

function deleteDirectory(dirPath) {
  if (confirm(`Are you sure you want to delete directory ${dirPath}? This action cannot be undone.`)) {
    sendWebSocketMessage({
      action: 'delete_directory',
      path: dirPath,
      recursive: true
    });
  }
}

// Tab Management
function generateTabId() {
  return 'tab_' + Math.random().toString(36).substring(2, 11);
}

function openFileInEditor(filePath, content) {
  // Check if file is already open
  let existingTab = findTabByPath(filePath);
  
  if (existingTab) {
    // Switch to existing tab
    switchToTab(existingTab.id);
    return;
  }

  // Create new tab
  const tabId = generateTabId();
  const fileName = filePath.split('/').pop();
  
  const tab = {
    id: tabId,
    path: filePath,
    name: fileName,
    content: content,
    originalContent: content,
    isDirty: false
  };

  openTabs.push(tab);
  renderTabs();
  switchToTab(tabId);
}

function findTabByPath(filePath) {
  return openTabs.find(tab => tab.path === filePath);
}

function findTabById(tabId) {
  return openTabs.find(tab => tab.id === tabId);
}

function renderTabs() {
  elements.editorTabs.innerHTML = '';
  
  openTabs.forEach(tab => {
    const tabElement = document.createElement('div');
    tabElement.className = `editor-tab ${tab.id === activeTabId ? 'active' : ''}`;
    if (tab.isDirty) {
      tabElement.classList.add('dirty');
    }
    
    const tabName = document.createElement('span');
    tabName.textContent = tab.name;
    
    const tabClose = document.createElement('span');
    tabClose.className = 'tab-close';
    tabClose.textContent = '×';
    tabClose.onclick = (e) => {
      e.stopPropagation();
      closeTab(tab.id);
    };
    
    tabElement.onclick = () => switchToTab(tab.id);
    
    tabElement.appendChild(tabName);
    tabElement.appendChild(tabClose);
    elements.editorTabs.appendChild(tabElement);
  });
}

function switchToTab(tabId) {
  const tab = findTabById(tabId);
  if (!tab) return;

  activeTabId = tabId;
  renderTabs();
  renderEditor(tab);
  updateEditorStatus(tab);
}

function closeTab(tabId) {
  const tab = findTabById(tabId);
  if (!tab) return;

  if (tab.isDirty) {
    const result = confirm(`${tab.name} has unsaved changes. Close anyway?`);
    if (!result) return;
  }

  openTabs = openTabs.filter(t => t.id !== tabId);
  
  if (activeTabId === tabId) {
    if (openTabs.length > 0) {
      switchToTab(openTabs[openTabs.length - 1].id);
    } else {
      activeTabId = null;
      renderEditor(null);
    }
  }
  
  renderTabs();
}

function renderEditor(tab) {
  elements.editorContent.innerHTML = '';
  
  if (!tab) {
    elements.editorContent.appendChild(elements.editorWelcome);
    return;
  }

  const textarea = document.createElement('textarea');
  textarea.className = 'editor-textarea';
  textarea.value = tab.content;
  textarea.oninput = () => {
    tab.content = textarea.value;
    tab.isDirty = tab.content !== tab.originalContent;
    updateTabVisual(tab);
    updateEditorStatus(tab);
  };

  // Add Ctrl+S save shortcut
  textarea.onkeydown = (e) => {
    if (e.ctrlKey && e.key === 's') {
      e.preventDefault();
      saveFile(tab);
    }
  };

  elements.editorContent.appendChild(textarea);
  textarea.focus();
}

function updateTabVisual(tab) {
  renderTabs(); // Re-render tabs to update dirty state
}

function updateEditorStatus(tab) {
  if (!tab) {
    elements.statusLeft.textContent = 'Ready';
    elements.statusRight.textContent = '';
    return;
  }

  const status = tab.isDirty ? 'Modified' : 'Saved';
  elements.statusLeft.textContent = `${tab.name} - ${status}`;
  elements.statusRight.textContent = `${tab.content.length} characters`;
}

function saveFile(tab) {
  if (!tab.isDirty) {
    addMessage('No changes to save', 'info');
    return;
  }

  saveFileContent(tab.path, tab.content);
  // Note: tab.isDirty will be set to false in handleFileUpdateResponse
}

// Message Management
function addMessage(text, type = 'info') {
  const messageElement = document.createElement('div');
  messageElement.className = `message-item ${type}`;
  messageElement.textContent = `[${new Date().toLocaleTimeString()}] ${text}`;
  
  elements.messagesContent.appendChild(messageElement);
  elements.messagesContent.scrollTop = elements.messagesContent.scrollHeight;

  // Limit messages to prevent memory issues
  const messages = elements.messagesContent.children;
  if (messages.length > 100) {
    elements.messagesContent.removeChild(messages[0]);
  }
}

function clearMessages() {
  elements.messagesContent.innerHTML = '';
  addMessage('Messages cleared', 'info');
}

// Event Listeners
elements.connectBtn.onclick = connectWebSocket;
elements.refreshTreeBtn.onclick = loadInitialFileTree;
elements.collapseAllBtn.onclick = () => {
  // Collapse all expanded tree nodes
  document.querySelectorAll('.tree-expand.expanded').forEach(btn => {
    btn.click();
  });
};
elements.clearMessagesBtn.onclick = clearMessages;

// Keyboard shortcuts
document.addEventListener('keydown', (e) => {
  if (e.ctrlKey) {
    switch (e.key) {
      case 's':
        e.preventDefault();
        if (activeTabId) {
          const tab = findTabById(activeTabId);
          if (tab) saveFile(tab);
        }
        break;
      case 'w':
        e.preventDefault();
        if (activeTabId) {
          closeTab(activeTabId);
        }
        break;
    }
  }
});

// Initialize
updateConnectionStatus('disconnected');
addMessage('File Manager ready. Click Connect to start.', 'info');

console.log('VSCode-like File Manager renderer loaded');