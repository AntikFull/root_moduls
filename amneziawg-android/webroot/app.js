// AWG-eCubz Material 3 Controller Logic
const STATE = {
  profiles: [],
  activeTunnels: [],
  installedApps: [],
  selectedApps: new Set(),
  editingProfileName: null,
  activeViewConf: null,
  searchQuery: '',
  currentAppFilter: 'all',
  activeTab: 'main'
};

let asyncExecSeq = 0;

function getKsuBridge() {
  if (typeof ksu !== 'undefined') return ksu;
  if (typeof window.ksu !== 'undefined') return window.ksu;
  return null;
}

// Android Root Shell Wrapper (Compatible with KernelSU / APatch / Magisk)
function sh(cmd) {
  const k = getKsuBridge();
  if (!k || typeof k.exec !== 'function') {
    console.warn('[No Root Bridge]:', cmd);
    return Promise.resolve({ code: 0, stdout: '', stderr: 'No root manager bridge' });
  }

  return new Promise((resolve) => {
    const id = '__ksuCb_' + (++asyncExecSeq);
    let done = false;

    const timer = setTimeout(() => {
      if (done) return;
      done = true;
      delete window[id];
      delete window['window.' + id];
      resolve({ code: -1, stdout: '', stderr: 'Exec timeout' });
    }, 8000);

    const callbackHandler = (code, stdout, stderr) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      delete window[id];
      delete window['window.' + id];
      resolve({
        code: Number(code ?? 0),
        stdout: String(stdout ?? ''),
        stderr: String(stderr ?? '')
      });
    };

    window[id] = callbackHandler;
    window['window.' + id] = callbackHandler;

    try {
      const ret = k.exec(cmd, 'window.' + id);

      if (ret && typeof ret.then === 'function') {
        ret.then(res => {
          if (done) return;
          done = true;
          clearTimeout(timer);
          delete window[id];
          delete window['window.' + id];
          if (typeof res === 'string') {
            try {
              const p = JSON.parse(res);
              resolve({ code: Number(p.errno ?? p.code ?? 0), stdout: String(p.stdout ?? res), stderr: String(p.stderr ?? '') });
            } catch (_) {
              resolve({ code: 0, stdout: res, stderr: '' });
            }
          } else if (res && typeof res === 'object') {
            resolve({ code: Number(res.errno ?? res.code ?? 0), stdout: String(res.stdout ?? ''), stderr: String(res.stderr ?? '') });
          } else {
            resolve({ code: 0, stdout: String(res || ''), stderr: '' });
          }
        }).catch(err => {
          if (done) return;
          done = true;
          clearTimeout(timer);
          delete window[id];
          delete window['window.' + id];
          resolve({ code: 1, stdout: '', stderr: String(err) });
        });
        return;
      }

      if (typeof ret === 'string' && ret.length > 0) {
        if (done) return;
        done = true;
        clearTimeout(timer);
        delete window[id];
        delete window['window.' + id];
        try {
          const p = JSON.parse(ret);
          resolve({ code: Number(p.errno ?? p.code ?? 0), stdout: String(p.stdout ?? ret), stderr: String(p.stderr ?? '') });
        } catch (_) {
          resolve({ code: 0, stdout: ret, stderr: '' });
        }
        return;
      }
    } catch (error) {
      if (done) return;
      done = true;
      clearTimeout(timer);
      delete window[id];
      delete window['window.' + id];

      try {
        const syncOut = k.exec(cmd);
        if (syncOut && typeof syncOut === 'object') {
          resolve({
            code: Number(syncOut.errno ?? syncOut.exitCode ?? 0),
            stdout: String(syncOut.stdout ?? ''),
            stderr: String(syncOut.stderr ?? '')
          });
        } else {
          resolve({ code: 0, stdout: String(syncOut ?? ''), stderr: '' });
        }
      } catch (syncErr) {
        resolve({ code: 1, stdout: '', stderr: String(syncErr) });
      }
    }
  });
}

// Toast Notification
function showToast(msg) {
  const sb = document.getElementById('m3-snackbar');
  if (!sb) return;
  sb.innerText = msg;
  sb.classList.add('show');
  setTimeout(() => sb.classList.remove('show'), 2500);
}

// Copy Text
function copyText(text, successMsg = 'Скопировано!') {
  if (!text) return;
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(text).then(() => showToast(successMsg));
  } else {
    const ta = document.createElement('textarea');
    ta.value = text;
    document.body.appendChild(ta);
    ta.select();
    document.execCommand('copy');
    document.body.removeChild(ta);
    showToast(successMsg);
  }
}

// External Intent Execution
function openUrl(url) {
  if (!url) return;
  sh(`am start -a android.intent.action.VIEW -d "${url}" 2>/dev/null`);
}

function openChannel() {
  openUrl('https://t.me/eCubzPlugins');
}



// Bottom Navigation Switching
function switchTabByName(tabName) {
  STATE.activeTab = tabName;

  document.querySelectorAll('.tab-page').forEach(page => {
    page.classList.remove('active');
  });
  const activePage = document.getElementById('tab-' + tabName);
  if (activePage) activePage.classList.add('active');

  document.querySelectorAll('.m3-nav-item').forEach(item => {
    item.classList.remove('active');
  });
  const activeNav = document.getElementById('nav-' + tabName);
  if (activeNav) activeNav.classList.add('active');

  window.scrollTo({ top: 0, behavior: 'smooth' });

  if (tabName === 'log') {
    loadLogs();
  }
  if (tabName === 'main' || tabName === 'profiles') {
    refreshAllData();
  }
}

function on(id, evt, handler) {
  const el = document.getElementById(id);
  if (el) el.addEventListener(evt, handler);
}

// Async Initialization Loop (Waits for KernelSU Bridge)
async function initWebUI() {
  let attempts = 0;
  while (!getKsuBridge() && attempts < 25) {
    await new Promise(r => setTimeout(r, 100));
    attempts++;
  }

  initEventHandlers();
  await refreshAllData();
  await loadInstalledApps();

  // Periodic Auto-refresh every 4 seconds for live handshakes/traffic
  setInterval(async () => {
    if (STATE.activeTab === 'main' || STATE.activeTab === 'profiles') {
      await loadProfiles();
      await loadStatus();
      renderDashboard();
      renderProfilesList();
      updateSystemSummary();
    }
  }, 4000);
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', initWebUI);
} else {
  initWebUI();
}

function initEventHandlers() {
  on('btn-master-restart', 'click', restartAll);
  on('btn-master-stop', 'click', stopAll);
  on('btn-add-profile', 'click', () => openProfileModal(null));

  const triggerQr = () => {
    const inp = document.getElementById('global-qr-file-input');
    if (inp) inp.click();
  };
  on('btn-add-profile-qr', 'click', triggerQr);
  on('btn-scan-qr-modal', 'click', triggerQr);
  on('global-qr-file-input', 'change', handleQrImageFile);

  // Profile Editor Modal
  on('btn-modal-close', 'click', closeProfileModal);
  on('btn-cancel-profile', 'click', closeProfileModal);
  on('btn-save-profile', 'click', saveProfile);

  // Logs & Diagnostics
  on('btn-refresh-logs', 'click', loadLogs);
  on('btn-clear-logs', 'click', () => {
    const v = document.getElementById('log-viewer');
    if (v) v.innerText = '';
  });
  on('btn-ping-tunnels', 'click', runPingTest);
  on('btn-dump-uapi', 'click', runUAPIDump);
  on('btn-dump-ip-rules', 'click', runIPRulesDump);

  // QR Viewer Modal
  on('btn-qr-view-close', 'click', closeQrViewModal);
  on('btn-qr-view-done', 'click', closeQrViewModal);
  on('btn-copy-conf', 'click', copyActiveConf);

  // App Search & Filtering
  on('app-search', 'input', (e) => {
    STATE.searchQuery = e.target.value.trim().toLowerCase();
    renderFilteredApps();
  });

  document.querySelectorAll('.m3-chips-row .m3-chip[data-filter]').forEach(chip => {
    chip.addEventListener('click', () => {
      document.querySelectorAll('.m3-chips-row .m3-chip[data-filter]').forEach(c => c.classList.remove('active'));
      chip.classList.add('active');
      STATE.currentAppFilter = chip.getAttribute('data-filter');
      renderFilteredApps();
    });
  });

  on('btn-select-all-visible', 'click', selectAllVisibleApps);
  on('btn-deselect-all', 'click', deselectAllApps);

  // Config File Upload
  on('file-conf-upload', 'change', (e) => {
    const file = e.target.files[0];
    if (file) {
      const reader = new FileReader();
      reader.onload = (evt) => {
        const rawEl = document.getElementById('prof-conf-raw');
        if (rawEl) rawEl.value = evt.target.result;
        autoFillProfileName(file.name.replace(/\.[^/.]+$/, ""));
        showToast('Конфигурация загружена');
      };
      reader.readAsText(file);
    }
  });

  // Routing Mode Change
  on('prof-mode', 'change', (e) => {
    const mode = e.target.value;
    const groupApps = document.getElementById('group-apps');
    if (groupApps) groupApps.style.display = (mode === 'all_traffic') ? 'none' : 'block';
  });
}

// Data Refresh
async function refreshAllData() {
  await loadProfiles();
  await loadStatus();
  renderDashboard();
  renderProfilesList();
  updateSystemSummary();
}

async function loadProfiles() {
  const res = await sh('/data/adb/modules/amneziawg-android/bin/awg-controller check-conflicts');
  try {
    let raw = (res.stdout || '').trim();
    const match = raw.match(/\{[\s\S]*"profiles"[\s\S]*\}/);
    if (match) raw = match[0];
    const data = JSON.parse(raw);
    STATE.profiles = data.profiles || [];
  } catch (e) {
    // If parse error, keep existing profiles
  }

  const pausedRes = await sh('for f in /data/adb/amneziawg/run/*.paused; do [ -f "$f" ] && echo "$(basename "$f" .paused)=$(cat "$f")"; done');
  const pausedMap = {};
  (pausedRes.stdout || '').trim().split('\n').forEach(line => {
    if (!line) return;
    const parts = line.split('=');
    if (parts[0]) pausedMap[parts[0]] = parts[1] || 'Wi-Fi';
  });
  STATE.profiles.forEach(p => {
    p.paused_ssid = pausedMap[p.name] || null;
  });
}

async function loadStatus() {
  const res = await sh('/data/adb/modules/amneziawg-android/bin/awg status json');
  try {
    let raw = (res.stdout || '').trim();
    const match = raw.match(/\[[\s\S]*\]/);
    if (match) raw = match[0];
    STATE.activeTunnels = JSON.parse(raw);
  } catch (e) {
    STATE.activeTunnels = [];
  }
}

function updateSystemSummary() {
  const activeCount = STATE.activeTunnels.length;
  const activeEl = document.getElementById('val-active-cnt');
  if (activeEl) activeEl.innerText = activeCount;
  const totalEl = document.getElementById('val-total-cnt');
  if (totalEl) totalEl.innerText = STATE.profiles.length;
}

// Render Dashboard Cards
function renderDashboard() {
  const container = document.getElementById('dashboard-cards');
  if (!container) return;
  container.innerHTML = '';

  if (STATE.profiles.length === 0) {
    container.innerHTML = '<div class="m3-card"><div class="m3-card-body"><p style="color:var(--md-sys-color-on-surface-variant);font-size:13px;">Профили загружаются или еще не созданы. Перейдите во вкладку "Профили" для добавления.</p></div></div>';
    return;
  }

  STATE.profiles.forEach(prof => {
    const tunnel = STATE.activeTunnels.find(t => 
      (t.profile_name && t.profile_name === prof.name) || 
      (prof.interface && t.interface === prof.interface) ||
      (t.interface && t.interface === (prof.interface || ''))
    ) || null;
    const isUp = !!tunnel;
    const peer = (tunnel && tunnel.peers && tunnel.peers[0]) || null;

    const card = document.createElement('div');
    card.className = `m3-profile-card ${isUp ? 'active' : ''}`;
    card.innerHTML = `
      <div class="m3-profile-header">
        <div class="m3-profile-title-box">
          <span class="m3-profile-name">${escapeHtml(prof.name)}</span>
          <span class="m3-badge ${isUp ? 'm3-badge-success' : 'm3-badge-idle'}">
            ${isUp ? 'Подключен' : 'Отключен'}
          </span>
        </div>
        <label class="m3-switch">
          <input type="checkbox" ${isUp ? 'checked' : ''} onchange="toggleProfile('${prof.name}', this.checked)">
          <span class="m3-slider"></span>
        </label>
      </div>

      <div class="m3-stats-grid">
        <div class="m3-stat-item">
          <span>Режим</span>
          <span>${prof.routing_mode === 'include_apps' ? 'Только выбранные' : (prof.routing_mode === 'exclude_apps' ? 'Исключая выбранные' : 'Весь трафик')}</span>
        </div>
        <div class="m3-stat-item">
          <span>Приложений</span>
          <span>${prof.apps ? prof.apps.length : 0}</span>
        </div>
        <div class="m3-stat-item">
          <span>Эндпоинт</span>
          <span>${peer && peer.endpoint ? escapeHtml(peer.endpoint) : 'Ожидание'}</span>
        </div>
        <div class="m3-stat-item">
          <span>Трафик (RX/TX)</span>
          <span>${peer ? formatBytes(peer.rx_bytes) + ' / ' + formatBytes(peer.tx_bytes) : '0 B / 0 B'}</span>
        </div>
      </div>

      <div class="m3-btn-group">
        <button class="m3-btn m3-btn-outlined m3-btn-sm" onclick="showProfileQr('${prof.name}')"><svg class="g-icon g-icon-sm" viewBox="0 0 24 24"><path fill="currentColor" d="M3 5v4h2V5h4V3H5c-1.1 0-2 .9-2 2zm2 10H3v4c0 1.1.9 2 2 2h4v-2H5v-4zm14 4h-4v2h4c1.1 0 2-.9 2-2v-4h-2v4zm0-16h-4v2h4v4h2V5c0-1.1-.9-2-2-2z"/></svg> QR-код</button>
        <button class="m3-btn m3-btn-tonal m3-btn-sm" onclick="editProfile('${prof.name}')"><svg class="g-icon g-icon-sm" viewBox="0 0 24 24"><path fill="currentColor" d="M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25zM20.71 7.04c.39-.39.39-1.02 0-1.41l-2.34-2.34c-.39-.39-1.02-.39-1.41 0l-1.83 1.83 3.75 3.75 1.83-1.83z"/></svg> Настроить</button>
      </div>
    `;
    container.appendChild(card);
  });
}

// Render Profiles List in Tab 2
function renderProfilesList() {
  const container = document.getElementById('profiles-list');
  if (!container) return;
  container.innerHTML = '';

  if (STATE.profiles.length === 0) {
    container.innerHTML = '<div class="m3-card"><div class="m3-card-body"><p style="color:var(--md-sys-color-on-surface-variant);font-size:13px;">Список пуст. Нажмите "+ Добавить профиль" или "Импорт QR".</p></div></div>';
    return;
  }

  STATE.profiles.forEach(prof => {
    const item = document.createElement('div');
    item.className = 'm3-profile-card';
    item.innerHTML = `
      <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 8px;">
        <span class="m3-profile-name">${escapeHtml(prof.name)}</span>
        <span class="m3-badge ${prof.enabled !== false ? 'm3-badge-success' : 'm3-badge-idle'}">
          ${prof.enabled !== false ? 'Автозапуск' : 'Ручной'}
        </span>
      </div>
      <p style="font-size: 12px; color: var(--md-sys-color-on-surface-variant); margin-bottom: 10px;">
        Режим: ${prof.routing_mode === 'include_apps' ? 'Выбранные' : (prof.routing_mode === 'exclude_apps' ? 'Исключая' : 'Полный')} &bull; 
        Приложений: ${prof.apps ? prof.apps.length : 0} &bull; 
        KillSwitch: ${prof.killswitch ? 'Вкл' : 'Выкл'}${prof.trusted_wifi ? ` &bull; Доверенные Wi-Fi: <span style="color:var(--md-sys-color-primary);">${prof.trusted_wifi}</span>` : ''}
      </p>
      <div class="m3-btn-group">
        <button class="m3-btn m3-btn-outlined m3-btn-sm" onclick="showProfileQr('${prof.name}')">QR-код</button>
        <button class="m3-btn m3-btn-tonal m3-btn-sm" onclick="editProfile('${prof.name}')">Настроить</button>
        <button class="m3-btn m3-btn-danger-outlined m3-btn-sm" onclick="deleteProfile('${prof.name}')">Удалить</button>
      </div>
    `;
    container.appendChild(item);
  });
}

// Toggle Profile
async function toggleProfile(name, enable) {
  showToast(enable ? `Запуск ${name}...` : `Остановка ${name}...`);
  const action = enable ? 'start' : 'stop';
  await sh(`/data/adb/modules/amneziawg-android/bin/awg-controller ${action} "${name}"`);
  await refreshAllData();
}

async function restartAll() {
  showToast('Перезапуск всех профилей...');
  await sh('/data/adb/modules/amneziawg-android/bin/awg-controller restart');
  await refreshAllData();
  showToast('Все профили перезапущены');
}

async function stopAll() {
  showToast('Остановка всех профилей...');
  await sh('/data/adb/modules/amneziawg-android/bin/awg-controller stop-all');
  await refreshAllData();
  showToast('Все туннели остановлены');
}

// Apps Loading via Native Package Manager
async function loadInstalledApps() {
  try {
    const res = await sh('pm list packages -U -3');
    if (res.stdout && res.stdout.includes('package:')) {
      const apps = [];
      const lines = res.stdout.trim().split('\n');
      for (const line of lines) {
        const match = line.match(/^package:([a-zA-Z0-9._]+)\s+uid:(\d+)/);
        if (match) {
          const pkg = match[1];
          const uid = parseInt(match[2], 10);
          const simpleName = pkg.split('.').pop();
          const capName = simpleName.charAt(0).toUpperCase() + simpleName.slice(1);
          apps.push({ package: pkg, name: capName, uid: uid, system: false });
        }
      }
      if (apps.length > 0) {
        STATE.installedApps = apps;
        return;
      }
    }
  } catch (e) {}

  if (STATE.installedApps.length === 0) {
    STATE.installedApps = [
      { package: 'org.telegram.messenger', name: 'Telegram', uid: 10469, system: false },
      { package: 'com.google.android.youtube', name: 'YouTube', uid: 10470, system: false },
      { package: 'com.openai.chatgpt', name: 'ChatGPT', uid: 10471, system: false },
      { package: 'com.anthropic.claude', name: 'Claude', uid: 10472, system: false },
      { package: 'com.spotify.music', name: 'Spotify', uid: 10473, system: false },
      { package: 'com.vkontakte.android', name: 'VK (ВКонтакте)', uid: 10474, system: false },
      { package: 'ru.yandex.music', name: 'Яндекс Музыка', uid: 10475, system: false },
      { package: 'ru.sberbankmobile', name: 'СберБанк', uid: 10476, system: false },
      { package: 'ru.ozon.app.android', name: 'OZON', uid: 10477, system: false },
      { package: 'com.android.chrome', name: 'Google Chrome', uid: 10001, system: true },
      { package: 'org.mozilla.firefox', name: 'Firefox', uid: 10478, system: false }
    ];
  }
}

// App Selection Rendering
function renderFilteredApps() {
  const container = document.getElementById('apps-selection-container');
  if (!container) return;
  container.innerHTML = '';

  let filtered = STATE.installedApps.filter(app => {
    if (STATE.searchQuery) {
      const matchName = app.name.toLowerCase().includes(STATE.searchQuery);
      const matchPkg = app.package.toLowerCase().includes(STATE.searchQuery);
      if (!matchName && !matchPkg) return false;
    }
    if (STATE.currentAppFilter === 'user') return !app.system;
    if (STATE.currentAppFilter === 'system') return app.system;
    if (STATE.currentAppFilter === 'selected') return STATE.selectedApps.has(app.package);
    return true;
  });

  if (filtered.length === 0) {
    container.innerHTML = '<div class="m3-apps-loading">Приложения не найдены</div>';
    return;
  }

  filtered.forEach(app => {
    const isChecked = STATE.selectedApps.has(app.package);
    const item = document.createElement('div');
    item.className = 'm3-app-item';
    item.innerHTML = `
      <input type="checkbox" ${isChecked ? 'checked' : ''} onchange="toggleAppSelection('${app.package}', this.checked)">
      <div style="flex: 1; min-width: 0;">
        <div class="m3-app-name">${escapeHtml(app.name)}</div>
        <div class="m3-app-pkg">${escapeHtml(app.package)} (UID: ${app.uid})</div>
      </div>
    `;
    item.onclick = (e) => {
      if (e.target.tagName !== 'INPUT') {
        const cb = item.querySelector('input[type="checkbox"]');
        cb.checked = !cb.checked;
        toggleAppSelection(app.package, cb.checked);
      }
    };
    container.appendChild(item);
  });

  renderSelectedChips();
}

function toggleAppSelection(pkg, isSelected) {
  if (isSelected) STATE.selectedApps.add(pkg);
  else STATE.selectedApps.delete(pkg);
  renderSelectedChips();
}

function renderSelectedChips() {
  const countEl = document.getElementById('selected-apps-count');
  if (countEl) countEl.innerText = STATE.selectedApps.size;

  const box = document.getElementById('selected-chips-box');
  if (!box) return;
  box.innerHTML = '';

  STATE.selectedApps.forEach(pkg => {
    const appObj = STATE.installedApps.find(a => a.package === pkg);
    const name = appObj ? appObj.name : pkg;
    const tag = document.createElement('span');
    tag.className = 'm3-app-tag';
    tag.innerHTML = `
      <span>${escapeHtml(name)}</span>
      <span class="m3-app-tag-del" onclick="toggleAppSelection('${pkg}', false); renderFilteredApps();">&times;</span>
    `;
    box.appendChild(tag);
  });
}

function selectAllVisibleApps() {
  const container = document.getElementById('apps-selection-container');
  if (!container) return;
  container.querySelectorAll('input[type="checkbox"]').forEach(cb => {
    cb.checked = true;
  });
  STATE.installedApps.forEach(a => {
    if (STATE.searchQuery) {
      if (a.name.toLowerCase().includes(STATE.searchQuery) || a.package.toLowerCase().includes(STATE.searchQuery)) {
        STATE.selectedApps.add(a.package);
      }
    } else {
      STATE.selectedApps.add(a.package);
    }
  });
  renderSelectedChips();
}

function deselectAllApps() {
  STATE.selectedApps.clear();
  renderFilteredApps();
}

// Profile Modal Actions
async function openProfileModal(name) {
  STATE.editingProfileName = name;
  const modal = document.getElementById('modal-profile');
  const title = document.getElementById('modal-title');
  const nameInput = document.getElementById('prof-name');
  const autostartInput = document.getElementById('prof-autostart');
  const killswitchInput = document.getElementById('prof-killswitch');
  const modeSelect = document.getElementById('prof-mode');
  const dnsInput = document.getElementById('prof-dns');
  const rawTextarea = document.getElementById('prof-conf-raw');

  STATE.selectedApps.clear();

  if (name) {
    title.innerText = `Редактирование: ${name}`;
    nameInput.value = name;
    nameInput.disabled = true;

    const resJson = await sh(`cat /data/adb/amneziawg/profiles/${name}.json 2>/dev/null`);
    try {
      const data = JSON.parse(resJson.stdout || '{}');
      autostartInput.checked = data.enabled !== false;
      killswitchInput.checked = !!data.killswitch;
      modeSelect.value = data.routing_mode || 'include_apps';
      dnsInput.value = data.custom_dns || '';
      if (data.apps && Array.isArray(data.apps)) {
        data.apps.forEach(p => STATE.selectedApps.add(p));
      }
    } catch (e) {}

    const resConf = await sh(`cat /data/adb/amneziawg/profiles/${name}.conf 2>/dev/null`);
    rawTextarea.value = resConf.stdout || '';
  } else {
    title.innerText = 'Новый профиль AWG';
    nameInput.value = '';
    nameInput.disabled = false;
    autostartInput.checked = true;
    killswitchInput.checked = false;
    modeSelect.value = 'include_apps';
    dnsInput.value = '';
    const trustedInput = document.getElementById('prof-trusted-wifi');
    if (trustedInput) trustedInput.value = '';
    rawTextarea.value = '';
  }

  const groupApps = document.getElementById('group-apps');
  if (groupApps) groupApps.style.display = (modeSelect.value === 'all_traffic') ? 'none' : 'block';

  renderFilteredApps();
  modal.style.display = 'flex';
}

function closeProfileModal() {
  document.getElementById('modal-profile').style.display = 'none';
}

function autoFillProfileName(suggested) {
  const nameInput = document.getElementById('prof-name');
  if (!nameInput.value.trim() && suggested) {
    nameInput.value = suggested.toLowerCase().replace(/[^a-z0-9_]/g, '_');
  }
}

async function saveProfile() {
  const name = document.getElementById('prof-name').value.trim();
  const autostart = document.getElementById('prof-autostart').checked;
  const killswitch = document.getElementById('prof-killswitch').checked;
  const mode = document.getElementById('prof-mode').value;
  const dns = document.getElementById('prof-dns').value.trim();
  const trustedWifi = document.getElementById('prof-trusted-wifi') ? document.getElementById('prof-trusted-wifi').value.trim() : '';
  const rawConf = document.getElementById('prof-conf-raw').value.trim();

  if (!name) {
    showToast('Введите имя профиля!');
    return;
  }
  if (!rawConf) {
    showToast('Введите конфигурацию AWG .conf!');
    return;
  }

  const payload = {
    name: name,
    enabled: autostart,
    killswitch: killswitch,
    routing_mode: mode,
    custom_dns: dns,
    trusted_wifi: trustedWifi,
    apps: Array.from(STATE.selectedApps)
  };

  const jsonStr = JSON.stringify(payload, null, 2);
  const escJson = jsonStr.replace(/'/g, "'\\''");
  const escConf = rawConf.replace(/'/g, "'\\''");

  await sh(`
    mkdir -p /data/adb/amneziawg/profiles
    echo '${escConf}' > /data/adb/amneziawg/profiles/${name}.conf
    echo '${escJson}' > /data/adb/amneziawg/profiles/${name}.json
    chmod 600 /data/adb/amneziawg/profiles/${name}.conf /data/adb/amneziawg/profiles/${name}.json
  `);

  closeProfileModal();
  showToast(`Профиль "${name}" сохранен!`);
  await refreshAllData();
}

async function editProfile(name) {
  openProfileModal(name);
}

async function deleteProfile(name) {
  if (!confirm(`Удалить профиль "${name}"?`)) return;
  showToast(`Удаление ${name}...`);
  STATE.profiles = STATE.profiles.filter(p => p.name !== name);
  renderDashboard();
  renderProfilesList();
  updateSystemSummary();

  await sh(`/data/adb/modules/amneziawg-android/bin/awg-controller stop "${name}" 2>/dev/null; rm -f /data/adb/amneziawg/profiles/${name}*`);
  await refreshAllData();
  showToast(`Профиль "${name}" удален`);
}

// QR Image Decoder
function handleQrImageFile(e) {
  const file = e.target.files[0];
  if (!file) return;

  const reader = new FileReader();
  reader.onload = (evt) => {
    const img = new Image();
    img.onload = () => {
      const canvas = document.createElement('canvas');
      canvas.width = img.width;
      canvas.height = img.height;
      const ctx = canvas.getContext('2d');
      ctx.drawImage(img, 0, 0, img.width, img.height);
      const imageData = ctx.getImageData(0, 0, canvas.width, canvas.height);

      if (typeof jsQR !== 'undefined') {
        const code = jsQR(imageData.data, imageData.width, imageData.height);
        if (code && code.data) {
          handleQrDecodedText(code.data);
        } else {
          showToast('QR-код на изображении не найден!');
        }
      } else {
        showToast('Библиотека jsQR не загружена.');
      }
    };
    img.src = evt.target.result;
  };
  reader.readAsDataURL(file);
}

function handleQrDecodedText(text) {
  text = text.trim();
  if (!text) return;

  const modalProf = document.getElementById('modal-profile');
  if (modalProf.style.display === 'none') {
    openProfileModal(null);
  }

  document.getElementById('prof-conf-raw').value = text;
  autoFillProfileName('qr_imported');
  showToast('Конфигурация импортирована из QR-кода!');
}

// QR Code Viewer
async function showProfileQr(name) {
  const modal = document.getElementById('modal-qr-view');
  const title = document.getElementById('qr-view-title');
  const container = document.getElementById('qr-view-container');

  title.innerText = `QR-код: ${name}`;
  container.innerHTML = '';

  const res = await sh(`cat /data/adb/amneziawg/profiles/${name}.conf 2>/dev/null`);
  const confText = (res.stdout || '').trim();

  if (!confText) {
    showToast('Конфигурационный файл пуст.');
    return;
  }

  STATE.activeViewConf = confText;

  if (typeof QRCode !== 'undefined') {
    new QRCode(container, {
      text: confText,
      width: 240,
      height: 240,
      colorDark: "#000000",
      colorLight: "#ffffff",
      correctLevel: QRCode.CorrectLevel.M
    });
  } else {
    container.innerHTML = '<p style="color:#000;">QRCode библиотека не найдена</p>';
  }

  modal.style.display = 'flex';
}

function closeQrViewModal() {
  document.getElementById('modal-qr-view').style.display = 'none';
}

function copyActiveConf() {
  if (STATE.activeViewConf) {
    copyText(STATE.activeViewConf, 'Конфигурация скопирована в буфер!');
  }
}

// Diagnostics & Logs
async function loadLogs() {
  const viewer = document.getElementById('log-viewer');
  if (!viewer) return;
  viewer.innerText = 'Загрузка журнала...';
  const res = await sh('tail -n 100 /data/adb/amneziawg/logs/awg-controller.log 2>/dev/null || echo "Лог пуст."');
  viewer.innerText = res.stdout || 'Лог пуст.';
}

async function runPingTest() {
  const out = document.getElementById('tools-output');
  out.style.display = 'block';
  out.innerText = 'Выполнение проверки связи...';
  const res = await sh('ping -c 3 -W 1 1.1.1.1 || ping -c 3 -W 1 8.8.8.8');
  out.innerText = res.stdout || res.stderr;
}

async function runUAPIDump() {
  const out = document.getElementById('tools-output');
  out.style.display = 'block';
  out.innerText = 'Запрос UAPI данных...';
  const res = await sh('/data/adb/modules/amneziawg-android/bin/awg status');
  out.innerText = res.stdout || res.stderr;
}

async function runIPRulesDump() {
  const out = document.getElementById('tools-output');
  out.style.display = 'block';
  out.innerText = 'Получение таблицы IP правил...';
  const res = await sh('ip rule show; echo ""; ip route show table 200 2>/dev/null; ip route show table 201 2>/dev/null');
  out.innerText = res.stdout || res.stderr;
}

function escapeHtml(str) {
  return String(str).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

function formatBytes(bytes) {
  if (!bytes || bytes === 0) return '0 B';
  const k = 1024;
  const sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
  const i = Math.floor(Math.log(bytes) / Math.log(k));
  return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
}
