/**
 * Tools page JavaScript for phev2mqtt web UI.
 * Handles vehicle emulator, pre-built commands, and xterm.js terminal.
 */

const API_BASE = '/api';
const WS_TERMINAL_URL = `${window.location.protocol === 'https:' ? 'wss:' : 'ws:'}//${window.location.host}/ws/terminal`;

let terminal = null;
let fitAddon = null;
let terminalSocket = null;
let emulatorPollInterval = null;

document.addEventListener('DOMContentLoaded', initTools);

function initTools() {
  loadInitialData();
  setupEmulatorSection();
  setupCommandsSection();
  setupTerminal();
}

// ============================================================================
// Initial Data Loading
// ============================================================================

async function loadInitialData() {
  try {
    // Load config to populate VIN field
    const config = await fetch(`${API_BASE}/config/get`).then(r => r.json());
    if (config.phev_vin) {
      document.getElementById('emulator-vin').value = config.phev_vin;
    }
    
    // Load emulator status
    const emulatorStatus = await fetch(`${API_BASE}/emulator/status`).then(r => r.json());
    document.getElementById('emulator-enabled').checked = emulatorStatus.running || false;
    updateEmulatorWarning(emulatorStatus.running);
    
    // Load pre-built commands
    const commandsData = await fetch(`${API_BASE}/terminal/commands`).then(r => r.json());
    populateCommands(commandsData.commands || []);
    
  } catch (error) {
    console.error('Failed to load initial data:', error);
  }
}

// ============================================================================
// Vehicle Emulator Section
// ============================================================================

function setupEmulatorSection() {
  const emulatorCheckbox = document.getElementById('emulator-enabled');
  if (emulatorCheckbox) {
    emulatorCheckbox.addEventListener('change', handleEmulatorToggle);
  }
  
  // Start polling emulator status every 5s
  emulatorPollInterval = setInterval(pollEmulatorStatus, 5000);
}

async function handleEmulatorToggle(e) {
  const enabled = e.target.checked;
  const vinInput = document.getElementById('emulator-vin');
  const vin = vinInput.value.trim().toUpperCase();
  
  if (enabled) {
    // Validate VIN before enabling
    if (!vin || vin.length !== 17) {
      e.target.checked = false;
      showEmulatorError('VIN must be exactly 17 characters');
      vinInput.focus();
      return;
    }
    
    try {
      const response = await fetch(`${API_BASE}/emulator/enable`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ vin }),
      });
      
      if (!response.ok) {
        const error = await response.json();
        throw new Error(error.error || `HTTP ${response.status}`);
      }
      
      updateEmulatorWarning(true);
      clearEmulatorError();
    } catch (error) {
      e.target.checked = false;
      showEmulatorError(`Failed to enable: ${error.message}`);
    }
  } else {
    // Disable emulator
    try {
      const response = await fetch(`${API_BASE}/emulator/disable`, {
        method: 'POST',
      });
      
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      
      updateEmulatorWarning(false);
      clearEmulatorError();
    } catch (error) {
      console.error('Failed to disable emulator:', error);
    }
  }
}

async function pollEmulatorStatus() {
  try {
    const status = await fetch(`${API_BASE}/emulator/status`).then(r => r.json());
    const checkbox = document.getElementById('emulator-enabled');
    if (checkbox) {
      checkbox.checked = status.running || false;
    }
    updateEmulatorWarning(status.running);
  } catch (error) {
    console.error('Emulator status poll error:', error);
  }
}

function updateEmulatorWarning(visible) {
  const emulatorCard = Array.from(document.querySelectorAll('.card')).find(c => c.textContent.includes('Vehicle Emulator'));
  if (!emulatorCard) return;
  
  const warning = emulatorCard.querySelector('.warning');
  if (warning) {
    warning.style.display = visible ? 'block' : 'none';
  }
}

function showEmulatorError(message) {
  const vinInput = document.getElementById('emulator-vin');
  if (!vinInput) return;
  
  // Remove existing error if present
  let errorDiv = vinInput.parentElement.querySelector('.emulator-error');
  if (!errorDiv) {
    errorDiv = document.createElement('div');
    errorDiv.className = 'emulator-error';
    errorDiv.style.cssText = 'margin-top: 6px; color: var(--critical, #b42318); font-size: 13px; font-weight: 500;';
    vinInput.parentElement.appendChild(errorDiv);
  }
  errorDiv.textContent = message;
}

function clearEmulatorError() {
  const vinInput = document.getElementById('emulator-vin');
  const errorDiv = vinInput?.parentElement?.querySelector('.emulator-error');
  if (errorDiv) {
    errorDiv.remove();
  }
}

// ============================================================================
// Pre-built Commands Section
// ============================================================================

function setupCommandsSection() {
  const commandsCard = Array.from(document.querySelectorAll('.card')).find(c => c.textContent.includes('Pre-built Commands'));
  if (!commandsCard) return;
  
  const buttons = commandsCard.querySelectorAll('button');
  const sendBtn = Array.from(buttons).find(b => b.textContent.trim() === 'Send');
  const killBtn = Array.from(buttons).find(b => b.textContent.includes('Kill'));
  
  if (sendBtn) {
    sendBtn.addEventListener('click', handleSendCommand);
  }
  if (killBtn) {
    killBtn.addEventListener('click', handleKillCommand);
  }
}

function populateCommands(commands) {
  const select = document.getElementById('command-select');
  if (!select) return;
  
  select.innerHTML = commands.map(cmd => 
    `<option value="${escapeHtml(cmd.command)}">${escapeHtml(cmd.label)}</option>`
  ).join('');
}

async function handleSendCommand() {
  const select = document.getElementById('command-select');
  if (!select) return;
  
  const command = select.value;
  if (!command) return;
  
  try {
    // Send command to backend (for logging/tracking)
    await fetch(`${API_BASE}/terminal/send-command`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ command }),
    });
    
    // Write command directly to terminal via WebSocket
    if (terminalSocket && terminalSocket.readyState === WebSocket.OPEN) {
      terminalSocket.send(command + '\n');
    }
  } catch (error) {
    console.error('Failed to send command:', error);
  }
}

function handleKillCommand() {
  // Close and reopen WebSocket to terminate running process
  if (terminalSocket) {
    terminalSocket.close();
  }
  
  // Reconnection will happen automatically via setupTerminal WebSocket close handler
  setTimeout(() => {
    setupTerminalWebSocket();
  }, 100);
}

// ============================================================================
// xterm.js Terminal
// ============================================================================

function setupTerminal() {
  // Import from CDN (already loaded via script tags in HTML)
  if (typeof Terminal === 'undefined') {
    console.error('xterm.js not loaded');
    return;
  }
  
  // Initialize terminal
  terminal = new Terminal({
    cursorBlink: true,
    fontSize: 14,
    fontFamily: 'Consolas, "Courier New", monospace',
    theme: {
      background: '#0b0e14',
      foreground: '#c5c8c6',
    },
  });
  
  // Load FitAddon from CDN
  // Note: FitAddon must be loaded separately via CDN or bundled
  // For now, we'll handle resize manually
  
  const terminalContainer = document.getElementById('terminal');
  if (terminalContainer) {
    terminal.open(terminalContainer);
    
    // Manual fit to container
    fitTerminalToContainer();
    
    // Handle window resize
    let resizeTimeout;
    window.addEventListener('resize', () => {
      clearTimeout(resizeTimeout);
      resizeTimeout = setTimeout(fitTerminalToContainer, 100);
    });
    
    // Listen for terminal resize events to send to backend
    terminal.onResize(({ cols, rows }) => {
      if (terminalSocket && terminalSocket.readyState === WebSocket.OPEN) {
        terminalSocket.send(JSON.stringify({ type: 'resize', cols, rows }));
      }
    });
    
    // Handle terminal input (keyboard)
    terminal.onData(data => {
      if (terminalSocket && terminalSocket.readyState === WebSocket.OPEN) {
        terminalSocket.send(data);
      }
    });
    
    // Copy/Paste support
    setupTerminalCopyPaste();
    
    // Connect WebSocket
    setupTerminalWebSocket();
  }
}

function fitTerminalToContainer() {
  if (!terminal) return;
  
  const container = document.getElementById('terminal');
  if (!container) return;
  
  // Calculate dimensions based on container size
  // Approximate character dimensions (adjust based on font)
  const charWidth = 9;  // pixels
  const charHeight = 17; // pixels
  
  const cols = Math.max(Math.floor(container.clientWidth / charWidth), 10);
  const rows = Math.max(Math.floor(container.clientHeight / charHeight), 5);
  
  if (cols !== terminal.cols || rows !== terminal.rows) {
    terminal.resize(cols, rows);
  }
}

function setupTerminalWebSocket() {
  if (terminalSocket) {
    terminalSocket.close();
  }
  
  terminalSocket = new WebSocket(WS_TERMINAL_URL);
  
  terminalSocket.onopen = () => {
    console.log('Terminal WebSocket connected');
    terminal.clear();
    terminal.focus();
    
    // Send initial terminal size
    terminalSocket.send(JSON.stringify({
      type: 'resize',
      cols: terminal.cols,
      rows: terminal.rows,
    }));
  };
  
  terminalSocket.onmessage = (event) => {
    // Write data from backend to terminal
    if (terminal) {
      terminal.write(event.data);
    }
  };
  
  terminalSocket.onclose = (event) => {
    console.log('Terminal WebSocket closed:', event.code, event.reason);
    if (terminal) {
      terminal.writeln('\r\n\x1B[31m[Connection closed]\x1B[0m');
    }
  };
  
  terminalSocket.onerror = (error) => {
    console.error('Terminal WebSocket error:', error);
    if (terminal) {
      terminal.writeln('\r\n\x1B[31m[Connection error]\x1B[0m');
    }
  };
}

function setupTerminalCopyPaste() {
  if (!terminal) return;
  
  const terminalContainer = document.getElementById('terminal');
  if (!terminalContainer) return;
  
  // Copy: Ctrl+Shift+C
  terminalContainer.addEventListener('keydown', (e) => {
    if (e.ctrlKey && e.shiftKey && e.key === 'C') {
      e.preventDefault();
      const selection = terminal.getSelection();
      if (selection) {
        navigator.clipboard.writeText(selection);
      }
    }
    
    // Paste: Ctrl+Shift+V
    if (e.ctrlKey && e.shiftKey && e.key === 'V') {
      e.preventDefault();
      navigator.clipboard.readText().then(text => {
        if (terminalSocket && terminalSocket.readyState === WebSocket.OPEN) {
          terminalSocket.send(text);
        }
      });
    }
  });
  
  // Right-click paste
  terminalContainer.addEventListener('contextmenu', (e) => {
    e.preventDefault();
    navigator.clipboard.readText().then(text => {
      if (terminalSocket && terminalSocket.readyState === WebSocket.OPEN) {
        terminalSocket.send(text);
      }
    }).catch(err => {
      console.error('Paste failed:', err);
    });
  });
}

// ============================================================================
// Utility Functions
// ============================================================================

function escapeHtml(text) {
  const map = {
    '&': '&amp;',
    '<': '&lt;',
    '>': '&gt;',
    '"': '&quot;',
    "'": '&#039;',
  };
  return text.replace(/[&<>"']/g, m => map[m]);
}

// Cleanup on page unload
window.addEventListener('beforeunload', () => {
  if (emulatorPollInterval) {
    clearInterval(emulatorPollInterval);
  }
  if (terminalSocket) {
    terminalSocket.close();
  }
});
