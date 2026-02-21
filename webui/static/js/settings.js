/**
 * Settings page JavaScript for phev2mqtt web UI.
 * Handles WiFi, MQTT, service control, logging, resources, and password management.
 */

const API_BASE = '/api';

// Polling intervals (milliseconds)
const POLL_INTERVALS = {
  status: 5000,  // WiFi, MQTT, phev2mqtt status
  resources: 3000,  // Resource monitor
};

// Thresholds from backend
let thresholds = {};

// Polling IDs
let pollTimeouts = {};

// CPU tracking for sustained high usage
let cpuSamples = [];  // Array of { timestamp, percent } for last 60 seconds

document.addEventListener('DOMContentLoaded', initSettings);

function initSettings() {
  loadInitialData();
  setupWiFiSection();
  setupMQTTSection();
  setupPhevSection();
  setupResourceMonitor();
  setupPasswordSection();
  setupSSHToggle();
  setupLogSettings();
  
  // Start polling
  startStatusPolling();
}

// ============================================================================
// Initial Data Loading
// ============================================================================

async function loadInitialData() {
  try {
    const [config, thresholdsData, resourceSnapshot] = await Promise.all([
      fetch(`${API_BASE}/config/get`).then(r => r.json()),
      fetch(`${API_BASE}/resources/thresholds`).then(r => r.json()),
      fetch(`${API_BASE}/resources/snapshot`).then(r => r.json()),
    ]);
    
    thresholds = thresholdsData;
    
    // Populate WiFi interfaces
    const wifiInterfaces = await fetch(`${API_BASE}/wifi/interfaces`).then(r => r.json());
    populateSelect('wifi-interface', wifiInterfaces.interfaces || []);
    
    // Populate saved WiFi settings
    if (config.wifi_interface) {
      document.getElementById('wifi-interface').value = config.wifi_interface;
    }
    if (config.wifi_ssid) {
      document.getElementById('wifi-ssid').value = config.wifi_ssid;
    }
    if (config.wifi_region) {
      document.getElementById('wifi-region').value = config.wifi_region;
    }
    
    // Populate MQTT settings
    if (config.mqtt_server) {
      document.getElementById('mqtt-server').value = config.mqtt_server;
    }
    if (config.mqtt_port) {
      document.getElementById('mqtt-port').value = config.mqtt_port;
    }
    
    // Populate log settings
    if (config.journal_max) {
      document.getElementById('journal-max').value = config.journal_max;
    }
    if (config.retention_days) {
      document.getElementById('retention-days').value = config.retention_days;
    }
    if (config.log_size) {
      document.getElementById('log-size').value = config.log_size;
    }
    if (config.log_rotate) {
      document.getElementById('log-rotate').value = config.log_rotate;
    }
    if (config.log_level) {
      document.getElementById('log-level').value = config.log_level;
    }
    
    // Populate SSH state
    if (config.ssh_enabled) {
      document.getElementById('ssh-enabled').checked = config.ssh_enabled;
    }
    
    // Update resource monitor with initial data
    updateResourceDisplay(resourceSnapshot);
    
  } catch (error) {
    console.error('Failed to load initial data:', error);
  }
}

// ============================================================================
// WiFi Section
// ============================================================================

function setupWiFiSection() {
  const scanBtn = document.querySelector('.card:has(> h2:contains("WiFi")) .actions button:nth-child(1)');
  const connectBtn = document.querySelector('.card:has(> h2:contains("WiFi")) .actions .btn.primary');
  
  // Find buttons more robustly
  const wifiCard = Array.from(document.querySelectorAll('.card')).find(c => c.textContent.includes('WiFi'));
  if (!wifiCard) return;
  
  const buttons = wifiCard.querySelectorAll('button');
  const scanBtn2 = Array.from(buttons).find(b => b.textContent.trim() === 'Scan');
  const connectBtn2 = Array.from(buttons).find(b => b.textContent.includes('Connect'));
  
  if (scanBtn2) {
    scanBtn2.addEventListener('click', handleWiFiScan);
  }
  if (connectBtn2) {
    connectBtn2.addEventListener('click', handleWiFiConnect);
  }
  
  // Handle DHCP toggle
  const dhcpCheckbox = document.getElementById('wifi-dhcp');
  if (dhcpCheckbox) {
    dhcpCheckbox.addEventListener('change', (e) => {
      const manualFields = [
        document.getElementById('wifi-ip'),
        document.getElementById('wifi-netmask'),
        document.getElementById('wifi-gateway'),
      ];
      manualFields.forEach(field => {
        if (field) field.disabled = e.target.checked;
      });
    });
    // Trigger on load
    dhcpCheckbox.dispatchEvent(new Event('change'));
  }
}

async function handleWiFiScan() {
  const iface = document.getElementById('wifi-interface').value;
  if (!iface) {
    showStatus('wifi', 'Please select an interface first');
    return;
  }
  
  try {
    const response = await fetch(`${API_BASE}/wifi/scan`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ interface: iface }),
    });
    
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const data = await response.json();
    populateSelect('wifi-ssid', data.ssids || []);
    showStatus('wifi', 'Scan complete');
  } catch (error) {
    showStatus('wifi', `Scan failed: ${error.message}`);
  }
}

async function handleWiFiConnect() {
  const iface = document.getElementById('wifi-interface').value;
  const ssid = document.getElementById('wifi-ssid').value;
  const psk = document.getElementById('wifi-psk').value;
  const dhcp = document.getElementById('wifi-dhcp').checked;
  const region = document.getElementById('wifi-region').value;
  
  if (!iface || !ssid) {
    showStatus('wifi', 'Please select interface and SSID');
    return;
  }
  
  const body = {
    interface: iface,
    ssid,
    psk: psk || null,
    dhcp,
    region: region || null,
  };
  
  if (!dhcp) {
    body.ip = document.getElementById('wifi-ip').value;
    body.netmask = document.getElementById('wifi-netmask').value;
    body.gateway = document.getElementById('wifi-gateway').value;
  }
  
  const mac = document.getElementById('wifi-mac').value;
  if (mac) body.mac = mac;
  
  try {
    const response = await fetch(`${API_BASE}/wifi/connect`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
    
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    showStatus('wifi', 'Connecting...');
  } catch (error) {
    showStatus('wifi', `Connection failed: ${error.message}`);
  }
}

// ============================================================================
// MQTT Section
// ============================================================================

function setupMQTTSection() {
  const mqttCard = Array.from(document.querySelectorAll('.card')).find(c => c.textContent.includes('MQTT'));
  if (!mqttCard) return;
  
  const buttons = mqttCard.querySelectorAll('button');
  const connectBtn = Array.from(buttons).find(b => b.textContent.includes('MQTT'));
  
  if (connectBtn) {
    connectBtn.addEventListener('click', handleMQTTConnect);
  }
}

async function handleMQTTConnect() {
  const server = document.getElementById('mqtt-server').value;
  const port = parseInt(document.getElementById('mqtt-port').value) || 1883;
  const username = document.getElementById('mqtt-user').value;
  const password = document.getElementById('mqtt-pass').value;
  
  if (!server) {
    showStatus('mqtt', 'Please enter MQTT server');
    return;
  }
  
  try {
    const response = await fetch(`${API_BASE}/mqtt/connect`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        server,
        port,
        username: username || null,
        password: password || null,
      }),
    });
    
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    showStatus('mqtt', 'Connecting...');
  } catch (error) {
    showStatus('mqtt', `Connection failed: ${error.message}`);
  }
}

// ============================================================================
// phev2mqtt Service Section
// ============================================================================

function setupPhevSection() {
  const phevCard = Array.from(document.querySelectorAll('.card')).find(c => c.textContent.includes('phev2mqtt Service'));
  if (!phevCard) return;
  
  const buttons = phevCard.querySelectorAll('button');
  const startBtn = Array.from(buttons).find(b => b.textContent.trim() === 'Start');
  const stopBtn = Array.from(buttons).find(b => b.textContent.trim() === 'Stop');
  const restartBtn = Array.from(buttons).find(b => b.textContent.trim() === 'Restart');
  
  if (startBtn) startBtn.addEventListener('click', () => fetchPhevAction('start'));
  if (stopBtn) stopBtn.addEventListener('click', () => fetchPhevAction('stop'));
  if (restartBtn) restartBtn.addEventListener('click', () => fetchPhevAction('restart'));
}

async function fetchPhevAction(action) {
  try {
    const response = await fetch(`${API_BASE}/phev/${action}`, { method: 'POST' });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
  } catch (error) {
    console.error(`phev2mqtt ${action} failed:`, error);
  }
}

// ============================================================================
// Resource Monitor Section
// ============================================================================

function setupResourceMonitor() {
  // Initial data loaded in loadInitialData
}

function updateResourceDisplay(snapshot) {
  if (!snapshot) return;
  
  const { disk, ram, cpu } = snapshot;
  
  // Update disk
  if (disk) {
    const diskPercent = ((disk.used / disk.total) * 100).toFixed(1);
    const diskFree = disk.total - disk.used;
    const diskFreePct = ((diskFree / disk.total) * 100).toFixed(1);
    
    const diskDot = document.querySelector('.resource:nth-child(1) .status-dot');
    if (diskDot) {
      diskDot.className = 'status-dot';
      if (diskFreePct < thresholds.disk?.critical_free_percent) {
        diskDot.classList.add('critical');
      } else if (diskFreePct < thresholds.disk?.warning_free_percent) {
        diskDot.classList.add('warn');
      }
    }
    
    const diskText = document.querySelector('.resource:nth-child(1) div');
    if (diskText) {
      diskText.innerHTML = `<strong>Disk</strong><br />${diskPercent}% / 100% (${diskFreePct}% free)`;
    }
  }
  
  // Update RAM
  if (ram) {
    const ramPercent = ((ram.used / ram.total) * 100).toFixed(1);
    
    const ramDot = document.querySelector('.resource:nth-child(2) .status-dot');
    if (ramDot) {
      ramDot.className = 'status-dot';
      if (ramPercent >= thresholds.ram?.critical_used_percent) {
        ramDot.classList.add('critical');
      } else if (ramPercent >= thresholds.ram?.warning_used_percent) {
        ramDot.classList.add('warn');
      }
    }
    
    const ramText = document.querySelector('.resource:nth-child(2) div');
    if (ramText) {
      ramText.innerHTML = `<strong>RAM</strong><br />${ramPercent}% / 100%`;
    }
  }
  
  // Update CPU
  if (cpu !== undefined) {
    cpuSamples.push({ timestamp: Date.now(), percent: cpu });
    
    // Keep only last 60 seconds
    const sixtySecondsAgo = Date.now() - 60000;
    cpuSamples = cpuSamples.filter(s => s.timestamp > sixtySecondsAgo);
    
    // Check if sustained high CPU (>80% for entire 60s window)
    const isSustainedHigh = cpuSamples.length > 5 && 
      cpuSamples.every(s => s.percent > thresholds.cpu?.warning_percent);
    
    const cpuDot = document.querySelector('.resource:nth-child(3) .status-dot');
    if (cpuDot) {
      cpuDot.className = 'status-dot';
      if (isSustainedHigh) {
        cpuDot.classList.add('warn');
      }
    }
    
    const cpuText = document.querySelector('.resource:nth-child(3) div');
    if (cpuText) {
      const avgCpu = cpuSamples.length > 0 
        ? (cpuSamples.reduce((sum, s) => sum + s.percent, 0) / cpuSamples.length).toFixed(1)
        : cpu.toFixed(1);
      cpuText.innerHTML = `<strong>CPU</strong><br />${avgCpu}% sustained`;
    }
  }
}

// ============================================================================
// Password Section
// ============================================================================

function setupPasswordSection() {
  const passwordCard = Array.from(document.querySelectorAll('.card')).find(c => c.textContent.includes('Web UI Password'));
  if (!passwordCard) return;
  
  const btn = passwordCard.querySelector('.btn.primary');
  if (btn) {
    btn.addEventListener('click', handlePasswordChange);
  }
}

async function handlePasswordChange() {
  const oldPwd = document.getElementById('current-password').value;
  const newPwd = document.getElementById('new-password').value;
  const confirmPwd = document.getElementById('confirm-password').value;
  
  if (!oldPwd || !newPwd || !confirmPwd) {
    showStatus('password', 'All fields required');
    return;
  }
  
  if (newPwd !== confirmPwd) {
    showStatus('password', 'New passwords do not match');
    return;
  }
  
  if (newPwd.length < 8) {
    showStatus('password', 'Password must be at least 8 characters');
    return;
  }
  
  try {
    const response = await fetch(`${API_BASE}/auth/change-password`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        old_password: oldPwd,
        new_password: newPwd,
      }),
    });
    
    if (!response.ok) {
      const error = await response.json();
      throw new Error(error.error || `HTTP ${response.status}`);
    }
    
    document.getElementById('current-password').value = '';
    document.getElementById('new-password').value = '';
    document.getElementById('confirm-password').value = '';
    showStatus('password', 'Password changed. Please log in again.');
    
    setTimeout(() => window.location.href = '/logout', 2000);
  } catch (error) {
    showStatus('password', `Change failed: ${error.message}`);
  }
}

// ============================================================================
// SSH Toggle
// ============================================================================

function setupSSHToggle() {
  const sshCheckbox = document.getElementById('ssh-enabled');
  if (sshCheckbox) {
    sshCheckbox.addEventListener('change', handleSSHToggle);
  }
}

async function handleSSHToggle(e) {
  const enabled = e.target.checked;
  
  try {
    const response = await fetch(`${API_BASE}/ssh/toggle`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ enabled }),
    });
    
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    
    const sshCard = Array.from(document.querySelectorAll('.card')).find(c => c.textContent.includes('SSH Access'));
    if (sshCard) {
      const status = sshCard.querySelector('.status');
      if (status) {
        status.textContent = `Status: ${enabled ? 'Enabled' : 'Disabled'}`;
      }
    }
  } catch (error) {
    e.target.checked = !enabled;
    console.error('SSH toggle failed:', error);
  }
}

// ============================================================================
// Log Settings
// ============================================================================

function setupLogSettings() {
  const logCard = Array.from(document.querySelectorAll('.card')).find(c => c.textContent.includes('Log Settings'));
  if (!logCard) return;
  
  // Sliders auto-save on change
  const sliders = ['journal-max', 'retention-days', 'log-size', 'log-rotate'];
  sliders.forEach(id => {
    const elem = document.getElementById(id);
    if (elem) {
      elem.addEventListener('change', handleLogSliderChange);
      elem.addEventListener('input', updateLogFootprint);
    }
  });
  
  // Log level dropdown
  const logLevel = document.getElementById('log-level');
  if (logLevel) {
    logLevel.addEventListener('change', handleLogLevelChange);
  }
  
  // Log warning text for levels
  updateLogLevelWarning();
  
  // Buttons
  const buttons = logCard.querySelectorAll('button');
  const clearBtn = Array.from(buttons).find(b => b.textContent.includes('Clear'));
  const downloadBtn = Array.from(buttons).find(b => b.textContent.includes('Download'));
  
  if (clearBtn) clearBtn.addEventListener('click', handleClearLogs);
  if (downloadBtn) downloadBtn.addEventListener('click', handleDownloadLogs);
  
  // Initial footprint
  updateLogFootprint();
}

async function handleLogSliderChange(e) {
  const name = e.target.name;
  const value = e.target.value;
  
  try {
    const response = await fetch(`${API_BASE}/config/set`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ [name]: parseInt(value) }),
    });
    
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    updateLogFootprint();
  } catch (error) {
    console.error('Failed to save log setting:', error);
  }
}

function updateLogFootprint() {
  const journal = parseInt(document.getElementById('journal-max')?.value || 200);
  const logSize = parseInt(document.getElementById('log-size')?.value || 20);
  const logRotate = parseInt(document.getElementById('log-rotate')?.value || 5);
  
  const total = journal + (logSize * logRotate);
  
  const footprint = document.querySelector('.footprint');
  if (footprint) {
    footprint.textContent = `Estimated footprint: ${total} MB`;
  }
}

async function handleLogLevelChange(e) {
  const level = e.target.value;
  
  try {
    const response = await fetch(`${API_BASE}/phev/set-log-level`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ level }),
    });
    
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
  } catch (error) {
    console.error('Failed to set log level:', error);
  }
  
  updateLogLevelWarning();
}

function updateLogLevelWarning() {
  const level = document.getElementById('log-level')?.value || 'info';
  
  let warning = '';
  if (level === 'error') {
    warning = '⚠️ Error mode shows only critical failures. You may miss early warning signs.';
  } else if (level === 'debug') {
    warning = '⚠️ Debug mode generates very high log volume, especially during reconnection. Disable after troubleshooting.';
  }
  
  // Insert warning below log level select
  const select = document.getElementById('log-level');
  let warningElem = select?.parentElement?.querySelector('.log-level-warning');
  
  if (warning) {
    if (!warningElem) {
      warningElem = document.createElement('div');
      warningElem.className = 'log-level-warning';
      warningElem.style.cssText = 'margin-top: 8px; font-size: 13px; color: var(--warn); font-weight: 500;';
      select.parentElement.appendChild(warningElem);
    }
    warningElem.textContent = warning;
  } else if (warningElem) {
    warningElem.remove();
  }
}

async function handleClearLogs() {
  const logCard = Array.from(document.querySelectorAll('.card')).find(c => c.textContent.includes('Log Settings'));
  if (!logCard) return;
  
  // Remove any existing confirmation dialog
  const existingConfirm = logCard.querySelector('.log-clear-confirm');
  if (existingConfirm) {
    existingConfirm.remove();
    return;
  }
  
  // Create confirmation UI
  const confirmDiv = document.createElement('div');
  confirmDiv.className = 'log-clear-confirm';
  confirmDiv.style.cssText = 'margin-top: 12px; padding: 12px; border: 1px solid var(--warn); border-radius: 6px; background: #fff9f0;';
  confirmDiv.innerHTML = `
    <div style="font-weight: 600; color: var(--warn); margin-bottom: 8px;">Are you sure? This cannot be undone.</div>
    <div style="display: flex; gap: 8px;">
      <button class="btn confirm-clear" style="background: var(--critical); color: white; border-color: var(--critical);">Confirm</button>
      <button class="btn cancel-clear">Cancel</button>
    </div>
  `;
  
  // Insert after buttons
  const actions = logCard.querySelector('.actions');
  if (actions) {
    actions.parentElement.insertBefore(confirmDiv, actions.nextSibling);
  }
  
  // Handle confirm
  const confirmBtn = confirmDiv.querySelector('.confirm-clear');
  confirmBtn.addEventListener('click', async () => {
    try {
      // NOTE: /api/logs/clear endpoint does not exist in api.py yet — must be added
      const response = await fetch(`${API_BASE}/logs/clear`, {
        method: 'POST',
      });
      
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      confirmDiv.remove();
      console.log('Logs cleared');
    } catch (error) {
      console.error('Failed to clear logs:', error);
      confirmDiv.remove();
    }
  });
  
  // Handle cancel
  const cancelBtn = confirmDiv.querySelector('.cancel-clear');
  cancelBtn.addEventListener('click', () => {
    confirmDiv.remove();
  });
}

async function handleDownloadLogs() {
  try {
    const response = await fetch(`${API_BASE}/logs/download`);
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    
    const blob = await response.blob();
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `phev2mqtt-logs-${Date.now()}.txt`;
    a.click();
    URL.revokeObjectURL(url);
  } catch (error) {
    console.error('Failed to download logs:', error);
  }
}

// ============================================================================
// Status Polling
// ============================================================================

function startStatusPolling() {
  // WiFi status
  pollStatus('wifi', `${API_BASE}/wifi/status`, updateWiFiStatus);
  
  // MQTT status
  pollStatus('mqtt', `${API_BASE}/mqtt/status`, updateMQTTStatus);
  
  // phev2mqtt status
  pollStatus('phev', `${API_BASE}/phev/status`, updatePhevStatus);
  
  // Resource snapshot
  pollStatus('resources', `${API_BASE}/resources/snapshot`, updateResourceDisplay, POLL_INTERVALS.resources);
}

function pollStatus(key, url, updateFn, interval = POLL_INTERVALS.status) {
  async function poll() {
    try {
      const response = await fetch(url);
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const data = await response.json();
      updateFn(data);
    } catch (error) {
      console.error(`Status poll error (${key}):`, error);
    }
    
    pollTimeouts[key] = setTimeout(poll, interval);
  }
  
  poll();  // Initial call
}

function updateWiFiStatus(status) {
  const wifiCard = Array.from(document.querySelectorAll('.card')).find(c => c.textContent.includes('WiFi'));
  if (!wifiCard) return;
  
  const statusDiv = wifiCard.querySelector('.status');
  if (!statusDiv) return;
  
  if (status.connected) {
    const parts = [
      `🟢 Connected to ${status.ssid}`,
      `IP: ${status.ip}`,
      `Gateway: ${status.gateway}`,
      `MAC: ${status.mac}`,
      `Signal: ${status.rssi}`,
    ];
    statusDiv.textContent = parts.join(' • ');
  } else {
    statusDiv.textContent = '🔴 Not connected';
  }
}

function updateMQTTStatus(status) {
  const mqttCard = Array.from(document.querySelectorAll('.card')).find(c => c.textContent.includes('MQTT'));
  if (!mqttCard) return;
  
  const statusDiv = mqttCard.querySelector('.status');
  if (!statusDiv) return;
  
  if (status.connected) {
    const parts = [
      `🟢 Connected to ${status.server}:${status.port}`,
      `Uptime: ${status.uptime}`,
    ];
    statusDiv.textContent = parts.join(' • ');
  } else {
    statusDiv.textContent = '🔴 Not connected';
  }
}

function updatePhevStatus(status) {
  const phevCard = Array.from(document.querySelectorAll('.card')).find(c => c.textContent.includes('phev2mqtt Service'));
  if (!phevCard) return;
  
  const statusDiv = phevCard.querySelector('.status');
  if (!statusDiv) return;
  
  if (status.running) {
    statusDiv.textContent = `🟢 Running`;
  } else {
    statusDiv.textContent = `🔴 Stopped`;
  }
}

// ============================================================================
// Utility Functions
// ============================================================================

function populateSelect(selectId, options) {
  const select = document.getElementById(selectId);
  if (!select) return;
  
  const currentValue = select.value;
  select.innerHTML = options.map(opt => `<option value="${escapeHtml(opt)}">${escapeHtml(opt)}</option>`).join('');
  
  if (options.includes(currentValue)) {
    select.value = currentValue;
  }
}

function showStatus(sectionKey, message) {
  // Find relevant card and update its status div
  let selector = '';
  switch (sectionKey) {
    case 'wifi':
      selector = '.card:has(> h2:contains("WiFi"))';
      break;
    case 'mqtt':
      selector = '.card:has(> h2:contains("MQTT"))';
      break;
    case 'password':
      selector = '.card:has(> h2:contains("Password"))';
      break;
    default:
      return;
  }
  
  // Use array find as fallback
  let card;
  if (sectionKey === 'wifi') {
    card = Array.from(document.querySelectorAll('.card')).find(c => c.textContent.includes('WiFi'));
  } else if (sectionKey === 'mqtt') {
    card = Array.from(document.querySelectorAll('.card')).find(c => c.textContent.includes('MQTT'));
  } else if (sectionKey === 'password') {
    card = Array.from(document.querySelectorAll('.card')).find(c => c.textContent.includes('Password'));
  }
  
  if (!card) return;
  
  const status = card.querySelector('.status');
  if (status) {
    status.textContent = message;
  }
}

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
