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

// Единая точка пути к контроллеру: раньше он был вписан строкой в каждый
// вызов, и любая правка требовала обхода полутора десятков мест.
const CTRL = '/data/adb/modules/amneziawg-android/bin/awg-controller';
const AWG_BIN = '/data/adb/modules/amneziawg-android/bin/awg';
// Согласовано с AWG_MAX_PROFILE_NAME в awg-controller.
const MAX_PROFILE_NAME = 22;

let asyncExecSeq = 0;
let isRefreshing = false;
let isActionRunning = false;
let lastProfilesSig = '';
let isLoadingApps = false;

function getKsuBridge() {
  return window.ksu || window.KernelSU || window.apatch || window.mmrl || window.magisk || (typeof ksu !== 'undefined' ? ksu : null);
}

// Таймауты выполнения команд.
// Прежняя редакция использовала единые 8 секунд на любую команду, тогда как
// запуск нескольких профилей штатно занимает дольше: ожидание сокета до 3 с
// на профиль плюс резолв эндпоинта и контрольный пинг. Команда успевала
// отработать, но интерфейс уже считал ее провалившейся.
const SH_TIMEOUT_FAST = 8000;
const SH_TIMEOUT_LONG = 60000;

// Android Root Shell Wrapper (Compatible with KernelSU / APatch / Magisk)
function sh(cmd, timeoutMs) {
  const k = getKsuBridge();
  if (!k || typeof k.exec !== 'function') {
    console.warn('[No Root Bridge]:', cmd);
    return Promise.resolve({ code: -1, stdout: '', stderr: 'Мост root-менеджера недоступен' });
  }

  return new Promise((resolve) => {
    const id = '__ksuCb_' + (++asyncExecSeq);
    let done = false;

    const timer = setTimeout(() => {
      if (done) return;
      done = true;
      delete window[id];
      delete window['window.' + id];
      resolve({ code: -1, stdout: '', stderr: 'Превышено время выполнения команды' });
    }, timeoutMs || SH_TIMEOUT_FAST);

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
  sh(`am start -a android.intent.action.VIEW -d "${url}" 2>/dev/null`); // глушение-обосновано: отсутствие подходящего приложения для ссылки не является сбоем модуля
}

function openChannel() {
  openUrl('https://t.me/module_ecubz');
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
  if (tabName === 'groups') {
    // Список профилей нужен для выбора участников, список приложений - для
    // выбора приложений группы: оба подгружаются при открытии вкладки.
    refreshAllData().then(loadInstalledApps).then(refreshGroupsTab);
  }
}

function on(id, evt, handler) {
  const el = document.getElementById(id);
  if (el) el.addEventListener(evt, handler);
}

// Async Initialization Loop (Waits for KernelSU / APatch / Magisk Bridge)
async function initWebUI() {
  let attempts = 0;
  while (!getKsuBridge() && attempts < 25) {
    await new Promise(r => setTimeout(r, 100));
    attempts++;
  }

  initEventHandlers();

  const bridge = getKsuBridge();
  if (!bridge || typeof bridge.exec !== 'function') {
    console.warn('[Root Bridge not detected after waiting]');
    const dash = document.getElementById('dashboard-cards');
    if (dash) {
      dash.innerHTML = '<div class="m3-card"><div class="m3-card-body" style="color:var(--md-sys-color-error);"><p><strong>[warning] Мост root-менеджера не обнаружен</strong></p><p style="font-size:12px;margin-top:6px;color:var(--md-sys-color-on-surface-variant);">WebUI ожидает мост KernelSU / APatch / Magisk (ksu/KernelSU/mmrl/magisk). Убедитесь, что модуль ksuwebui активен и приложению предоставлен root-доступ.</p></div></div>';
    }
  }

  try {
    await refreshAllData();
  } catch (err) {
    console.error('refreshAllData error:', err);
  }

  // Периодический опрос каждые 4 секунды с защитой от наложения и блокировок
  setInterval(async () => {
    if (isRefreshing || isActionRunning) return;
    if (STATE.activeTab === 'main' || STATE.activeTab === 'profiles') {
      isRefreshing = true;
      try {
        await loadProfiles();
        await loadStatus();
        renderDashboard();
        renderProfilesList();
        updateSystemSummary();
      } catch (err) {
        console.error('Periodic refresh error:', err);
      } finally {
        isRefreshing = false;
      }
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
  on('btn-add-group', 'click', () => openGroupModal(null));
  on('btn-check-groups', 'click', checkGroups);
  on('btn-group-save', 'click', saveGroup);
  on('btn-group-cancel', 'click', closeGroupModal);
  on('btn-group-modal-close', 'click', closeGroupModal);
  on('grp-app-search', 'input', (e) => {
    GROUPS_STATE.search = e.target.value || '';
    renderGroupApps();
  });

  const triggerQrImport = () => {
    const inp = document.getElementById('qr-file-input');
    if (inp) inp.click();
  };

  on('btn-add-profile-qr', 'click', triggerQrImport);
  on('btn-scan-qr-modal', 'click', triggerQrImport);
  on('qr-file-input', 'change', handleQrImageFile);
  on('qr-file-picker', 'change', handleQrImageFile);
  on('btn-qr-scanner-close', 'click', stopLiveQrScanner);

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
        const rawText = evt.target.result || '';
        const rawEl = document.getElementById('prof-conf-raw');
        if (rawEl) rawEl.value = rawText;
        autoFillProfileName(file.name.replace(/\.[^/.]+$/, ""));
        parseConfigDirectives(rawText);
        showToast('Конфигурация загружена');
      };
      reader.readAsText(file);
    }
  });

  // Автоматический парсинг директив при вставке конфига в текстовое поле
  on('prof-conf-raw', 'input', (e) => {
    parseConfigDirectives(e.target.value);
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
  if (isRefreshing || isActionRunning) return;
  isRefreshing = true;
  try {
    await loadProfiles();
    await loadStatus();
    renderDashboard();
    renderProfilesList();
    updateSystemSummary();
  } finally {
    isRefreshing = false;
  }
}

async function loadProfiles() {
  const combinedCmd = CTRL + ' check-conflicts; echo "___AWG_DELIM___"; for f in /data/adb/amneziawg/run/*.paused; do [ -f "$f" ] && echo "$(basename "$f" .paused)=$(cat "$f")"; done; echo "___AWG_DELIM___"; for f in /data/adb/amneziawg/run/*.failed; do [ -f "$f" ] && basename "$f" .failed; done';
  const res = await sh(combinedCmd);
  const parts = (res.stdout || '').split('___AWG_DELIM___');
  const confRaw = (parts[0] || '').trim();
  const pausedRaw = (parts[1] || '').trim();
  const failedRaw = (parts[2] || '').trim();

  try {
    let raw = confRaw;
    const match = raw.match(/\{[\s\S]*"profiles"[\s\S]*\}/);
    if (match) raw = match[0];
    const data = JSON.parse(raw);
    STATE.profiles = Array.isArray(data.profiles) ? data.profiles : [];
  } catch (e) {
    // При ошибке парсинга сохраняем текущие профили
  }

  const pausedMap = {};
  pausedRaw.split('\n').forEach(line => {
    if (!line) return;
    const p = line.split('=');
    if (p[0]) pausedMap[p[0]] = p[1] || 'Wi-Fi';
  });

  const failedSet = new Set(failedRaw.split('\n').filter(Boolean));

  STATE.profiles.forEach(p => {
    p.paused_ssid = pausedMap[p.name] || null;
    p.is_failed = failedSet.has(p.name);
  });
}

async function loadStatus() {
  const env = 'WG_UAPI_DIR=/data/adb/amneziawg/run AMNEZIAWG_UAPI_DIR=/data/adb/amneziawg/run';
  let res = await sh(`${env} ${AWG_BIN} status json`);
  if (!res.stdout || !res.stdout.trim().startsWith('[')) {
    res = await sh(`${CTRL} status json`);
  }
  try {
    let raw = (res.stdout || '').trim();
    const match = raw.match(/\[[\s\S]*\]/);
    if (match) raw = match[0];
    const parsed = JSON.parse(raw);
    STATE.activeTunnels = Array.isArray(parsed) ? parsed : [];
  } catch (e) {
    STATE.activeTunnels = [];
  }
}

function updateSystemSummary() {
  const tunnels = Array.isArray(STATE.activeTunnels) ? STATE.activeTunnels : [];
  const profiles = Array.isArray(STATE.profiles) ? STATE.profiles : [];
  const activeCount = profiles.filter(p => !p.paused_ssid && tunnels.some(t => 
    (t.profile_name && t.profile_name === p.name) || 
    (p.interface && t.interface === p.interface) ||
    (t.interface && t.interface === (p.interface || ''))
  )).length;
  const activeEl = document.getElementById('val-active-cnt');
  if (activeEl) activeEl.innerText = activeCount;
  const totalEl = document.getElementById('val-total-cnt');
  if (totalEl) totalEl.innerText = profiles.length;
}

// Render Dashboard Cards (точечное обновление без тотального уничтожения DOM)
function renderDashboard() {
  const container = document.getElementById('dashboard-cards');
  if (!container) return;

  const tunnels = Array.isArray(STATE.activeTunnels) ? STATE.activeTunnels : [];
  const profiles = Array.isArray(STATE.profiles) ? STATE.profiles : [];

  if (profiles.length === 0) {
    container.innerHTML = '<div class="m3-card"><div class="m3-card-body"><p style="color:var(--md-sys-color-on-surface-variant);font-size:13px;">Профили загружаются или еще не созданы. Перейдите во вкладку "Профили" для добавления.</p></div></div>';
    return;
  }

  // Удаляем плейсхолдер пустого списка, если он есть
  const placeholder = container.querySelector('.m3-card');
  if (placeholder && !placeholder.id) {
    container.innerHTML = '';
  }

  // Набор актуальных профилей для очистки удаленных
  const profNames = new Set(profiles.map(p => p.name));
  Array.from(container.children).forEach(child => {
    if (child.id && child.id.startsWith('dash-card-')) {
      const pName = child.id.substring('dash-card-'.length);
      if (!profNames.has(pName)) {
        child.remove();
      }
    }
  });

  profiles.forEach(prof => {
    const tunnel = tunnels.find(t => 
      (t.profile_name && t.profile_name === prof.name) || 
      (prof.interface && t.interface === prof.interface) ||
      (t.interface && t.interface === (prof.interface || ''))
    ) || null;
    const isUp = !!tunnel;
    const peer = (tunnel && tunnel.peers && tunnel.peers[0]) || null;

    const isPaused = !!prof.paused_ssid;
    const isFailed = !isUp && !isPaused && !!prof.is_failed;

    let badgeHtml = '<span class="m3-badge m3-badge-idle">Отключен</span>';
    if (isPaused) {
      badgeHtml = `<span class="m3-badge" style="background:rgba(255,180,0,0.15);color:#ffb400;border:1px solid rgba(255,180,0,0.3);">Спит (${escapeHtml(prof.paused_ssid)})</span>`;
    } else if (isUp && peer) {
      const rxBytes = peer.rx_bytes || 0;
      const txBytes = peer.tx_bytes || 0;
      const hsAge = (peer.last_handshake_ago_sec !== undefined ? peer.last_handshake_ago_sec : (peer.last_handshake_time_sec || 0));

      if (rxBytes > 500) {
        badgeHtml = '<span class="m3-badge m3-badge-success">Связь подтверждена</span>';
      } else if (txBytes > 2048 && rxBytes <= 150) {
        badgeHtml = '<span class="m3-badge" style="background:rgba(255,82,82,0.15);color:#ff5252;border:1px solid rgba(255,82,82,0.3);">Блок данных (DPI)</span>';
      } else if (hsAge > 0 && rxBytes > 0) {
        badgeHtml = '<span class="m3-badge" style="background:rgba(0,180,216,0.15);color:#00b4d8;border:1px solid rgba(0,180,216,0.3);">Хендшейк OK (Ожидание)</span>';
      } else {
        badgeHtml = '<span class="m3-badge m3-badge-idle">Ожидание хендшейка</span>';
      }
    } else if (isUp) {
      badgeHtml = '<span class="m3-badge m3-badge-success">Подключен</span>';
    } else if (isFailed) {
      badgeHtml = '<span class="m3-badge" style="background:rgba(255,82,82,0.15);color:#ff5252;border:1px solid rgba(255,82,82,0.3);">Сбой Watchdog</span>';
    }

    const cardId = 'dash-card-' + prof.name;
    let card = document.getElementById(cardId);
    const cardClass = `m3-profile-card ${isPaused ? 'paused' : (isUp ? 'active' : (isFailed ? 'failed' : ''))}`;

    if (card) {
      if (card.className !== cardClass) card.className = cardClass;
      const badgeBox = card.querySelector('.m3-profile-title-box');
      if (badgeBox) {
        const nameSpan = badgeBox.querySelector('.m3-profile-name');
        badgeBox.innerHTML = '';
        if (nameSpan) badgeBox.appendChild(nameSpan);
        badgeBox.insertAdjacentHTML('beforeend', badgeHtml);
      }
      const sw = card.querySelector('input[type="checkbox"]');
      if (sw && sw.checked !== (isUp || isPaused)) {
        sw.checked = (isUp || isPaused);
      }
      const epEl = card.querySelector('.stat-endpoint');
      if (epEl) epEl.innerText = (peer && peer.endpoint ? peer.endpoint : 'Ожидание');
      const trEl = card.querySelector('.stat-traffic');
      if (trEl) trEl.innerText = (peer ? formatBytes(peer.rx_bytes) + ' / ' + formatBytes(peer.tx_bytes) : '0 B / 0 B');
    } else {
      card = document.createElement('div');
      card.id = cardId;
      card.className = cardClass;
      card.innerHTML = `
        <div class="m3-profile-header">
          <div class="m3-profile-title-box">
            <span class="m3-profile-name">${escapeHtml(prof.name)}</span>
            ${badgeHtml}
          </div>
          <label class="m3-switch">
            <input type="checkbox" ${(isUp || isPaused) ? 'checked' : ''} onchange="toggleProfile('${prof.name}', this.checked)">
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
            <span class="stat-endpoint">${peer && peer.endpoint ? escapeHtml(peer.endpoint) : 'Ожидание'}</span>
          </div>
          <div class="m3-stat-item">
            <span>Трафик (RX/TX)</span>
            <span class="stat-traffic">${peer ? formatBytes(peer.rx_bytes) + ' / ' + formatBytes(peer.tx_bytes) : '0 B / 0 B'}</span>
          </div>
        </div>

        <div class="m3-btn-group">
          ${isFailed ? `<button class="m3-btn m3-btn-tonal m3-btn-sm" style="background:rgba(255,82,82,0.15);color:#ff5252;" onclick="resetProfileFailure('${escapeAttr(prof.name)}')">Сбросить сбой</button>` : ''}
          <button class="m3-btn m3-btn-outlined m3-btn-sm" onclick="showProfileQr('${escapeAttr(prof.name)}')"><svg class="g-icon g-icon-sm" viewBox="0 0 24 24"><path fill="currentColor" d="M3 5v4h2V5h4V3H5c-1.1 0-2 .9-2 2zm2 10H3v4c0 1.1.9 2 2 2h4v-2H5v-4zm14 4h-4v2h4c1.1 0 2-.9 2-2v-4h-2v4zm0-16h-4v2h4v4h2V5c0-1.1-.9-2-2-2z"/></svg> QR-код</button>
          <button class="m3-btn m3-btn-tonal m3-btn-sm" onclick="editProfile('${escapeAttr(prof.name)}')"><svg class="g-icon g-icon-sm" viewBox="0 0 24 24"><path fill="currentColor" d="M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25zM20.71 7.04c.39-.39.39-1.02 0-1.41l-2.34-2.34c-.39-.39-1.02-.39-1.41 0l-1.83 1.83 3.75 3.75 1.83-1.83z"/></svg> Настроить</button>
        </div>
      `;
      container.appendChild(card);
    }
  });
}

// Render Profiles List in Tab 2 (только при фактическом изменении конфигурации)
function renderProfilesList() {
  const container = document.getElementById('profiles-list');
  if (!container) return;

  const curSig = JSON.stringify(STATE.profiles.map(p => ({
    name: p.name,
    enabled: p.enabled,
    mode: p.routing_mode,
    appsCount: p.apps ? p.apps.length : 0,
    ks: p.killswitch,
    lan: p.lan_bypass,
    tw: p.trusted_wifi,
    failed: p.is_failed
  })));
  if (curSig === lastProfilesSig && container.children.length > 0) {
    return;
  }
  lastProfilesSig = curSig;

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
        KillSwitch: ${prof.killswitch ? 'Вкл' : 'Выкл'}${prof.lan_bypass === false ? ' &bull; LAN: Маршрутизировать' : ''}${prof.trusted_wifi ? ` &bull; Доверенные Wi-Fi: <span style="color:var(--md-sys-color-primary);">${escapeHtml(prof.trusted_wifi)}</span>` : ''}
      </p>
      <div class="m3-btn-group">
        ${prof.is_failed ? `<button class="m3-btn m3-btn-tonal m3-btn-sm" style="background:rgba(255,82,82,0.15);color:#ff5252;" onclick="resetProfileFailure('${escapeAttr(prof.name)}')">Сбросить сбой</button>` : ''}
        <button class="m3-btn m3-btn-outlined m3-btn-sm" onclick="showProfileQr('${escapeAttr(prof.name)}')">QR-код</button>
        <button class="m3-btn m3-btn-tonal m3-btn-sm" onclick="editProfile('${escapeAttr(prof.name)}')">Настроить</button>
        <button class="m3-btn m3-btn-danger-outlined m3-btn-sm" onclick="deleteProfile('${escapeAttr(prof.name)}')">Удалить</button>
      </div>
    `;
    container.appendChild(item);
  });
}

async function resetProfileFailure(name) {
  if (isActionRunning) return;
  isActionRunning = true;
  showToast(`Сброс сбоя watchdog для ${name}...`);
  try {
    await sh(`${CTRL} reset-failures "${name}"`);
    const res = await sh(`${CTRL} start "${name}"`, SH_TIMEOUT_LONG);
    if (res.code !== 0) {
      showToast(`Запуск не выполнен: ${res.stderr || 'код ' + res.code}`);
    }
    await loadProfiles();
    await loadStatus();
    renderDashboard();
    renderProfilesList();
    updateSystemSummary();
    showToast(`Профиль "${name}" перезапущен`);
  } catch (err) {
    showToast(`Ошибка: ${err}`);
  } finally {
    isActionRunning = false;
  }
}

// Toggle Profile с защитой от одновременных вызовов
async function toggleProfile(name, enable) {
  if (isActionRunning) return;
  isActionRunning = true;
  showToast(enable ? `Включение ${name}...` : `Отключение ${name}...`);
  const action = enable ? 'enable' : 'disable';
  try {
    const res = await sh(`${CTRL} ${action} "${name}"`, SH_TIMEOUT_LONG);
    if (res.code !== 0) {
      showToast(`Команда ${action} завершилась с ошибкой: ${res.stderr || 'код ' + res.code}`);
    }
    await loadProfiles();
    await loadStatus();
    renderDashboard();
    renderProfilesList();
    updateSystemSummary();
  } catch (err) {
    showToast(`Ошибка переключения: ${err}`);
  } finally {
    isActionRunning = false;
  }
}

async function restartAll() {
  if (isActionRunning) return;
  isActionRunning = true;
  showToast('Перезапуск всех профилей...');
  try {
    const res = await sh(`${CTRL} restart`, SH_TIMEOUT_LONG);
    await loadProfiles();
    await loadStatus();
    renderDashboard();
    renderProfilesList();
    updateSystemSummary();
    showToast(res.code === 0 ? 'Все профили перезапущены'
                             : `Перезапуск завершился с ошибкой: ${res.stderr || 'код ' + res.code}`);
  } catch (err) {
    showToast(`Ошибка перезапуска: ${err}`);
  } finally {
    isActionRunning = false;
  }
}

async function stopAll() {
  if (isActionRunning) return;
  isActionRunning = true;
  showToast('Остановка всех профилей...');
  try {
    const res = await sh(`${CTRL} stop all`, SH_TIMEOUT_LONG);
    await loadProfiles();
    await loadStatus();
    renderDashboard();
    renderProfilesList();
    updateSystemSummary();
    showToast(res.code === 0 ? 'Все туннели остановлены'
                             : `Остановка завершилась с ошибкой: ${res.stderr || 'код ' + res.code}`);
  } catch (err) {
    showToast(`Ошибка остановки: ${err}`);
  } finally {
    isActionRunning = false;
  }
}

const KNOWN_APPS = {
  'org.telegram.messenger': 'Telegram',
  'org.telegram.plus': 'Telegram Plus',
  'org.thunderdog.challegram': 'Telegram X',
  'com.exteragram.messenger': 'exteraGram',
  'org.telegram.messenger.web': 'Telegram Web',
  'com.vkontakte.android': 'ВКонтакте (VK)',
  'com.google.android.youtube': 'YouTube',
  'com.google.android.apps.youtube.music': 'YouTube Music',
  'com.openai.chatgpt': 'ChatGPT',
  'com.anthropic.claude': 'Claude',
  'com.spotify.music': 'Spotify',
  'ru.yandex.music': 'Яндекс Музыка',
  'ru.sberbankmobile': 'СберБанк',
  'ru.tinkoff.mobile.bank': 'Т-Банк (Тинькофф)',
  'com.idamob.tinkoff.android': 'Т-Банк',
  'com.vtb24.mobilebanking.android': 'ВТБ',
  'ru.alfabank.mobile.android': 'Альфа-Банк',
  'ru.ozon.app.android': 'OZON',
  'com.wildberries.work': 'Wildberries WB',
  'com.wildberries.wbclient': 'Wildberries',
  'ru.yandex.searchplugin': 'Яндекс Старт',
  'com.yandex.browser': 'Яндекс Браузер',
  'com.android.chrome': 'Google Chrome',
  'org.mozilla.firefox': 'Firefox',
  'com.brave.browser': 'Brave Browser',
  'com.opera.browser': 'Opera',
  'com.opera.gx': 'Opera GX',
  'com.microsoft.emmx': 'Microsoft Edge',
  'com.whatsapp': 'WhatsApp',
  'com.whatsapp.w4b': 'WhatsApp Business',
  'com.viber.voip': 'Viber',
  'com.instagram.android': 'Instagram',
  'com.facebook.katana': 'Facebook',
  'com.twitter.android': 'Twitter / X',
  'com.zhiliaoapp.musically': 'TikTok',
  'com.discord': 'Discord',
  'com.valvesoftware.android.steam.community': 'Steam',
  'com.kinopoisk': 'Кинопоиск',
  'ru.rutube.app': 'Rutube',
  'ru.yandex.disk': 'Яндекс Диск',
  'ru.yandex.market': 'Яндекс Маркет',
  'ru.yandex.taxi': 'Яндекс Go',
  'ru.yandex.yandexnavi': 'Яндекс Навигатор',
  'ru.yandex.yandexmaps': 'Яндекс Карты',
  'com.hsv.freeviewer': 'MX Player',
  'org.videolan.vlc': 'VLC',
  'ru.gosuslugi.gostech': 'Госуслуги',
  'ru.rostel.gosuslugi': 'Госуслуги',
  'com.cbr.investor': 'ЦБ РФ',
  'com.avito.android': 'Авито',
  'com.duolingo': 'Duolingo',
  'com.reddit.frontpage': 'Reddit',
  'com.speedtest.android': 'Speedtest',
  'com.github.android': 'GitHub',
  'org.torproject.torbrowser': 'Tor Browser'
};

function formatAppLabel(pkg) {
  if (KNOWN_APPS[pkg]) return KNOWN_APPS[pkg];
  const parts = pkg.split('.');
  if (parts.length === 0) return pkg;
  let namePart = parts[parts.length - 1];
  const junk = new Set(['android', 'app', 'client', 'mobile', 'messenger', 'lite', 'beta', 'main', 'phone']);
  if (junk.has(namePart.toLowerCase()) && parts.length > 1) {
    namePart = parts[parts.length - 2];
  }
  if (junk.has(namePart.toLowerCase()) && parts.length > 2) {
    namePart = parts[parts.length - 3];
  }
  if (!namePart) namePart = pkg;
  return namePart.charAt(0).toUpperCase() + namePart.slice(1);
}

// Apps Loading via Native Package Manager & CLI
async function loadInstalledApps() {
  if (isLoadingApps) return;
  if (STATE.installedApps && STATE.installedApps.length > 0) return;
  isLoadingApps = true;
  try {
    try {
      const cliRes = await sh(`${CTRL} list-apps`);
    if (cliRes.stdout && cliRes.stdout.trim().startsWith('[')) {
      const parsed = JSON.parse(cliRes.stdout.trim());
      if (Array.isArray(parsed) && parsed.length > 0) {
        STATE.installedApps = parsed.map(it => ({
          package: it.package,
          name: KNOWN_APPS[it.package] || it.name || formatAppLabel(it.package),
          uid: it.uid,
          system: !!it.system
        }));
        return;
      }
    }
  } catch (err) {
    console.warn('Список приложений через awg-controller недоступен:', err);
  }

  try {
    const res = await sh('pm list packages -U -3; pm list packages -U -s');
    if (res.stdout && res.stdout.includes('package:')) {
      const apps = [];
      const seen = new Set();
      const lines = res.stdout.trim().split('\n');
      for (const line of lines) {
        const match = line.match(/^package:([a-zA-Z0-9._]+)\s+uid:(\d+)/);
        if (match) {
          const pkg = match[1];
          if (seen.has(pkg)) continue;
          seen.add(pkg);
          const uid = parseInt(match[2], 10);
          const isSys = uid < 10000 || pkg.startsWith('com.android.') || pkg.startsWith('com.google.android.gms');
          apps.push({
            package: pkg,
            name: formatAppLabel(pkg),
            uid: uid,
            system: isSys
          });
        }
      }
      if (apps.length > 0) {
        apps.sort((a, b) => a.name.localeCompare(b.name, 'ru'));
        STATE.installedApps = apps;
        return;
      }
    }
  } catch (err) {
    console.warn('Разбор вывода pm list packages не удался:', err);
  }

  if (STATE.installedApps.length === 0) {
    STATE.installedApps = [
      { package: 'org.telegram.messenger', name: 'Telegram', uid: 10469, system: false },
      { package: 'com.google.android.youtube', name: 'YouTube', uid: 10470, system: false },
      { package: 'com.openai.chatgpt', name: 'ChatGPT', uid: 10471, system: false },
      { package: 'com.anthropic.claude', name: 'Claude', uid: 10472, system: false },
      { package: 'com.spotify.music', name: 'Spotify', uid: 10473, system: false },
      { package: 'com.vkontakte.android', name: 'ВКонтакте (VK)', uid: 10474, system: false },
      { package: 'ru.yandex.music', name: 'Яндекс Музыка', uid: 10475, system: false },
      { package: 'ru.sberbankmobile', name: 'СберБанк', uid: 10476, system: false },
      { package: 'ru.ozon.app.android', name: 'OZON', uid: 10477, system: false },
      { package: 'com.android.chrome', name: 'Google Chrome', uid: 10001, system: true },
      { package: 'org.mozilla.firefox', name: 'Firefox', uid: 10478, system: false }
    ];
  }
  } finally {
    isLoadingApps = false;
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

async function insertCurrentWifiSsid() {
  try {
    const res = await sh(`${CTRL} get-current-ssid`);
    const ssid = (res.stdout || '').trim();
    if (!ssid) {
      showToast('Wi-Fi не подключен или имя сети не определено');
      return;
    }
    const input = document.getElementById('prof-trusted-wifi');
    if (!input) return;
    const currentVal = input.value.trim();
    if (!currentVal) {
      input.value = ssid;
    } else {
      const list = currentVal.split(',').map(s => s.trim());
      if (!list.includes(ssid)) {
        input.value = currentVal + ', ' + ssid;
      }
    }
    showToast(`Сеть "${ssid}" добавлена`);
  } catch (e) {
    showToast('Ошибка определения сети');
  }
}

// Profile Modal Actions
async function openProfileModal(name) {
  STATE.editingProfileName = name;
  const modal = document.getElementById('modal-profile');
  const title = document.getElementById('modal-title');
  const nameInput = document.getElementById('prof-name');
  const autostartInput = document.getElementById('prof-autostart');
  const killswitchInput = document.getElementById('prof-killswitch');
  const lanBypassInput = document.getElementById('prof-lan-bypass');
  const modeSelect = document.getElementById('prof-mode');
  const dnsInput = document.getElementById('prof-dns');
  const trustedInput = document.getElementById('prof-trusted-wifi');
  const rawTextarea = document.getElementById('prof-conf-raw');

  STATE.selectedApps.clear();

  if (name) {
    title.innerText = `Редактирование: ${name}`;
    nameInput.value = name;
    nameInput.disabled = false;

    const resJson = await sh(`cat /data/adb/amneziawg/profiles/${name}.json 2>/dev/null`); // глушение-обосновано: у нового профиля файла опций еще нет, случай обработан ниже
    try {
      const data = JSON.parse(resJson.stdout || '{}');
      autostartInput.checked = data.enabled !== false;
      killswitchInput.checked = !!data.killswitch;
      if (lanBypassInput) lanBypassInput.checked = data.lan_bypass !== false;
      modeSelect.value = data.routing_mode || 'include_apps';
      dnsInput.value = data.custom_dns || '';
      if (trustedInput) trustedInput.value = data.trusted_wifi || '';
      if (data.apps && Array.isArray(data.apps)) {
        data.apps.forEach(p => STATE.selectedApps.add(p));
      }
    } catch (err) {
      showToast('Профиль сохранен в поврежденном формате JSON, поля не заполнены');
      console.error('Разбор JSON профиля не удался:', err);
    }

    const resConf = await sh(`cat /data/adb/amneziawg/profiles/${name}.conf 2>/dev/null`); // глушение-обосновано: у нового профиля конфигурации еще нет, случай обработан ниже
    rawTextarea.value = resConf.stdout || '';
  } else {
    title.innerText = 'Новый профиль AWG';
    nameInput.value = '';
    nameInput.disabled = false;
    autostartInput.checked = true;
    killswitchInput.checked = false;
    if (lanBypassInput) lanBypassInput.checked = true;
    modeSelect.value = 'include_apps';
    dnsInput.value = '';
    if (trustedInput) trustedInput.value = '';
    rawTextarea.value = '';
  }

  const groupApps = document.getElementById('group-apps');
  if (groupApps) groupApps.style.display = (modeSelect.value === 'all_traffic') ? 'none' : 'block';

  modal.style.display = 'flex';

  if (!STATE.installedApps || STATE.installedApps.length === 0) {
    const appsBox = document.getElementById('apps-selection-container');
    if (appsBox) appsBox.innerHTML = '<div class="m3-apps-loading">Загрузка списка приложений...</div>';
    loadInstalledApps().then(() => {
      renderFilteredApps();
    });
  } else {
    renderFilteredApps();
  }
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
  const lanBypass = document.getElementById('prof-lan-bypass') ? document.getElementById('prof-lan-bypass').checked : true;
  const mode = document.getElementById('prof-mode').value;
  const dns = document.getElementById('prof-dns').value.trim();
  const trustedWifi = document.getElementById('prof-trusted-wifi') ? document.getElementById('prof-trusted-wifi').value.trim() : '';
  const rawConf = document.getElementById('prof-conf-raw').value.trim();

  if (!name) {
    showToast('Введите имя профиля!');
    return;
  }
  if (!/^[a-zA-Z0-9_-]+$/.test(name)) {
    showToast('Имя профиля может содержать только латинские буквы, цифры, _ и -');
    return;
  }
  // Предел имени цепочки iptables - 28 символов, префикс "AWG_M_" занимает 6.
  // Более длинное имя приводило к молчаливому отказу создания цепочки и к
  // профилю без единого правила маршрутизации.
  if (name.length > MAX_PROFILE_NAME) {
    showToast('Имя профиля не длиннее ' + MAX_PROFILE_NAME + ' символов');
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
    lan_bypass: lanBypass,
    routing_mode: mode,
    custom_dns: dns,
    trusted_wifi: trustedWifi,
    apps: Array.from(STATE.selectedApps)
  };

  const jsonStr = JSON.stringify(payload, null, 2);
  const escJson = jsonStr.replace(/'/g, "'\\''");
  const escConf = rawConf.replace(/'/g, "'\\''");

  const oldName = STATE.editingProfileName;
  const isRename = !!(oldName && oldName !== name);

  if (isRename) {
    showToast(`Переименование ${oldName} -> ${name}...`);
    // Удаление выполняет контроллер по точному списку файлов профиля.
    const del = await sh(`${CTRL} delete "${oldName}"`, SH_TIMEOUT_LONG);
    if (del.code !== 0) {
      showToast(`Не удалось удалить старый профиль: ${del.stderr || 'код ' + del.code}`);
      return;
    }
  }

  const res = await sh(`
    set -e
    mkdir -p /data/adb/amneziawg/profiles
    umask 077
    printf '%s
' '${escConf}' > /data/adb/amneziawg/profiles/${name}.conf
    printf '%s
' '${escJson}' > /data/adb/amneziawg/profiles/${name}.json
    chmod 600 /data/adb/amneziawg/profiles/${name}.conf /data/adb/amneziawg/profiles/${name}.json
    if [ -f "/data/adb/amneziawg/run/${name}.iface" ] || [ "${isRename ? '1' : '0'}" = "1" ]; then
      ${CTRL} restart "${name}"
    else
      ${CTRL} sync-rules
    fi
  `, SH_TIMEOUT_LONG);

  if (res.code !== 0) {
    showToast(`Сохранение завершилось с ошибкой: ${res.stderr || 'код ' + res.code}`);
    await refreshAllData();
    return;
  }

  STATE.editingProfileName = null;
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

  // Удаление делает контроллер по точному списку файлов профиля.
  // Прежняя редакция выполняла здесь rm -f по шаблону ${name}* - без точки
  // перед расширением, из-за чего удаление профиля "wg" уносило вместе с ним
  // "wg2" и любой другой профиль с тем же началом имени вместе с ключами.
  const res = await sh(`${CTRL} delete "${name}"`, SH_TIMEOUT_LONG);
  await refreshAllData();
  if (res.code === 0) {
    showToast(`Профиль "${name}" удален`);
  } else {
    showToast(`Удаление не выполнено: ${res.stderr || 'код ' + res.code}`);
  }
}

// QR Image Decoder
// Журнал WebUI на устройстве: без него шаги импорта не видны снаружи
function qrLog(msg) {
  try {
    const line = String(msg).replace(/'/g, "");
    sh(`echo "$(date '+%Y-%m-%d %H:%M:%S') [WEBUI] ${line}" >> /data/adb/amneziawg/logs/webui.log`);
  } catch (e) { /* журнал не критичен */ }
}

// Многопроходное распознавание QR.
// Снимок с камеры имеет полное разрешение матрицы, и getImageData на таком
// холсте в WebView часто отдает пустые данные, поэтому кадр масштабируется.
function decodeQrFromImage(img) {
  const W = img.naturalWidth || img.width;
  const H = img.naturalHeight || img.height;
  if (!W || !H) return { text: null, info: 'изображение не загрузилось' };

  const trace = [];
  const attempt = (dw, dh, sx, sy, sw, sh, tag) => {
    let data;
    try {
      const canvas = document.createElement('canvas');
      canvas.width = dw;
      canvas.height = dh;
      const ctx = canvas.getContext('2d', { willReadFrequently: true });
      if (!ctx) { trace.push(`${tag}:нет-контекста`); return null; }
      ctx.drawImage(img, sx, sy, sw, sh, 0, 0, dw, dh);
      data = ctx.getImageData(0, 0, dw, dh);
    } catch (err) {
      trace.push(`${tag}:исключение`);
      return null;
    }
    if (!data || !data.data || !data.data.length) { trace.push(`${tag}:пусто`); return null; }
    // Средняя яркость по выборке: нули означают, что холст не отрисовался,
    // а не отсутствие кода на снимке. Это разные причины отказа.
    let sum = 0, n = 0;
    for (let i = 0; i < data.data.length; i += 4 * 997) { sum += data.data[i]; n++; }
    const lum = n ? Math.round(sum / n) : -1;
    for (const inv of ['dontInvert', 'attemptBoth']) {
      const code = jsQR(data.data, data.width, data.height, { inversionAttempts: inv });
      if (code && code.data) { trace.push(`${tag}:НАЙДЕН`); return code.data; }
    }
    trace.push(`${tag}:нет(яркость ${lum})`);
    return null;
  };

  const fit = (sx, sy, sw, sh, target, tag) => {
    const scale = Math.min(1, target / Math.max(sw, sh));
    return attempt(Math.max(1, Math.round(sw * scale)), Math.max(1, Math.round(sh * scale)), sx, sy, sw, sh, tag);
  };

  // 1. Кадр целиком в нескольких масштабах
  for (const target of [1024, 1600, 2048]) {
    const text = fit(0, 0, W, H, target, String(target));
    if (text) return { text: text, info: `кадр целиком, масштаб ${target}` };
  }

  // 2. Центральная область: QR чаще всего наводят в середину
  const cw = Math.round(W * 0.6);
  const ch = Math.round(H * 0.6);
  const centerText = fit(Math.round((W - cw) / 2), Math.round((H - ch) / 2), cw, ch, 1400, 'центр');
  if (centerText) return { text: centerText, info: 'центральная область кадра' };

  // 3. Разбор по перекрывающимся плиткам.
  // На снимке 3072x4096 код занимает малую часть кадра, и при сжатии всего
  // кадра до 1024 px его модули становятся меньше пикселя. Плитки сохраняют
  // исходную детализацию участка.
  for (const grid of [2, 3]) {
    const tw = Math.round(W / grid);
    const th = Math.round(H / grid);
    const stepX = Math.round(tw / 2);
    const stepY = Math.round(th / 2);
    for (let gy = 0; gy + th <= H + stepY; gy += stepY) {
      for (let gx = 0; gx + tw <= W + stepX; gx += stepX) {
        const sx = Math.min(gx, Math.max(0, W - tw));
        const sy = Math.min(gy, Math.max(0, H - th));
        const text = fit(sx, sy, tw, th, 1000, `п${grid}`);
        if (text) return { text: text, info: `плитка ${grid}x${grid}` };
      }
    }
  }

  // Трасса длинная: в журнал идет сводка, а не каждая плитка
  const found = {};
  for (const t of trace) {
    const k = t.split(':')[0];
    found[k] = (found[k] || 0) + 1;
  }
  const summary = Object.keys(found).map(k => `${k}x${found[k]}`).join(' ');
  const lum = trace.filter(t => t.indexOf('яркость') >= 0).slice(0, 3).join(' ');
  return { text: null, info: `${W}x${H}; проходов ${trace.length} (${summary}); ${lum}` };
}

function decodeQrFromSource(src, onDone) {
  if (typeof jsQR === 'undefined') {
    showToast('Библиотека jsQR не загружена.');
    if (onDone) onDone();
    return;
  }
  const img = new Image();
  img.onload = () => {
    const res = decodeQrFromImage(img);
    qrLog(`decode ${img.naturalWidth}x${img.naturalHeight} -> ${res.text ? 'найден, ' + res.text.length + ' символов' : 'НЕ найден: ' + res.info}`);
    if (res.text) {
      handleQrDecodedText(res.text);
    } else {
      showToast(`QR-код не распознан (${res.info})`);
    }
    if (onDone) onDone(!!res.text);
  };
  img.onerror = () => {
    qrLog('decode: изображение не загрузилось в WebView');
    showToast('Не удалось открыть изображение.');
    if (onDone) onDone(false);
  };
  img.src = src;
}

// ==========================================
// QR Scanner Engine (BarcodeDetector + jsQR)
// ==========================================
let qrMediaStream = null;
let qrScanAnimFrame = null;
let barcodeDetectorInstance = undefined;

function getBarcodeDetector() {
  if (barcodeDetectorInstance !== undefined) return barcodeDetectorInstance;
  if ('BarcodeDetector' in window) {
    try {
      barcodeDetectorInstance = new BarcodeDetector({ formats: ['qr_code'] });
    } catch (e) {
      barcodeDetectorInstance = null;
    }
  } else {
    barcodeDetectorInstance = null;
  }
  return barcodeDetectorInstance;
}

// Открытие сканера камеры
async function openLiveQrScanner() {
  const modal = document.getElementById('modal-qr-scanner');
  const video = document.getElementById('qr-video');
  const errBox = document.getElementById('qr-camera-error');
  const targetBox = document.getElementById('qr-target-box');

  if (modal) modal.style.display = 'flex';
  if (errBox) errBox.style.display = 'none';
  if (targetBox) targetBox.style.display = 'block';

  try {
    if (navigator.mediaDevices && navigator.mediaDevices.getUserMedia) {
      qrMediaStream = await navigator.mediaDevices.getUserMedia({
        video: {
          facingMode: { ideal: 'environment' },
          width: { ideal: 1280 },
          height: { ideal: 720 }
        },
        audio: false
      });
      if (video) {
        video.srcObject = qrMediaStream;
        await video.play();
        startLiveScanningLoop();
      }
    } else {
      throw new Error('getUserMedia not supported in WebView');
    }
  } catch (err) {
    qrLog('camera error: ' + err.message);
    if (errBox) errBox.style.display = 'block';
    if (targetBox) targetBox.style.display = 'none';
  }
}

function stopLiveQrScanner() {
  if (qrScanAnimFrame) {
    cancelAnimationFrame(qrScanAnimFrame);
    qrScanAnimFrame = null;
  }
  if (qrMediaStream) {
    try {
      qrMediaStream.getTracks().forEach(t => t.stop());
    } catch (err) {
      console.warn('Остановка потока камеры вернула ошибку:', err);
    }
    qrMediaStream = null;
  }
  const video = document.getElementById('qr-video');
  if (video) {
    video.srcObject = null;
  }
  const modal = document.getElementById('modal-qr-scanner');
  if (modal) modal.style.display = 'none';
}

function startLiveScanningLoop() {
  const video = document.getElementById('qr-video');
  if (!video || !qrMediaStream) return;

  const canvas = document.createElement('canvas');
  const ctx = canvas.getContext('2d', { willReadFrequently: true });

  const scanFrame = async () => {
    if (!qrMediaStream || video.readyState < 2) {
      qrScanAnimFrame = requestAnimationFrame(scanFrame);
      return;
    }

    try {
      let codeText = null;

      // 1. Нативный аппаратный BarcodeDetector
      const detector = getBarcodeDetector();
      if (detector) {
        const barcodes = await detector.detect(video);
        if (barcodes && barcodes.length > 0 && barcodes[0].rawValue) {
          codeText = barcodes[0].rawValue;
        }
      }

      // 2. jsQR через canvas
      if (!codeText && typeof jsQR !== 'undefined') {
        canvas.width = Math.min(640, video.videoWidth || 640);
        canvas.height = Math.min(480, video.videoHeight || 480);
        ctx.drawImage(video, 0, 0, canvas.width, canvas.height);
        const imgData = ctx.getImageData(0, 0, canvas.width, canvas.height);
        const code = jsQR(imgData.data, canvas.width, canvas.height, { inversionAttempts: 'dontInvert' });
        if (code && code.data) {
          codeText = code.data;
        }
      }

      if (codeText) {
        if (navigator.vibrate) navigator.vibrate(50);
        stopLiveQrScanner();
        handleQrDecodedText(codeText);
        return;
      }
    } catch (err) {
      // Кадр не разобран: это штатная ситуация для видеопотока, следующий
      // кадр запрашивается ниже. В журнал пишется только первый случай.
      if (!scanFrame.errorLogged) {
        scanFrame.errorLogged = true;
        console.warn('Кадр сканера не разобран:', err);
      }
    }

    qrScanAnimFrame = requestAnimationFrame(scanFrame);
  };

  qrScanAnimFrame = requestAnimationFrame(scanFrame);
}

// Загрузка фото из галереи или проводника
async function handleQrImageFile(e) {
  const input = e.target;
  const file = input.files && input.files[0];
  const reset = () => {
    try {
      input.value = '';
    } catch (err) {
      console.warn('Сброс поля выбора файла не удался:', err);
    }
  };
  if (!file) { reset(); return; }

  showToast('Анализ изображения...');
  const reader = new FileReader();
  reader.onload = async (evt) => {
    const img = new Image();
    img.onload = async () => {
      let text = null;
      const detector = getBarcodeDetector();
      if (detector) {
        try {
          const barcodes = await detector.detect(img);
          if (barcodes && barcodes.length > 0 && barcodes[0].rawValue) {
            text = barcodes[0].rawValue;
          }
        } catch (err) {
          qrLog('BarcodeDetector не справился, переход к jsQR: ' + err);
        }
      }

      if (!text) {
        const res = decodeQrFromImage(img);
        if (res && res.text) text = res.text;
      }

      reset();
      stopLiveQrScanner();

      if (text) {
        handleQrDecodedText(text);
      } else {
        showToast('QR-код на фото не распознан. Попробуйте другой ракурс.');
      }
    };
    img.onerror = () => {
      reset();
      showToast('Не удалось открыть фото');
    };
    img.src = evt.target.result;
  };
  reader.readAsDataURL(file);
}

function parseConfigDirectives(rawText) {
  if (!rawText) return;
  const lines = rawText.split('\n');
  let included = null;
  let excluded = null;
  let dns = null;

  for (let line of lines) {
    line = line.trim();
    if (line.startsWith('#') || line.startsWith(';')) continue;
    const parts = line.split('=');
    if (parts.length >= 2) {
      const key = parts[0].trim().toLowerCase();
      const val = parts.slice(1).join('=').trim();
      if (key === 'includedapplications') {
        included = val.split(',').map(s => s.trim()).filter(Boolean);
      } else if (key === 'excludedapplications') {
        excluded = val.split(',').map(s => s.trim()).filter(Boolean);
      } else if (key === 'dns') {
        dns = val.split(',').map(s => s.trim()).filter(Boolean).join(', ');
      }
    }
  }

  if (included && included.length > 0) {
    const modeEl = document.getElementById('prof-mode');
    if (modeEl) modeEl.value = 'include_apps';
    STATE.selectedApps = new Set(included);
    renderSelectedChips();
    renderFilteredApps();
    const groupApps = document.getElementById('group-apps');
    if (groupApps) groupApps.style.display = 'block';
  } else if (excluded && excluded.length > 0) {
    const modeEl = document.getElementById('prof-mode');
    if (modeEl) modeEl.value = 'exclude_apps';
    STATE.selectedApps = new Set(excluded);
    renderSelectedChips();
    renderFilteredApps();
    const groupApps = document.getElementById('group-apps');
    if (groupApps) groupApps.style.display = 'block';
  }

  if (dns) {
    const dnsEl = document.getElementById('prof-dns');
    if (dnsEl && !dnsEl.value) {
      dnsEl.value = dns;
    }
  }
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
  parseConfigDirectives(text);
  showToast('Конфигурация импортирована из QR-кода!');
}

// QR Code Viewer
async function showProfileQr(name) {
  const modal = document.getElementById('modal-qr-view');
  const title = document.getElementById('qr-view-title');
  const container = document.getElementById('qr-view-container');

  title.innerText = `QR-код: ${name}`;
  container.innerHTML = '';

  const res = await sh(`cat /data/adb/amneziawg/profiles/${name}.conf 2>/dev/null`); // глушение-обосновано: пустой вывод обрабатывается как отсутствие конфигурации для QR
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
  const res = await sh('tail -n 100 /data/adb/amneziawg/logs/awg-controller.log 2>/dev/null || echo "Лог пуст."'); // глушение-обосновано: до первого запуска журнала не существует, подставляется текст-заглушка
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
  const res = await sh(`${AWG_BIN} status`);
  out.innerText = res.stdout || res.stderr;
}

async function runIPRulesDump() {
  const out = document.getElementById('tools-output');
  out.style.display = 'block';
  out.innerText = 'Получение таблицы IP правил...';
  const res = await sh('ip rule show; echo ""; ip route show table 201 2>/dev/null; ip route show table 202 2>/dev/null'); // глушение-обосновано: незанятая таблица маршрутизации выводит пустой список, это штатное состояние
  out.innerText = res.stdout || res.stderr;
}

// ============================================================
// Группы резервирования
// ============================================================
//
// Отображение и редактирование групп. Переключение между туннелями выполняет
// ядро по правилам с разными приоритетами, поэтому интерфейс не управляет
// выбором активного участника: он показывает, кто им стал, и позволяет
// снять или вернуть маршрут вручную.

const GROUPS_STATE = {
  groups: [],
  editing: null,
  members: [],
  selectedApps: new Set(),
  search: ''
};

async function loadGroupsState() {
  const res = await sh(`${CTRL} group-state`);
  try {
    const raw = (res.stdout || '').trim();
    const match = raw.match(/\[[\s\S]*\]/);
    GROUPS_STATE.groups = match ? JSON.parse(match[0]) : [];
  } catch (err) {
    GROUPS_STATE.groups = [];
    console.warn('Разбор состояния групп не удался:', err);
  }
}

function memberBadge(m) {
  if (!m.running) return '<span class="m3-badge m3-badge-idle">Не запущен</span>';
  if (m.route_down) return '<span class="m3-badge m3-badge-warn">Маршрут снят</span>';
  if (m.active) return '<span class="m3-badge m3-badge-success">Принимает трафик</span>';
  return '<span class="m3-badge m3-badge-idle">В резерве</span>';
}

function renderGroups() {
  const container = document.getElementById('groups-list');
  if (!container) return;
  container.innerHTML = '';

  if (!GROUPS_STATE.groups.length) {
    container.innerHTML = '<div class="m3-card"><div class="m3-card-body">'
      + '<p style="color:var(--md-sys-color-on-surface-variant);font-size:13px;">'
      + 'Групп нет. Группа нужна, когда одно приложение должно переключаться '
      + 'между несколькими туннелями при блокировке эндпоинта. Для одного '
      + 'туннеля группа не требуется.</p></div></div>';
    return;
  }

  GROUPS_STATE.groups.forEach(g => {
    const card = document.createElement('div');
    card.className = 'm3-profile-card';
    const rows = g.members.map(m => `
      <div class="m3-member-row">
        <span class="m3-member-rank">${m.rank + 1}</span>
        <span class="m3-member-name">${escapeHtml(m.name)}</span>
        ${memberBadge(m)}
        <button class="m3-btn m3-btn-outlined m3-btn-sm"
          onclick="toggleMemberRoute('${escapeAttr(m.name)}', ${m.route_down ? 'false' : 'true'})">
          ${m.route_down ? 'Вернуть' : 'Снять'}
        </button>
      </div>`).join('');

    card.innerHTML = `
      <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:8px;">
        <span class="m3-profile-name">${escapeHtml(g.name)}</span>
        <span class="m3-badge ${g.killswitch ? 'm3-badge-warn' : 'm3-badge-idle'}">
          ${g.killswitch ? 'KillSwitch' : 'Прямой канал'}
        </span>
      </div>
      <p style="font-size:12px;color:var(--md-sys-color-on-surface-variant);margin-bottom:10px;">
        Приложений: ${g.apps ? g.apps.length : 0} &bull;
        DNS: ${g.dns ? escapeHtml(g.dns) : 'по умолчанию'} &bull;
        Возврат: ${g.failback_after_sec > 0 ? g.failback_after_sec + ' с' : 'отключен'}
      </p>
      <div class="m3-members-list">${rows}</div>
      <div class="m3-btn-group" style="margin-top:10px;">
        <button class="m3-btn m3-btn-tonal m3-btn-sm" onclick="openGroupModal('${escapeAttr(g.name)}')">Настроить</button>
        <button class="m3-btn m3-btn-danger-outlined m3-btn-sm" onclick="deleteGroup('${escapeAttr(g.name)}')">Удалить</button>
      </div>`;
    container.appendChild(card);
  });
}

// Ручное снятие и возврат маршрута участника.
async function toggleMemberRoute(name, down) {
  if (isActionRunning) return;
  isActionRunning = true;
  showToast(down ? `Снятие маршрута ${name}...` : `Возврат маршрута ${name}...`);
  try {
    const cmd = down ? 'route-down' : 'route-up';
    const res = await sh(`${CTRL} ${cmd} "${name}"`, SH_TIMEOUT_LONG);
    if (res.code !== 0) {
      showToast(`Команда ${cmd} завершилась с ошибкой: ${res.stderr || 'код ' + res.code}`);
    }
    await loadGroupsState();
    renderGroups();
  } finally {
    isActionRunning = false;
  }
}

// Чтение файла групп для редактирования.
async function readGroupsFile() {
  const res = await sh(`cat "$(${CTRL} group-file)" 2>/dev/null`); // глушение-обосновано: до создания первой группы файла не существует, пустой вывод обрабатывается ниже
  const raw = (res.stdout || '').trim();
  if (!raw) return [];
  try {
    return JSON.parse(raw);
  } catch (err) {
    showToast('Файл групп поврежден, будет перезаписан при сохранении');
    console.error('Разбор groups.json не удался:', err);
    return [];
  }
}

function openGroupModal(name) {
  GROUPS_STATE.editing = name || null;
  GROUPS_STATE.selectedApps = new Set();
  GROUPS_STATE.search = '';

  const profileNames = STATE.profiles.map(p => p.name);
  document.getElementById('modal-group-title').innerText =
    name ? `Группа "${name}"` : 'Новая группа';
  document.getElementById('grp-name').value = name || '';
  document.getElementById('grp-dns').value = '';
  document.getElementById('grp-failback').value = '600';
  document.getElementById('grp-killswitch').checked = false;
  document.getElementById('grp-lan-bypass').checked = true;

  const g = GROUPS_STATE.groups.find(x => x.name === name);
  if (g) {
    document.getElementById('grp-dns').value = g.dns || '';
    document.getElementById('grp-failback').value = String(g.failback_after_sec ?? 600);
    document.getElementById('grp-killswitch').checked = !!g.killswitch;
    document.getElementById('grp-lan-bypass').checked = g.lan_bypass !== false;
    (g.apps || []).forEach(a => GROUPS_STATE.selectedApps.add(a));
    // Участники группы идут первыми в своем порядке, остальные профили следом.
    const chosen = g.members.map(m => m.name);
    GROUPS_STATE.members = chosen
      .map(n => ({ name: n, checked: true }))
      .concat(profileNames.filter(n => !chosen.includes(n)).map(n => ({ name: n, checked: false })));
  } else {
    GROUPS_STATE.members = profileNames.map(n => ({ name: n, checked: false }));
  }

  renderGroupMembers();
  renderGroupApps();
  document.getElementById('modal-group').style.display = 'flex';
}

function closeGroupModal() {
  document.getElementById('modal-group').style.display = 'none';
  GROUPS_STATE.editing = null;
}

function renderGroupMembers() {
  const box = document.getElementById('grp-members');
  if (!box) return;
  box.innerHTML = '';
  GROUPS_STATE.members.forEach((m, idx) => {
    const row = document.createElement('div');
    row.className = 'm3-member-row';
    row.innerHTML = `
      <label class="m3-switch m3-switch-sm">
        <input type="checkbox" ${m.checked ? 'checked' : ''}
          onchange="setGroupMember(${idx}, this.checked)"><span class="m3-slider"></span>
      </label>
      <span class="m3-member-name">${escapeHtml(m.name)}</span>
      <button class="m3-btn m3-btn-outlined m3-btn-sm" ${idx === 0 ? 'disabled' : ''}
        onclick="moveGroupMember(${idx}, -1)">Выше</button>
      <button class="m3-btn m3-btn-outlined m3-btn-sm" ${idx === GROUPS_STATE.members.length - 1 ? 'disabled' : ''}
        onclick="moveGroupMember(${idx}, 1)">Ниже</button>`;
    box.appendChild(row);
  });
}

function setGroupMember(idx, checked) {
  if (GROUPS_STATE.members[idx]) GROUPS_STATE.members[idx].checked = checked;
}

function moveGroupMember(idx, delta) {
  const to = idx + delta;
  const list = GROUPS_STATE.members;
  if (to < 0 || to >= list.length) return;
  const tmp = list[idx];
  list[idx] = list[to];
  list[to] = tmp;
  renderGroupMembers();
}

function renderGroupApps() {
  const chips = document.getElementById('grp-selected-chips');
  const list = document.getElementById('grp-apps-list');
  if (!chips || !list) return;

  chips.innerHTML = '';
  Array.from(GROUPS_STATE.selectedApps).forEach(pkg => {
    const app = STATE.installedApps.find(a => a.package === pkg);
    const tag = document.createElement('span');
    tag.className = 'm3-chip';
    tag.innerHTML = `${escapeHtml(app ? app.name : pkg)}
      <button class="m3-chip-x" onclick="toggleGroupApp('${escapeAttr(pkg)}')">x</button>`;
    chips.appendChild(tag);
  });

  const q = GROUPS_STATE.search.toLowerCase();
  const items = STATE.installedApps
    .filter(a => !q || a.name.toLowerCase().includes(q) || a.package.toLowerCase().includes(q))
    .slice(0, 120);
  list.innerHTML = '';
  if (!items.length) {
    list.innerHTML = '<div class="m3-apps-loading">Приложения не найдены</div>';
    return;
  }
  items.forEach(a => {
    const row = document.createElement('div');
    row.className = 'm3-app-row';
    row.innerHTML = `
      <label class="m3-switch m3-switch-sm">
        <input type="checkbox" ${GROUPS_STATE.selectedApps.has(a.package) ? 'checked' : ''}
          onchange="toggleGroupApp('${escapeAttr(a.package)}')"><span class="m3-slider"></span>
      </label>
      <span class="m3-app-name">${escapeHtml(a.name)}</span>
      <span class="m3-app-pkg">${escapeHtml(a.package)}</span>`;
    list.appendChild(row);
  });
}

function toggleGroupApp(pkg) {
  if (GROUPS_STATE.selectedApps.has(pkg)) {
    GROUPS_STATE.selectedApps.delete(pkg);
  } else {
    GROUPS_STATE.selectedApps.add(pkg);
  }
  renderGroupApps();
}

// Запись файла групп с откатом при неудачной проверке.
// Конфигурация с противоречиями (участник в двух группах, один участник,
// несуществующий профиль) не должна попадать на диск: она сломала бы
// маршрутизацию уже работающих профилей.
async function writeGroups(groups) {
  const json = JSON.stringify(groups, null, 2);
  const esc = json.replace(/'/g, "'\\''");
  const res = await sh(`
    set -e
    F="$(${CTRL} group-file)"
    umask 077
    [ -f "$F" ] && cp -f "$F" "$F.bak"
    printf '%s\\n' '${esc}' > "$F"
    chmod 600 "$F"
    if ! ${CTRL} group-check; then
      if [ -f "$F.bak" ]; then cp -f "$F.bak" "$F"; else rm -f "$F"; fi
      # Временная копия убирается и на пути отката: иначе она оставалась бы
      # в каталоге данных после каждой неудачной попытки сохранения.
      rm -f "$F.bak"
      echo "ОТКАТ: конфигурация групп не прошла проверку"
      exit 1
    fi
    rm -f "$F.bak"
    ${CTRL} sync-rules
  `, SH_TIMEOUT_LONG);
  return res;
}

async function saveGroup() {
  const name = document.getElementById('grp-name').value.trim();
  if (!name) { showToast('Введите имя группы'); return; }
  if (!/^[a-zA-Z0-9_-]+$/.test(name)) {
    showToast('Имя группы: только латиница, цифры, _ и -');
    return;
  }
  if (name.length > MAX_PROFILE_NAME) {
    showToast('Имя группы не длиннее ' + MAX_PROFILE_NAME + ' символов');
    return;
  }
  const members = GROUPS_STATE.members.filter(m => m.checked).map(m => m.name);
  if (members.length < 2) {
    showToast('В группе нужно не меньше двух участников, иначе резервировать нечем');
    return;
  }
  const apps = Array.from(GROUPS_STATE.selectedApps);
  if (!apps.length) { showToast('Выберите хотя бы одно приложение'); return; }

  const failback = parseInt(document.getElementById('grp-failback').value, 10);
  const entry = {
    name: name,
    apps: apps,
    members: members,
    dns: document.getElementById('grp-dns').value.trim(),
    failback_after_sec: isNaN(failback) ? 600 : Math.max(0, failback),
    killswitch: document.getElementById('grp-killswitch').checked,
    lan_bypass: document.getElementById('grp-lan-bypass').checked
  };

  const all = await readGroupsFile();
  const old = GROUPS_STATE.editing;
  const kept = all.filter(g => g.name !== name && g.name !== old);
  kept.push(entry);

  showToast('Сохранение группы...');
  const res = await writeGroups(kept);
  if (res.code !== 0) {
    showToast(`Не сохранено: ${(res.stdout || res.stderr || 'код ' + res.code).trim().split('\n').pop()}`);
    return;
  }
  closeGroupModal();
  showToast(`Группа "${name}" сохранена`);
  await refreshGroupsTab();
}

async function deleteGroup(name) {
  if (!confirm(`Удалить группу "${name}"? Приложения вернутся к правилам своих профилей.`)) return;
  const all = await readGroupsFile();
  const res = await writeGroups(all.filter(g => g.name !== name));
  if (res.code !== 0) {
    showToast(`Не удалено: ${(res.stdout || res.stderr || 'код ' + res.code).trim().split('\n').pop()}`);
    return;
  }
  showToast(`Группа "${name}" удалена`);
  await refreshGroupsTab();
}

async function checkGroups() {
  const res = await sh(`${CTRL} group-check`, SH_TIMEOUT_LONG);
  if (res.code === 0) {
    showToast((res.stdout || 'Противоречий не найдено').trim());
  } else {
    showToast('Найдены противоречия: ' + (res.stderr || res.stdout || '').trim().split('\n')[0]);
  }
}

async function refreshGroupsTab() {
  await loadGroupsState();
  renderGroups();
}

function escapeHtml(str) {
  return String(str).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

// Экранирование для подстановки в строковый литерал внутри атрибута onclick.
// Имена профилей приходят не только из формы WebUI, но и из имен файлов
// каталога профилей, поэтому проверка формата на входе не является гарантией.
function escapeAttr(str) {
  return escapeHtml(String(str).replace(/\\/g, '\\\\').replace(/'/g, "\\'"));
}

function formatBytes(bytes) {
  if (!bytes || bytes === 0) return '0 B';
  const k = 1024;
  const sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
  const i = Math.floor(Math.log(bytes) / Math.log(k));
  return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
}
