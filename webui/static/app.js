// chocoDeploy command builder
// Vanilla JS, no build step. Loaded by index.html.

const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));

const state = {
  catalog: null,
  inventories: [],
  selectedInventory: null,    // {path, groups, raw}
  selectedHostsForPing: new Set(),
  pingResults: {},
  mode: 'choco_conversion',
  apps: {
    mode: 'default',          // default | filter | skip
    selected: {},             // alias -> {checked: bool, min_version: str}
  },
  removals: {
    mode: 'default',          // default | filter | skip
    selected: {},             // alias -> bool
    adhoc: '',
  },
  runtimes: {},               // key -> { enabled, tracks: Set<string>, single_track:'', min_version:'', flags:{}, perTarget:{exclusive,floor_required,min_supported_track} }
  reboot: 'never',
  forks: '',
  tags: '',
  forceOrphan: {},            // key -> bool
  commonFlags: {},            // key -> bool
  extraRaw: '',
};

// Watch state for staleness detection
const watch = {
  lastSnapshot: 0,       // unix-ts the server gave us at last poll
  pollTimer: null,
  pollIntervalMs: 5000,  // 5s feels live without being noisy
  dismissedKey: '',      // user dismissed a specific change set; suppress until different
};

// ---------------------------------------------------------------------------
// boot
// ---------------------------------------------------------------------------

async function boot() {
  try {
    const r = await fetch('/api/catalog');
    if (!r.ok) throw new Error('catalog fetch ' + r.status);
    state.catalog = await r.json();
  } catch (e) {
    showFatal('Failed to load /api/catalog: ' + e.message);
    return;
  }

  initModePicker();
  initAppPicker();
  initRemovalPicker();
  initRuntimePicker();
  initFlagsBlock();
  initOutputControls();
  initSidebar();
  initTabs();
  populateStaticHelp();
  initCollapsibles();
  initRefresh();

  await refreshInventories();
  await pingHealth();
  await seedStalenessBaseline();
  startStalenessPolling();

  render();
}

// Fill all the data-step-desc and data-field-help slots from catalog.
function populateStaticHelp() {
  const c = state.catalog;
  for (const el of $$('[data-step-desc]')) {
    const key = el.dataset.stepDesc;
    el.textContent = (c.step_descriptions || {})[key] || '';
  }
  for (const el of $$('[data-field-help]')) {
    const key = el.dataset.fieldHelp;
    el.textContent = (c.field_help || {})[key] || '';
  }
}

function showFatal(msg) {
  $('#cmd-out').textContent = '[!] ' + msg;
}

// ---------------------------------------------------------------------------
// modes
// ---------------------------------------------------------------------------

function initModePicker() {
  const host = $('#mode-picker');
  host.innerHTML = '';
  for (const m of state.catalog.modes) {
    const card = document.createElement('div');
    card.className = 'mode-card';
    card.dataset.key = m.key;
    card.innerHTML = `
      <div class="mode-label">${escapeHtml(m.label)}</div>
      <div class="mode-key">${escapeHtml(m.key)}</div>
      <div class="mode-blurb">${escapeHtml(m.blurb)}</div>
    `;
    card.addEventListener('click', () => {
      state.mode = m.key;
      $$('.mode-card', host).forEach(c => c.classList.toggle('selected', c.dataset.key === m.key));
      renderModeDetail();
      render();
    });
    host.appendChild(card);
    if (m.key === state.mode) card.classList.add('selected');
  }
  renderModeDetail();
}

function renderModeDetail() {
  const el = $('#mode-detail');
  if (!el) return;
  const m = (state.catalog.modes || []).find(x => x.key === state.mode);
  if (!m || !m.details) { el.className = 'step-detail'; el.textContent = ''; return; }
  el.className = 'step-detail visible';
  el.innerHTML = `<strong>${escapeHtml(m.label)} (${escapeHtml(m.key)}):</strong> ${escapeHtml(m.details)}`;
}

// ---------------------------------------------------------------------------
// apps
// ---------------------------------------------------------------------------

function initAppPicker() {
  // mode radios (built from catalog)
  const radioHost = $('#apps-mode-radios');
  radioHost.innerHTML = '';
  for (const opt of state.catalog.apps_mode_options) {
    const row = document.createElement('label');
    row.className = 'radio-row' + (opt.key === state.apps.mode ? ' selected' : '');
    row.innerHTML = `
      <input type="radio" name="apps-mode" value="${opt.key}" ${opt.key === state.apps.mode ? 'checked' : ''}>
      <span class="radio-text">
        <span class="radio-label">${escapeHtml(opt.label)}</span>
        <span class="radio-desc">${escapeHtml(opt.desc)}</span>
      </span>
    `;
    radioHost.appendChild(row);
    $('input', row).addEventListener('change', () => {
      state.apps.mode = opt.key;
      $$('.radio-row', radioHost).forEach(r => r.classList.toggle('selected',
        $('input', r).value === opt.key));
      refreshAppCardEnabledness();
      render();
    });
  }

  // app cards
  const host = $('#app-picker');
  host.innerHTML = '';
  for (const app of state.catalog.apps) {
    const id = `app_${app.alias}`;
    const card = document.createElement('div');
    card.className = 'app-card';
    card.dataset.alias = app.alias;
    card.innerHTML = `
      <label class="cb-row">
        <input type="checkbox" id="${id}" data-alias="${app.alias}">
        <span>
          <span class="app-label">${escapeHtml(app.label)}</span>
          <span class="app-alias"> ${escapeHtml(app.alias)}</span><br>
          <span class="app-meta${app.requires_explicit_target ? ' explicit' : ''}">
            min ${escapeHtml(app.min_version)} | ${escapeHtml(app.install_size)}${app.requires_explicit_target ? ' | explicit-only' : ''}
          </span>
          ${app.description ? `<span class="app-desc">${escapeHtml(app.description)}</span>` : ''}
        </span>
      </label>
      <input type="text" class="mini" placeholder="ver override" data-alias-version="${app.alias}">
    `;
    host.appendChild(card);
    state.apps.selected[app.alias] = { checked: false, min_version: '' };

    $('input[type=checkbox]', card).addEventListener('change', (e) => {
      state.apps.selected[app.alias].checked = e.target.checked;
      if (e.target.checked && state.apps.mode !== 'filter') {
        state.apps.mode = 'filter';
        $$('input[name=apps-mode]').forEach(r => r.checked = (r.value === 'filter'));
        $$('#apps-mode-radios .radio-row').forEach(r => r.classList.toggle('selected',
          $('input', r).value === 'filter'));
        refreshAppCardEnabledness();
      }
      render();
    });
    $('input[type=text]', card).addEventListener('input', (e) => {
      state.apps.selected[app.alias].min_version = e.target.value.trim();
      render();
    });
  }

  refreshAppCardEnabledness();
}

function refreshAppCardEnabledness() {
  const filtering = state.apps.mode === 'filter';
  $$('.app-card', $('#app-picker')).forEach(card => {
    card.classList.toggle('disabled', !filtering);
  });
}

// ---------------------------------------------------------------------------
// removals
// ---------------------------------------------------------------------------

function initRemovalPicker() {
  // mode radios (built from catalog)
  const radioHost = $('#rm-mode-radios');
  radioHost.innerHTML = '';
  for (const opt of state.catalog.rm_mode_options) {
    const row = document.createElement('label');
    row.className = 'radio-row' + (opt.key === state.removals.mode ? ' selected' : '');
    row.innerHTML = `
      <input type="radio" name="rm-mode" value="${opt.key}" ${opt.key === state.removals.mode ? 'checked' : ''}>
      <span class="radio-text">
        <span class="radio-label">${escapeHtml(opt.label)}</span>
        <span class="radio-desc">${escapeHtml(opt.desc)}</span>
      </span>
    `;
    radioHost.appendChild(row);
    $('input', row).addEventListener('change', () => {
      state.removals.mode = opt.key;
      $$('.radio-row', radioHost).forEach(r => r.classList.toggle('selected',
        $('input', r).value === opt.key));
      refreshRmEnabledness();
      render();
    });
  }

  // removal cards
  const host = $('#rm-picker');
  host.innerHTML = '';
  for (const entry of state.catalog.removal_catalog) {
    const card = document.createElement('div');
    card.className = 'rm-card';
    card.dataset.alias = entry.alias;
    card.innerHTML = `
      <label>
        <input type="checkbox" data-rm-alias="${entry.alias}">
        <span class="rm-label">${escapeHtml(entry.label)}</span>
        <span class="app-alias"> ${escapeHtml(entry.alias)}</span>
        ${entry.description ? `<span class="app-desc">${escapeHtml(entry.description)}</span>` : ''}
      </label>
    `;
    host.appendChild(card);
    state.removals.selected[entry.alias] = false;
    $('input', card).addEventListener('change', e => {
      state.removals.selected[entry.alias] = e.target.checked;
      if (e.target.checked && state.removals.mode !== 'filter') {
        state.removals.mode = 'filter';
        $$('input[name=rm-mode]').forEach(r => r.checked = (r.value === 'filter'));
        $$('#rm-mode-radios .radio-row').forEach(r => r.classList.toggle('selected',
          $('input', r).value === 'filter'));
        refreshRmEnabledness();
      }
      render();
    });
  }

  $('#rm-adhoc').addEventListener('input', e => {
    state.removals.adhoc = e.target.value;
    if (e.target.value.trim() && state.removals.mode !== 'filter') {
      state.removals.mode = 'filter';
      $$('input[name=rm-mode]').forEach(r => r.checked = (r.value === 'filter'));
      $$('#rm-mode-radios .radio-row').forEach(r => r.classList.toggle('selected',
        $('input', r).value === 'filter'));
      refreshRmEnabledness();
    }
    render();
  });
  refreshRmEnabledness();
}

function refreshRmEnabledness() {
  const filtering = state.removals.mode === 'filter';
  $$('.rm-card', $('#rm-picker')).forEach(card => {
    card.classList.toggle('disabled', !filtering);
  });
  $('#rm-adhoc').disabled = !filtering;
}

// ---------------------------------------------------------------------------
// runtimes
// ---------------------------------------------------------------------------

function initRuntimePicker() {
  const host = $('#runtime-picker');
  host.innerHTML = '';
  const ptOpts = state.catalog.runtime_per_target_options || {};

  for (const rt of state.catalog.runtimes) {
    state.runtimes[rt.key] = {
      enabled: false,
      tracks: new Set(),
      single_track: '',
      min_version: '',
      flags: {},
      perTarget: {
        exclusive: false,
        floor_required: false,
        min_supported_track: '',
      },
    };

    const card = document.createElement('div');
    card.className = 'runtime-card';
    card.dataset.key = rt.key;

    const headHtml = `
      <div class="rt-head">
        <label><input type="checkbox" data-rt-enable="${rt.key}">
          <span class="rt-label">${escapeHtml(rt.label)}</span>
          <span class="rt-key">${escapeHtml(rt.key)}</span>
        </label>
      </div>
      ${rt.description ? `<div class="rt-desc">${escapeHtml(rt.description)}</div>` : ''}
    `;

    const bodyParts = [];

    if (rt.channels) {
      const chanList = rt.channels.map(t => {
        const cv = (rt.channel_min_versions || {})[t];
        return `<span class="track-chip" data-track="${t}" title="${cv ? 'min ' + escapeHtml(cv) : ''}">${t}</span>`;
      }).join('');
      bodyParts.push(`<div class="track-row">
        <span class="form-label" style="margin:0">Tracks:</span>
        ${chanList}
      </div>
      <div class="rt-pt-desc">Leave all unselected to auto-detect installed tracks based on the deployment mode. Default floor: <code>${escapeHtml(rt.default_min_supported_track || '')}</code>.</div>`);
    } else {
      bodyParts.push(`<div class="rt-inline">
        <label><input type="text" placeholder="min_version override (catalog default: ${escapeHtml(rt.min_version)})" data-rt-min="${rt.key}"></label>
      </div>`);
    }

    // per-target options (exclusive / floor_required / min_supported_track)
    if (rt.channels) {
      const ex = ptOpts.exclusive || {};
      const fl = ptOpts.floor_required || {};
      const mst = ptOpts.min_supported_track || {};
      bodyParts.push(`
        <div class="rt-flag-row">
          <label><input type="checkbox" data-rt-pt="${rt.key}" data-pt="exclusive"> <code>exclusive: true</code> -- ${escapeHtml(ex.label || '')}</label>
          ${ex.desc ? `<span class="rt-flag-desc">${escapeHtml(ex.desc)}</span>` : ''}
        </div>
        <div class="rt-flag-row">
          <label><input type="checkbox" data-rt-pt="${rt.key}" data-pt="floor_required"> <code>floor_required: true</code> -- ${escapeHtml(fl.label || '')}</label>
          ${fl.desc ? `<span class="rt-flag-desc">${escapeHtml(fl.desc)}</span>` : ''}
        </div>
        <div class="rt-inline">
          <label><code>min_supported_track:</code> <input type="text" placeholder="${escapeHtml(rt.default_min_supported_track || '')}" data-rt-pt-str="${rt.key}" data-pt="min_supported_track"></label>
        </div>
        ${mst.desc ? `<span class="rt-flag-desc">${escapeHtml(mst.desc)}</span>` : ''}
      `);
    }

    // per-runtime global flags (cleanup vendor, audit only, etc.)
    if (rt.flags && rt.flags.length) {
      bodyParts.push(rt.flags.map(f => `
        <div class="rt-flag-row">
          <label><input type="checkbox" data-rt-flag="${rt.key}" data-flag-key="${f.key}"> ${escapeHtml(f.label)} <code>${escapeHtml(f.key)}=true</code></label>
          ${f.desc ? `<span class="rt-flag-desc">${escapeHtml(f.desc)}</span>` : ''}
        </div>
      `).join(''));
    }

    card.innerHTML = headHtml + `<div class="rt-body">${bodyParts.join('')}</div>`;
    host.appendChild(card);

    // wire enable
    $('input[data-rt-enable]', card).addEventListener('change', e => {
      state.runtimes[rt.key].enabled = e.target.checked;
      card.classList.toggle('enabled', e.target.checked);
      render();
    });

    // wire track chips
    $$('.track-chip', card).forEach(chip => {
      chip.addEventListener('click', () => {
        const t = chip.dataset.track;
        const s = state.runtimes[rt.key].tracks;
        if (s.has(t)) s.delete(t); else s.add(t);
        chip.classList.toggle('selected', s.has(t));
        if (!state.runtimes[rt.key].enabled) {
          state.runtimes[rt.key].enabled = true;
          $('input[data-rt-enable]', card).checked = true;
          card.classList.add('enabled');
        }
        render();
      });
    });

    // wire min version (no-channel runtimes)
    const minEl = $(`input[data-rt-min="${rt.key}"]`, card);
    if (minEl) {
      minEl.addEventListener('input', e => {
        state.runtimes[rt.key].min_version = e.target.value.trim();
        render();
      });
    }

    // wire per-target bool/str
    $$(`input[data-rt-pt="${rt.key}"]`, card).forEach(cb => {
      cb.addEventListener('change', e => {
        state.runtimes[rt.key].perTarget[cb.dataset.pt] = e.target.checked;
        if (e.target.checked && !state.runtimes[rt.key].enabled) {
          state.runtimes[rt.key].enabled = true;
          $('input[data-rt-enable]', card).checked = true;
          card.classList.add('enabled');
        }
        render();
      });
    });
    $$(`input[data-rt-pt-str="${rt.key}"]`, card).forEach(input => {
      input.addEventListener('input', e => {
        state.runtimes[rt.key].perTarget[input.dataset.pt] = e.target.value.trim();
        render();
      });
    });

    // wire per-runtime flags
    $$(`input[data-rt-flag="${rt.key}"]`, card).forEach(cb => {
      cb.addEventListener('change', e => {
        state.runtimes[rt.key].flags[cb.dataset.flagKey] = e.target.checked;
        render();
      });
    });
  }
}

// ---------------------------------------------------------------------------
// flags
// ---------------------------------------------------------------------------

function initFlagsBlock() {
  const reboot = $('#reboot-policy');
  reboot.innerHTML = '';
  for (const p of state.catalog.reboot_policies) {
    const opt = document.createElement('option');
    opt.value = p.key;
    opt.textContent = p.label;
    reboot.appendChild(opt);
  }
  reboot.value = state.reboot;
  const renderRebootDetail = () => {
    const p = (state.catalog.reboot_policies || []).find(x => x.key === state.reboot);
    const el = $('#reboot-detail');
    if (el) el.textContent = p && p.desc ? p.desc : '';
  };
  renderRebootDetail();
  reboot.addEventListener('change', () => { state.reboot = reboot.value; renderRebootDetail(); render(); });

  const fo = $('#force-orphan-flags');
  fo.innerHTML = '';
  for (const f of state.catalog.force_orphan_flags) {
    const row = document.createElement('div');
    row.className = 'flag-row';
    row.innerHTML = `
      <label><input type="checkbox" data-fo="${f.key}"> <code>${escapeHtml(f.label)}</code></label>
      ${f.desc ? `<span class="flag-desc">${escapeHtml(f.desc)}</span>` : ''}
    `;
    fo.appendChild(row);
    state.forceOrphan[f.key] = false;
    $('input', row).addEventListener('change', e => {
      state.forceOrphan[f.key] = e.target.checked;
      render();
    });
  }

  const cf = $('#common-flags');
  cf.innerHTML = '';
  for (const f of state.catalog.common_flags) {
    const row = document.createElement('div');
    row.className = 'flag-row';
    row.innerHTML = `
      <label><input type="checkbox" data-cf="${f.key}"> <code>${escapeHtml(f.label)}</code></label>
      ${f.desc ? `<span class="flag-desc">${escapeHtml(f.desc)}</span>` : ''}
    `;
    cf.appendChild(row);
    state.commonFlags[f.key] = false;
    $('input', row).addEventListener('change', e => {
      state.commonFlags[f.key] = e.target.checked;
      render();
    });
  }

  $('#forks').addEventListener('input', e => { state.forks = e.target.value.trim(); render(); });
  $('#tags').addEventListener('input', e => { state.tags = e.target.value.trim(); render(); });
  $('#extra-vars-free').addEventListener('input', e => { state.extraRaw = e.target.value; render(); });
}

// ---------------------------------------------------------------------------
// output controls
// ---------------------------------------------------------------------------

function initOutputControls() {
  $('#multiline-toggle').addEventListener('change', render);

  $('#copy-cmd-btn').addEventListener('click', async () => {
    const { multiline } = renderInternal();
    await copyToClipboard(multiline, $('#copy-cmd-btn'));
  });
  $('#copy-cmd-1l-btn').addEventListener('click', async () => {
    const { single } = renderInternal();
    await copyToClipboard(single, $('#copy-cmd-1l-btn'));
  });

  $('#reset-btn').addEventListener('click', () => {
    if (confirm('Reset all builder fields?')) location.reload();
  });

  // Target inputs
  $('#inventory-path').addEventListener('input', render);
  $('#limit-pattern').addEventListener('input', render);
}

async function copyToClipboard(text, btn) {
  try {
    await navigator.clipboard.writeText(text);
    const original = btn.textContent;
    btn.classList.add('copied');
    btn.textContent = '[OK] Copied';
    setTimeout(() => {
      btn.classList.remove('copied');
      btn.textContent = original;
    }, 1200);
  } catch (e) {
    // Fallback: select the pre and let user copy with Ctrl-C
    const sel = window.getSelection();
    const range = document.createRange();
    range.selectNodeContents($('#cmd-out'));
    sel.removeAllRanges();
    sel.addRange(range);
    alert('Clipboard API unavailable. Command is selected -- press Ctrl-C.');
  }
}

// ---------------------------------------------------------------------------
// command rendering
// ---------------------------------------------------------------------------

function render() {
  const out = renderInternal();
  const multi = $('#multiline-toggle').checked;
  $('#cmd-out').textContent = multi ? out.multiline : out.single;

  // warnings
  const w = $('#cmd-warnings');
  w.innerHTML = '';
  for (const msg of out.warnings) {
    const div = document.createElement('div');
    div.className = 'warning' + (msg.level === 'error' ? ' error' : '');
    div.textContent = msg.text;
    w.appendChild(div);
  }
}

function renderInternal() {
  const c = state.catalog;
  const inv = $('#inventory-path').value.trim();
  const limit = $('#limit-pattern').value.trim();

  const warnings = [];
  if (!inv) warnings.push({ level: 'error', text: 'No inventory selected (-i). The command will not run.' });

  const parts = [
    'ansible-playbook',
    c.playbook,
  ];
  if (inv) parts.push('-i', inv);
  parts.push('--vault-password-file=' + c.vault_key);
  if (limit) parts.push('-l', shellQuote(limit));

  // mode
  parts.push('-e', `"deployment=${state.mode}"`);

  if (state.mode === 'report_only') {
    if (Object.values(state.runtimes).some(r => r.enabled)) {
      warnings.push({ text: 'report_only ignores targetRuntimes (no software changes are made).' });
    }
    if (state.apps.mode !== 'default' || state.removals.mode !== 'default') {
      warnings.push({ text: 'report_only ignores targetSoftware/removeSoftware (no software changes are made).' });
    }
  }

  // -------- targetSoftware / removeSoftware / targetRuntimes consolidated into one JSON -e --------
  const evObj = {};

  if (state.apps.mode === 'skip') {
    evObj.targetSoftware = [];
  } else if (state.apps.mode === 'filter') {
    const sw = [];
    for (const app of c.apps) {
      const s = state.apps.selected[app.alias];
      if (!s.checked) continue;
      if (s.min_version) sw.push({ key: app.alias, min_version: s.min_version });
      else sw.push(app.alias);
    }
    if (sw.length === 0) {
      warnings.push({ text: '"Filter to selected apps" is on but no apps are checked -> targetSoftware=[] (no apps will run).' });
      evObj.targetSoftware = [];
    } else {
      evObj.targetSoftware = sw;
    }
  }
  // mode 'default' = omit targetSoftware

  if (state.removals.mode === 'skip') {
    evObj.removeSoftware = [];
  } else if (state.removals.mode === 'filter') {
    const rm = [];
    for (const e of c.removal_catalog) {
      if (state.removals.selected[e.alias]) rm.push(e.alias);
    }
    const adhoc = state.removals.adhoc.split(/[,\n]+/).map(s => s.trim()).filter(Boolean);
    for (const a of adhoc) rm.push(a);
    evObj.removeSoftware = rm; // [] is legitimately "skip" semantics, but mode==filter means user wants this list as-is
  }

  // runtimes
  const rtList = [];
  for (const rt of c.runtimes) {
    const s = state.runtimes[rt.key];
    if (!s.enabled) continue;

    const obj = { key: rt.key };
    if (rt.channels) {
      const tracks = Array.from(s.tracks);
      if (tracks.length === 1 && !s.perTarget.exclusive && !s.perTarget.floor_required && !s.perTarget.min_supported_track) {
        obj.track = tracks[0];
      } else if (tracks.length >= 1) {
        obj.tracks = tracks;
      }
      // per-target options
      if (s.perTarget.exclusive) obj.exclusive = true;
      if (s.perTarget.floor_required) obj.floor_required = true;
      if (s.perTarget.min_supported_track) obj.min_supported_track = s.perTarget.min_supported_track;
    } else {
      if (s.min_version) obj.min_version = s.min_version;
    }

    // if obj is just {key}, push as bare string
    const keys = Object.keys(obj);
    if (keys.length === 1) rtList.push(rt.key);
    else rtList.push(obj);
  }
  if (rtList.length) evObj.targetRuntimes = rtList;

  // collapse to one consolidated -e JSON (mirrors quickref style)
  if (Object.keys(evObj).length) {
    parts.push('-e', shellQuoteJson(JSON.stringify(evObj)));
  }

  // runtime per-flag bools (cleanup_vendor / audit_only / etc.) - emit one -e per flag set true
  for (const rt of c.runtimes) {
    const s = state.runtimes[rt.key];
    if (!s.enabled) continue;
    for (const [fk, fv] of Object.entries(s.flags || {})) {
      if (fv) parts.push('-e', `"${fk}=true"`);
    }
  }

  // reboot policy (only emit if non-default)
  if (state.reboot && state.reboot !== 'never') {
    parts.push('-e', `"choco_deploy_reboot=${state.reboot}"`);
  }

  // force orphan
  for (const [k, v] of Object.entries(state.forceOrphan)) {
    if (v) parts.push('-e', `"${k}=true"`);
  }
  // common flags
  for (const [k, v] of Object.entries(state.commonFlags)) {
    if (v) parts.push('-e', `"${k}=true"`);
  }

  if (state.forks) parts.push('-f', state.forks);
  if (state.tags) parts.push('--tags', state.tags);

  // extra raw -e
  for (const raw of state.extraRaw.split('\n').map(s => s.trim()).filter(Boolean)) {
    parts.push('-e', `"${raw}"`);
  }

  // ---- format ----
  // single line
  const single = parts.join(' ');

  // multi-line: group flags into logical pairs (-i + path), (-l + pattern), each (-e + value)
  const lines = ['ansible-playbook ' + c.playbook];
  let i = 2;
  while (i < parts.length) {
    const tok = parts[i];
    if (tok.startsWith('-') && i + 1 < parts.length && !parts[i+1].startsWith('-')) {
      lines.push(`  ${tok} ${parts[i+1]}`);
      i += 2;
    } else if (tok.startsWith('--') && tok.includes('=')) {
      lines.push(`  ${tok}`);
      i += 1;
    } else {
      lines.push(`  ${tok}`);
      i += 1;
    }
  }
  const multiline = lines.map((ln, idx) => idx === lines.length - 1 ? ln : ln + ' \\').join('\n');

  return { single, multiline, warnings };
}

function shellQuote(s) {
  if (/^[A-Za-z0-9_\-\.\/=,*]+$/.test(s)) return s;
  return `'${s.replace(/'/g, `'\\''`)}'`;
}

// JSON for -e payloads: ansible-playbook accepts -e '<JSON>' (single-quoted).
function shellQuoteJson(jsonStr) {
  // wrap in single quotes; escape embedded single quotes via '\''
  return `'${jsonStr.replace(/'/g, `'\\''`)}'`;
}

function escapeHtml(s) {
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

// ---------------------------------------------------------------------------
// sidebar - inventories
// ---------------------------------------------------------------------------

function initSidebar() {
  $('#inv-select').addEventListener('change', async () => {
    const rel = $('#inv-select').value;
    if (!rel) return;
    await loadInventory(rel);
  });

  $('#use-inventory-btn').addEventListener('click', () => {
    if (!state.selectedInventory) return;
    $('#inventory-path').value = state.selectedInventory.path;
    // If exactly one group exists, prefill it as the limit pattern
    const groupNames = Object.keys(state.selectedInventory.groups || {});
    if (groupNames.length === 1) {
      $('#limit-pattern').value = groupNames[0];
    }
    render();
    // Visual feedback
    const b = $('#use-inventory-btn');
    const orig = b.textContent;
    b.textContent = '[OK] Loaded';
    b.classList.add('copied');
    setTimeout(() => { b.textContent = orig; b.classList.remove('copied'); }, 1100);
  });

  $('#inv-export-btn').addEventListener('click', () => {
    if (!state.selectedInventory) return;
    window.location.href = '/api/inventory/export?path=' + encodeURIComponent(state.selectedInventory.path);
  });

  $('#inv-ping-all-btn').addEventListener('click', async () => {
    if (!state.selectedInventory) return;
    const hosts = [];
    for (const arr of Object.values(state.selectedInventory.groups)) {
      for (const h of arr) if (!hosts.includes(h)) hosts.push(h);
    }
    await runPing(hosts);
  });

  $('#save-inv-btn').addEventListener('click', async () => {
    const name = $('#new-inv-name').value.trim();
    const group = $('#new-inv-group').value.trim() || 'basic_hosts';
    const hosts = $('#new-inv-hosts').value.split(/\n+/).map(s => s.trim()).filter(Boolean);
    const msg = $('#save-inv-msg');
    msg.textContent = '';
    msg.className = 'hint';
    if (!name.match(/^[A-Za-z0-9_\-]+$/)) {
      msg.textContent = '[X] Name must be [A-Za-z0-9_-]+';
      msg.style.color = '#f48771';
      return;
    }
    if (!hosts.length) {
      msg.textContent = '[X] Add at least one host';
      msg.style.color = '#f48771';
      return;
    }
    try {
      const r = await fetch('/api/inventory/save', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name, hosts, group }),
      });
      const data = await r.json();
      if (!r.ok || !data.ok) {
        msg.textContent = '[X] ' + (data.error || ('HTTP ' + r.status));
        msg.style.color = '#f48771';
        return;
      }
      msg.textContent = '[OK] Saved ' + data.path;
      msg.style.color = '#6a9955';
      await refreshInventories();
      // auto-select it
      $('#inv-select').value = data.path;
      $$('.tab-btn').find(b => b.dataset.tab === 'browse').click();
      await loadInventory(data.path);
    } catch (e) {
      msg.textContent = '[X] ' + e.message;
      msg.style.color = '#f48771';
    }
  });

  $('#download-inv-btn').addEventListener('click', () => {
    const name = $('#new-inv-name').value.trim() || 'adhoc';
    const group = $('#new-inv-group').value.trim() || 'basic_hosts';
    const hosts = $('#new-inv-hosts').value.split(/\n+/).map(s => s.trim()).filter(Boolean);
    if (!hosts.length) {
      $('#save-inv-msg').textContent = '[X] Add at least one host';
      $('#save-inv-msg').style.color = '#f48771';
      return;
    }
    const lines = ['---', 'all:', '  children:', `    ${group}:`, '      hosts:'];
    for (const h of hosts) lines.push(`        ${h}:`);
    const blob = new Blob([lines.join('\n') + '\n'], { type: 'application/x-yaml' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `inv-${name}.yml`;
    a.click();
    URL.revokeObjectURL(url);
  });
}

async function refreshInventories() {
  try {
    const r = await fetch('/api/inventories');
    const data = await r.json();
    state.inventories = data.inventories || [];
    const sel = $('#inv-select');
    sel.innerHTML = '';
    for (const inv of state.inventories) {
      const opt = document.createElement('option');
      opt.value = inv.path;
      opt.textContent = `${inv.path} (${inv.host_count} host${inv.host_count === 1 ? '' : 's'})`;
      sel.appendChild(opt);
    }
  } catch (e) {
    console.error('inventory list failed', e);
  }
}

async function loadInventory(rel) {
  try {
    const r = await fetch('/api/inventory?path=' + encodeURIComponent(rel));
    const data = await r.json();
    if (data.error) { console.error(data.error); return; }
    state.selectedInventory = data;
    state.pingResults = {};
    renderHostList();
    $('#use-inventory-btn').disabled = false;
  } catch (e) {
    console.error(e);
  }
}

function renderHostList() {
  const root = $('#host-list');
  root.innerHTML = '';
  const groups = state.selectedInventory?.groups || {};
  const groupNames = Object.keys(groups);
  if (!groupNames.length) {
    root.innerHTML = '<p class="hint">No host groups found in this inventory.</p>';
    return;
  }
  for (const gn of groupNames) {
    const header = document.createElement('div');
    header.style.cssText = 'font-size:0.8rem;color:#9cdcfe;margin:0.4rem 0 0.15rem;text-transform:uppercase;letter-spacing:.05em;';
    header.textContent = `[${gn}]`;
    root.appendChild(header);
    for (const host of groups[gn]) {
      const row = document.createElement('div');
      row.className = 'host-row';
      row.innerHTML = `
        <span class="hostname">${escapeHtml(host)}</span>
        <button class="btn btn-ghost btn-sm" data-ping-host="${host}">ping</button>
        <span class="ping-status" data-status-host="${host}"></span>
      `;
      root.appendChild(row);
      const pingStatus = $(`[data-status-host="${host}"]`, row);
      if (state.pingResults[host]) {
        renderPingResult(pingStatus, state.pingResults[host]);
      }
      $('button[data-ping-host]', row).addEventListener('click', async () => {
        await runPing([host]);
      });
    }
  }
}

async function runPing(hosts) {
  if (!state.selectedInventory) return;
  for (const h of hosts) {
    const el = $(`[data-status-host="${h}"]`);
    if (el) { el.className = 'ping-status ping-pend'; el.textContent = '...'; }
  }
  try {
    const r = await fetch('/api/ping', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ inventory: state.selectedInventory.path, hosts }),
    });
    const data = await r.json();
    if (data.error) {
      for (const h of hosts) {
        const el = $(`[data-status-host="${h}"]`);
        if (el) { el.className = 'ping-status ping-bad'; el.textContent = '[X]'; el.title = data.error; }
      }
      return;
    }
    for (const res of data.results || []) {
      state.pingResults[res.host] = res;
      const el = $(`[data-status-host="${res.host}"]`);
      if (el) renderPingResult(el, res);
    }
  } catch (e) {
    for (const h of hosts) {
      const el = $(`[data-status-host="${h}"]`);
      if (el) { el.className = 'ping-status ping-bad'; el.textContent = '[X]'; el.title = e.message; }
    }
  }
}

function renderPingResult(el, res) {
  if (res.ok) {
    el.className = 'ping-status ping-ok';
    el.textContent = '[OK] ' + (res.status || 'OK');
  } else {
    el.className = 'ping-status ping-bad';
    el.textContent = '[X] ' + (res.status || 'FAIL');
    if (res.msg) el.title = res.msg;
  }
}

// ---------------------------------------------------------------------------
// tabs
// ---------------------------------------------------------------------------

function initTabs() {
  $$('.tab-btn').forEach(b => {
    b.addEventListener('click', () => {
      $$('.tab-btn').forEach(x => x.classList.toggle('active', x === b));
      $$('.tab-pane').forEach(p => p.classList.toggle('active', p.dataset.pane === b.dataset.tab));
    });
  });
}

// ---------------------------------------------------------------------------
// health
// ---------------------------------------------------------------------------

async function pingHealth() {
  try {
    const r = await fetch('/api/health');
    const data = await r.json();
    const dot = $('#health-indicator');
    if (data.ok && data.ansible_on_path && data.vault_key_present) {
      dot.className = 'health-dot health-ok';
      dot.title = 'OK | ansible [OK] | vault key [OK]';
    } else {
      dot.className = 'health-dot health-degraded';
      dot.title = (data.ansible_on_path ? 'ansible [OK]' : 'ansible [X]') + ' | ' + (data.vault_key_present ? 'vault key [OK]' : 'vault key [X]');
    }
  } catch (e) {
    $('#health-indicator').className = 'health-dot health-bad';
    $('#health-indicator').title = 'server unreachable';
  }
}

// ---------------------------------------------------------------------------
// collapsible sections
// ---------------------------------------------------------------------------

const COLLAPSE_KEY = 'chocoDeployBuilder.collapsed';

function loadCollapseState() {
  try { return JSON.parse(localStorage.getItem(COLLAPSE_KEY) || '{}'); }
  catch { return {}; }
}
function saveCollapseState(map) {
  try { localStorage.setItem(COLLAPSE_KEY, JSON.stringify(map)); } catch {}
}

function initCollapsibles() {
  const saved = loadCollapseState();
  for (const section of $$('.step[data-step]')) {
    const key = section.dataset.step;
    if (saved[key]) section.classList.add('collapsed');
    const h2 = $('h2', section);
    if (!h2) continue;
    h2.addEventListener('click', () => {
      section.classList.toggle('collapsed');
      const map = loadCollapseState();
      map[key] = section.classList.contains('collapsed');
      saveCollapseState(map);
    });
  }
}

// ---------------------------------------------------------------------------
// refresh + staleness detection
// ---------------------------------------------------------------------------

function initRefresh() {
  const btn = $('#refresh-btn');
  if (btn) btn.addEventListener('click', () => doRefresh({ manual: true }));

  const reloadBtn = $('#staleness-reload-btn');
  if (reloadBtn) reloadBtn.addEventListener('click', () => doRefresh({ manual: true }));

  const dismissBtn = $('#staleness-dismiss-btn');
  if (dismissBtn) dismissBtn.addEventListener('click', () => {
    // mark the current snapshot as dismissed so we don't keep re-prompting
    watch.dismissedKey = String(watch.lastSnapshot);
    hideStalenessBanner();
  });
}

// Re-fetch catalog + inventories. Preserves the entire user selection state
// by only re-rendering the bits that depend on catalog shape (mode cards, app
// cards, runtime cards, flag lists) but keeping the *state* object intact for
// keys that still exist. New entries appear unchecked; removed entries are
// silently dropped.
async function doRefresh({ manual = false } = {}) {
  const btn = $('#refresh-btn');
  if (btn) btn.classList.add('spinning');
  try {
    const r = await fetch('/api/catalog');
    if (!r.ok) throw new Error('catalog ' + r.status);
    const newCat = await r.json();

    // Merge: keep existing state.apps.selected for aliases that survive; default new ones to false.
    const oldAppsSel = { ...state.apps.selected };
    state.apps.selected = {};
    for (const app of newCat.apps) {
      state.apps.selected[app.alias] = oldAppsSel[app.alias] || { checked: false, min_version: '' };
    }
    const oldRmSel = { ...state.removals.selected };
    state.removals.selected = {};
    for (const e of newCat.removal_catalog) {
      state.removals.selected[e.alias] = oldRmSel[e.alias] || false;
    }
    // Runtimes: keep enabled/tracks/flags/perTarget for keys that survive.
    const oldRt = state.runtimes;
    state.runtimes = {};
    for (const rt of newCat.runtimes) {
      const prev = oldRt[rt.key];
      state.runtimes[rt.key] = prev || {
        enabled: false, tracks: new Set(), single_track: '', min_version: '',
        flags: {}, perTarget: { exclusive: false, floor_required: false, min_supported_track: '' },
      };
    }
    // Force-orphan + common flags: keep what we had, drop unknowns, default new ones.
    const oldFO = { ...state.forceOrphan };
    state.forceOrphan = {};
    for (const f of newCat.force_orphan_flags) state.forceOrphan[f.key] = !!oldFO[f.key];
    const oldCF = { ...state.commonFlags };
    state.commonFlags = {};
    for (const f of newCat.common_flags) state.commonFlags[f.key] = !!oldCF[f.key];

    state.catalog = newCat;

    // Tear down + redraw the catalog-driven UI sections. The user's selections
    // are restored from state because each init() reads state on render().
    initModePicker();
    initAppPicker();
    initRemovalPicker();
    initRuntimePicker();
    initFlagsBlock();
    populateStaticHelp();

    // Replay state into the freshly-rendered DOM so checkboxes etc. show
    // their saved state.
    rehydrateUiFromState();

    await refreshInventories();
    await seedStalenessBaseline();
    hideStalenessBanner();
    render();

    if (manual) flashRefreshOk();
  } catch (e) {
    showStalenessBanner('Refresh failed: ' + e.message, { error: true });
  } finally {
    if (btn) btn.classList.remove('spinning');
  }
}

function flashRefreshOk() {
  const btn = $('#refresh-btn');
  if (!btn) return;
  const orig = btn.textContent;
  btn.textContent = 'Refreshed';
  setTimeout(() => { btn.textContent = orig; }, 900);
}

// Walk the freshly-rendered DOM and tick boxes / fill inputs from state.
// Each init() above creates virgin DOM, so this is what makes the merge
// transparent to the user.
function rehydrateUiFromState() {
  // Mode
  $$('.mode-card').forEach(c => c.classList.toggle('selected', c.dataset.key === state.mode));

  // Apps
  $$('#apps-mode-radios input').forEach(r => {
    r.checked = (r.value === state.apps.mode);
    r.closest('.radio-row').classList.toggle('selected', r.value === state.apps.mode);
  });
  for (const [alias, sel] of Object.entries(state.apps.selected)) {
    const cb = $(`#app_${cssEscape(alias)}`);
    if (cb) cb.checked = !!sel.checked;
    const txt = $(`input[data-alias-version="${cssEscape(alias)}"]`);
    if (txt) txt.value = sel.min_version || '';
  }
  refreshAppCardEnabledness();

  // Removals
  $$('#rm-mode-radios input').forEach(r => {
    r.checked = (r.value === state.removals.mode);
    r.closest('.radio-row').classList.toggle('selected', r.value === state.removals.mode);
  });
  for (const [alias, on] of Object.entries(state.removals.selected)) {
    const cb = $(`input[data-rm-alias="${cssEscape(alias)}"]`);
    if (cb) cb.checked = !!on;
  }
  const adhoc = $('#rm-adhoc'); if (adhoc) adhoc.value = state.removals.adhoc || '';
  refreshRmEnabledness();

  // Runtimes
  for (const [key, s] of Object.entries(state.runtimes)) {
    const card = $(`.runtime-card[data-key="${cssEscape(key)}"]`);
    if (!card) continue;
    const enableCb = $('input[data-rt-enable]', card);
    if (enableCb) enableCb.checked = !!s.enabled;
    card.classList.toggle('enabled', !!s.enabled);
    for (const t of (s.tracks || [])) {
      const chip = $(`.track-chip[data-track="${cssEscape(t)}"]`, card);
      if (chip) chip.classList.add('selected');
    }
    for (const [pt, val] of Object.entries(s.perTarget || {})) {
      const cb = $(`input[data-rt-pt="${cssEscape(key)}"][data-pt="${pt}"]`, card);
      if (cb) cb.checked = !!val;
      const str = $(`input[data-rt-pt-str="${cssEscape(key)}"][data-pt="${pt}"]`, card);
      if (str && typeof val === 'string') str.value = val;
    }
    for (const [fk, fv] of Object.entries(s.flags || {})) {
      const cb = $(`input[data-rt-flag="${cssEscape(key)}"][data-flag-key="${fk}"]`, card);
      if (cb) cb.checked = !!fv;
    }
    const minEl = $(`input[data-rt-min="${cssEscape(key)}"]`, card);
    if (minEl && s.min_version) minEl.value = s.min_version;
  }

  // Flags block
  const reb = $('#reboot-policy'); if (reb) reb.value = state.reboot;
  for (const [k, v] of Object.entries(state.forceOrphan)) {
    const cb = $(`input[data-fo="${cssEscape(k)}"]`);
    if (cb) cb.checked = !!v;
  }
  for (const [k, v] of Object.entries(state.commonFlags)) {
    const cb = $(`input[data-cf="${cssEscape(k)}"]`);
    if (cb) cb.checked = !!v;
  }
  const fk = $('#forks'); if (fk) fk.value = state.forks || '';
  const tg = $('#tags');  if (tg) tg.value = state.tags || '';
  const ex = $('#extra-vars-free'); if (ex) ex.value = state.extraRaw || '';
}

// Simple CSS.escape polyfill (good enough for our alias keys with dots).
function cssEscape(s) {
  if (window.CSS && CSS.escape) return CSS.escape(s);
  return String(s).replace(/[^\w-]/g, ch => '\\' + ch);
}

// --- staleness polling ---

async function seedStalenessBaseline() {
  try {
    const r = await fetch('/api/changes?since=0');
    const d = await r.json();
    watch.lastSnapshot = d.now || (Date.now() / 1000);
  } catch {
    watch.lastSnapshot = Date.now() / 1000;
  }
}

function startStalenessPolling() {
  if (watch.pollTimer) clearInterval(watch.pollTimer);
  watch.pollTimer = setInterval(checkStaleness, watch.pollIntervalMs);
}

async function checkStaleness() {
  try {
    const r = await fetch('/api/changes?since=' + encodeURIComponent(watch.lastSnapshot));
    if (!r.ok) return;
    const d = await r.json();
    if (!d.changed || !d.changed.length) {
      // Nothing changed since baseline; advance baseline so we don't keep
      // re-fetching the same set forever.
      watch.lastSnapshot = d.now;
      return;
    }
    // Don't re-show after explicit dismiss until something else changes.
    const key = d.changed.join(',') + '@' + d.mtimes.catalog + '/' + d.mtimes.role_defaults + '/' + d.mtimes.inventory_newest;
    if (key === watch.dismissedKey) return;
    const labels = {
      catalog:          'catalog.json',
      role_defaults:    'role defaults (defaults/main.yml)',
      inventory_newest: 'inventory/',
    };
    const friendly = d.changed.map(k => labels[k] || k);
    let msg;
    if (d.catalog_stale) {
      msg = 'Role defaults changed AFTER catalog.json. The UI may be missing new apps or showing old versions until catalog.json is regenerated.';
    } else {
      msg = 'Updated on disk: ' + friendly.join(', ') + '. Reload to pick up changes.';
    }
    showStalenessBanner(msg);
  } catch {
    // server is down; pingHealth() will reflect that. silent.
  }
}

function showStalenessBanner(text, opts = {}) {
  const banner = $('#staleness-banner');
  const span = $('#staleness-text');
  if (!banner || !span) return;
  span.innerHTML = '';
  span.appendChild(document.createTextNode(text));
  banner.classList.toggle('error', !!opts.error);
  banner.classList.add('visible');
}

function hideStalenessBanner() {
  const banner = $('#staleness-banner');
  if (banner) {
    banner.classList.remove('visible');
    banner.classList.remove('error');
  }
}

// ---------------------------------------------------------------------------

document.addEventListener('DOMContentLoaded', boot);
