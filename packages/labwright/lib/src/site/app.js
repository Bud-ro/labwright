const byId = (id) => document.getElementById(id);
let snap = { tests: [], buttons: [] };
let history = [];              // newest first
const filters = { tests: '', log: '', queue: '' };
let highlight = null;          // {name, run} — the show-log target to spotlight

const mark = { passed: '✓', failed: '✗', error: '‼', skipped: '○', running: '…', queued: '·' };
const changeLabel = { newFail: '▲ new fail', newPass: '▼ now passing', changed: 'changed' };
const isFail = (s) => s === 'failed' || s === 'error';
// Wall-clock ms → the operator's local HH:MM:SS.
const clock = (ms) => ms == null ? '' : new Date(ms).toLocaleTimeString([], { hour12: false });

// Every control is one POST to its own verb path (/run, /stop, /run-one…);
// the body is the verb's arguments, {} when it has none.
async function post(path, body) {
  try {
    const res = await fetch(path, { method: 'POST',
        headers: { 'content-type': 'application/json' }, body: JSON.stringify(body || {}) });
    if (!res.ok) { const r = await res.json().catch(() => ({}));
      byId('meta').textContent = ' · rejected: ' + (r.error || res.status); }
  } catch (e) { byId('meta').textContent = ' · action failed: ' + e; }
}

function badge(cls, text) { const b = document.createElement('span'); b.className = cls; b.textContent = text; return b; }
// Jump-to-source: substitute the absolute file path and line into the static
// vscode:// template the server shipped (snap.editorLink) — a plain <a href>,
// no server round-trip. Path segments are URL-encoded; the / and : separators
// (and a Windows drive colon) stay intact.
function gotoHref(file, line) {
  const path = file.replace(/\\/g, '/').split('/')
      .map((s) => encodeURIComponent(s).replace(/%3A/gi, ':')).join('/');
  return snap.editorLink.replace('{file}', path).replace('{line}', line);
}
function nameEl(t) {
  const goto = snap.interactive && snap.editorLink && t.file;
  const n = document.createElement(goto ? 'a' : 'span');
  n.className = 'name ' + (t.status || '');
  n.textContent = t.name;
  if (goto) {
    n.classList.add('link');
    n.href = gotoHref(t.file, t.line || 1);
    n.title = 'open ' + t.file + ':' + (t.line || 1);
  }
  return n;
}
function has(text, q) { return !q || text.toLowerCase().includes(q.toLowerCase()); }
function testMatch(t, q) { return has([t.name, t.status, t.change, (t.requirements || []).join(' ')].join(' '), q); }
function logMatch(e, q) { return has(e.name + ' ' + e.status, q); }

// ── Tests view: compact latest-run status, no logs ───────────────────────────
function renderTests() {
  const list = byId('testsList'); list.replaceChildren();
  for (const t of snap.tests || []) {
    if (!testMatch(t, filters.tests)) continue;
    const row = document.createElement('div'); row.className = 'row';
    row.appendChild(badge(t.status, mark[t.status] || '•'));
    row.appendChild(nameEl(t));
    for (const r of t.requirements || []) row.appendChild(badge('req', r));
    if (t.ms != null) row.appendChild(badge('req', t.ms + ' ms'));
    if (t.change) row.appendChild(badge('chg ' + t.change, changeLabel[t.change] || t.change));
    if (t.flaky) row.appendChild(badge('chg flaky', 'flaky'));
    const at = t.status === 'running' ? t.startedAt : t.finishedAt;
    if (at != null) row.appendChild(badge('time', clock(at)));
    row.appendChild(badge('spacer', ''));
    const lg = document.createElement('button'); lg.className = 'mini'; lg.textContent = 'log';
    lg.title = 'show this test in the Log view'; lg.onclick = () => showLog(t.name);
    row.appendChild(lg);
    if (snap.interactive) {
      const q = document.createElement('button'); q.className = 'mini'; q.textContent = '▶';
      q.title = 'queue this test'; q.disabled = !!snap.busy;
      q.onclick = () => post('/run-one', { test: t.name });
      row.appendChild(q);
    }
    list.appendChild(row);
  }
}

// ── Queue view: tests waiting in the active run ──────────────────────────────
// The queue is first-class server state (snap.queue, ordered names), NOT
// derived from statuses — a waiting test keeps showing its previous verdict
// in the Tests pane until it actually runs.
function renderQueue() {
  const list = byId('queueList'); list.replaceChildren();
  const byName = new Map((snap.tests || []).map((t) => [t.name, t]));
  const queued = (snap.queue || []).map((n) => byName.get(n)).filter(Boolean);
  const shown = queued.filter((t) => testMatch(t, filters.queue));
  if (!shown.length) {
    list.appendChild(badge('empty', snap.busy ? 'running — nothing else queued' : 'nothing queued'));
    return;
  }
  shown.forEach((t, i) => {
    const row = document.createElement('div'); row.className = 'row';
    row.appendChild(badge('idx', '' + (i + 1)));
    row.appendChild(nameEl(t));
    for (const r of t.requirements || []) row.appendChild(badge('req', r));
    if (t.queuedAt != null) row.appendChild(badge('time', 'queued ' + clock(t.queuedAt)));
    list.appendChild(row);
  });
}

// ── Log view: animated history feed, newest at top ───────────────────────────
function logEntryEl(e, live) {
  const div = document.createElement('div'); div.className = 'logentry ' + (e.status || '');
  if (live) div.classList.add('live');
  if (highlight && e.name === highlight.name && e.run === highlight.run) div.classList.add('hl');
  const head = document.createElement('div'); head.className = 'row';
  head.appendChild(badge(e.status, live ? '…' : (mark[e.status] || '•')));
  head.appendChild(nameEl(e));
  if (e.run != null) head.appendChild(badge('idx', 'run ' + e.run));
  if (e.ms != null) head.appendChild(badge('req', e.ms + ' ms'));
  if (e.change) head.appendChild(badge('chg ' + e.change, changeLabel[e.change] || e.change));
  const when = live ? e.startedAt : e.finishedAt;
  if (when != null) head.appendChild(badge('time', (live ? 'started ' : '') + clock(when)));
  div.appendChild(head);
  if (e.detail) { const d = document.createElement('div'); d.className = 'detail'; d.textContent = e.detail; div.appendChild(d); }
  if ((e.logs || []).length) {
    const l = document.createElement('div'); l.className = 'logs';
    // Each line carries the wall-clock time it was logged.
    l.textContent = e.logs.map((x) => clock(x.t) + '  ' + x.m).join('\n');
    div.appendChild(l);
  }
  return div;
}
function renderLog() {
  const list = byId('logList'); list.replaceChildren();
  const running = (snap.tests || []).find((t) => t.status === 'running');
  if (running && logMatch(running, filters.log)) list.appendChild(logEntryEl(running, true));
  for (const e of history) if (logMatch(e, filters.log)) list.appendChild(logEntryEl(e, false));
  const hl = list.querySelector('.hl'); if (hl) hl.scrollIntoView({ block: 'center' });
}
// Prepend one freshly-finished entry (below the live row) and animate it in.
function prependLog(e) {
  if (!logMatch(e, filters.log)) return;
  const node = logEntryEl(e, false); node.classList.add('pop');
  const list = byId('logList'); const live = list.querySelector('.live');
  if (live) list.insertBefore(node, live.nextSibling); else list.insertBefore(node, list.firstChild);
}
// Refresh only the live (currently-running) row on a snapshot — cheap.
function refreshLive() {
  const list = byId('logList'); const live = list.querySelector('.live');
  const running = (snap.tests || []).find((t) => t.status === 'running');
  if (!running || !logMatch(running, filters.log)) { if (live) live.remove(); return; }
  const fresh = logEntryEl(running, true);
  if (live) list.replaceChild(fresh, live); else list.insertBefore(fresh, list.firstChild);
}

// The Log pane is always visible, so show-log just filters + spotlights it.
function showLog(name) {
  let run = null;
  for (const e of history) if (e.name === name) run = run == null ? e.run : Math.max(run, e.run);
  highlight = { name: name, run: run };
  filters.log = name; byId('filterLog').value = name;
  renderLog();
}

function counts() {
  byId('cTests').textContent = (snap.tests || []).length || '';
  byId('cLog').textContent = history.length || '';
  byId('cQueue').textContent = (snap.queue || []).length || '';
}
function controls() {
  byId('controls').hidden = !snap.interactive;
  const busy = !!snap.busy;
  const anyFail = (snap.tests || []).some((t) => isFail(t.status));
  byId('run').disabled = busy;
  byId('runFailed').disabled = busy || !anyFail;
  byId('reload').disabled = busy;
  const restart = byId('restart');
  restart.disabled = busy || !snap.supervised;
  restart.title = snap.supervised
      ? 'fresh suite process — required for edited test bodies'
      : 'needs the labwright run supervisor (bare dart run cannot respawn itself)';
  byId('stop').disabled = !busy;
  const ub = byId('userButtons'); ub.replaceChildren();
  (snap.buttons || []).forEach((label, i) => {
    const b = document.createElement('button'); b.textContent = label; b.disabled = busy;
    b.onclick = () => post('/button', { index: i }); ub.appendChild(b);
  });
}
function onSnapshot() {
  const busy = !!snap.busy;
  byId('meta').textContent = ' · seed ' + snap.seed + (busy ? ' · running…' : snap.done ? ' · idle' : ' · live');
  controls(); renderTests(); renderQueue(); refreshLive(); counts();
}

byId('run').onclick = () => post('/run');
byId('runFailed').onclick = () => post('/run-failed');
byId('reload').onclick = () => post('/reload');
byId('restart').onclick = () => post('/restart');
byId('stop').onclick = () => post('/stop');
byId('copyFails').onclick = () => {
  const text = (snap.tests || []).filter((t) => isFail(t.status))
      .map((t) => t.name + (t.detail ? '\n  ' + t.detail.replace(/\n/g, '\n  ') : '')).join('\n\n');
  navigator.clipboard.writeText(text || 'no failures').then(
      () => { byId('meta').textContent = ' · copied ' + (text ? 'failures' : '(none)'); },
      () => { byId('meta').textContent = ' · clipboard blocked'; });
};
byId('filterTests').oninput = (e) => { filters.tests = e.target.value; renderTests(); };
byId('filterQueue').oninput = (e) => { filters.queue = e.target.value; renderQueue(); };
byId('filterLog').oninput = (e) => { filters.log = e.target.value; highlight = null; renderLog(); };

// The header dot: green while the SSE stream is open, red the moment it
// drops (EventSource keeps retrying; the dot flips back on reconnect).
function setConn(ok) {
  const c = byId('conn');
  c.classList.toggle('ok', ok);
  c.title = ok ? 'connected' : 'disconnected';
}

const source = new EventSource('/events');
source.onopen = () => setConn(true);
source.onerror = () => { setConn(false); byId('meta').textContent = ' · disconnected'; };
source.onmessage = (m) => { setConn(true); snap = JSON.parse(m.data); onSnapshot(); };
source.addEventListener('hist', (m) => {
  const d = JSON.parse(m.data);
  if (d.reset) { history = (d.entries || []).slice().reverse(); renderLog(); }
  else if (d.entry) { history.unshift(d.entry); prependLog(d.entry); }
  counts();
});
// A single log line: update the local model and APPEND to the live row —
// never a pane rebuild (full snapshots only flow on status changes).
source.addEventListener('log', (m) => {
  const d = JSON.parse(m.data);
  const t = (snap.tests || []).find((x) => x.name === d.name && x.status === 'running');
  if (t) (t.logs = t.logs || []).push({ t: d.t, m: d.m });
  const live = byId('logList').querySelector('.live');
  if (!live || (t && !logMatch(t, filters.log))) return;
  let l = live.querySelector('.logs');
  if (!l) { l = document.createElement('div'); l.className = 'logs'; live.appendChild(l); }
  l.textContent += (l.textContent ? '\n' : '') + clock(d.t) + '  ' + d.m;
});
