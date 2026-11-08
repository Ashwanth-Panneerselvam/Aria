import Foundation

/// The single page served at `/`. Self-contained (no external requests) so
/// it works on a LAN with no internet.
nonisolated enum TransferPage {
    static var data: Data { Data(html.utf8) }

    static let html = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Aria · Wi-Fi Transfer</title>
<style>
  :root { --bg:#000; --surface:#0e0e0e; --raised:#151515; --line:#242424; --text:#fff; --dim:#a8a8a8; --faint:#707070; --accent:#59a6f2; --ok:#4cc38a; --warn:#f0a03c; --bad:#ef5b5b; }
  * { box-sizing: border-box; }
  html, body { margin:0; background:var(--bg); color:var(--text); font: 15px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
  main { max-width: 760px; margin: 0 auto; padding: 40px 20px 80px; }
  h1 { font-size: 13px; letter-spacing: .35em; font-weight: 600; color: var(--dim); margin: 0 0 6px; }
  h2 { font-size: 26px; margin: 0 0 24px; font-weight: 600; }
  .card { background: var(--surface); border: 1px solid var(--line); border-radius: 12px; padding: 20px; margin-bottom: 16px; }
  .muted { color: var(--dim); } .faint { color: var(--faint); font-size: 13px; }
  input[type=text] { background: var(--raised); color: var(--text); border: 1px solid var(--line); border-radius: 8px; font-size: 24px; letter-spacing: .3em; padding: 10px 14px; width: 180px; text-align: center; }
  button { background: var(--text); color: var(--bg); border: 0; border-radius: 999px; padding: 11px 22px; font-weight: 600; font-size: 15px; cursor: pointer; }
  button.secondary { background: var(--raised); color: var(--text); border: 1px solid var(--line); }
  #drop { border: 1.5px dashed var(--line); border-radius: 12px; padding: 44px 20px; text-align: center; transition: border-color .15s, background .15s; }
  #drop.over { border-color: var(--accent); background: #0a1520; }
  #drop strong { display:block; font-size: 18px; margin-bottom: 6px; }
  .row { display:flex; align-items:center; gap: 12px; padding: 10px 0; border-bottom: 1px solid var(--line); }
  .row:last-child { border-bottom: 0; }
  .name { flex:1; min-width:0; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .bar { width: 120px; height: 4px; background: var(--line); border-radius: 2px; overflow:hidden; flex-shrink:0; }
  .bar > i { display:block; height:100%; width:0; background: var(--text); }
  .st { width: 110px; text-align:right; font-size: 13px; color: var(--dim); flex-shrink:0; }
  .st.ok { color: var(--ok); } .st.warn { color: var(--warn); } .st.bad { color: var(--bad); }
  .stats { display:flex; gap: 24px; flex-wrap: wrap; font-variant-numeric: tabular-nums; }
  .stats b { display:block; font-size: 22px; font-weight: 600; }
  .hidden { display:none; }
  .actions { display:flex; gap: 10px; justify-content:center; margin-top: 16px; flex-wrap: wrap; }
</style>
</head>
<body>
<main>
  <h1>ARIA</h1>
  <h2>Wi-Fi Transfer</h2>

  <section id="login" class="card">
    <p class="muted" style="margin-top:0">Enter the 6-digit PIN shown on your iPhone.</p>
    <input id="pin" type="text" inputmode="numeric" maxlength="6" autocomplete="off" autofocus>
    <button id="pinGo" style="margin-left:10px">Connect</button>
    <p id="pinErr" class="faint" style="color:var(--bad)"></p>
  </section>

  <section id="app" class="hidden">
    <div class="card">
      <div id="drop">
        <strong>Drop music files or folders here</strong>
        <span class="muted">FLAC, ALAC/M4A, WAV, AIFF, MP3, AAC — folders are searched recursively</span>
        <div class="actions">
          <button class="secondary" id="pickFiles">Choose files…</button>
          <button class="secondary" id="pickFolder">Choose folder…</button>
        </div>
        <input id="fileInput" type="file" multiple class="hidden">
        <input id="folderInput" type="file" webkitdirectory multiple class="hidden">
      </div>
      <p class="faint">Keep Aria open on the iPhone with the screen on until uploads finish. Files already in the library are skipped.</p>
    </div>

    <div class="card stats">
      <div><b id="sQueued">0</b><span class="faint">waiting</span></div>
      <div><b id="sDone">0</b><span class="faint">imported</span></div>
      <div><b id="sSkip">0</b><span class="faint">already there</span></div>
      <div><b id="sFail">0</b><span class="faint">failed</span></div>
      <div><b id="sLib">–</b><span class="faint">tracks on iPhone</span></div>
    </div>

    <div class="card" id="listCard"><div id="list" class="faint">No uploads yet.</div></div>
  </section>
</main>
<script>
(() => {
  const $ = (s) => document.querySelector(s);
  const EXT = ['flac','m4a','mp3','wav','wave','aif','aiff','aac','alac'];
  let pin = sessionStorage.getItem('ariaPin') || '';
  const items = [];
  let busy = false;
  const counts = { done: 0, skip: 0, fail: 0 };

  async function ping(p) {
    try { const r = await fetch('/api/ping', { headers: { 'X-Aria-Pin': p } }); return r.ok; }
    catch (e) { return false; }
  }

  async function connect() {
    const p = $('#pin').value.trim();
    if (!/^\d{6}$/.test(p)) { $('#pinErr').textContent = 'The PIN has 6 digits.'; return; }
    if (await ping(p)) {
      pin = p; sessionStorage.setItem('ariaPin', p);
      $('#login').classList.add('hidden'); $('#app').classList.remove('hidden');
      refreshLibrary();
    } else {
      $('#pinErr').textContent = 'Wrong PIN, or the transfer screen was closed on the iPhone.';
    }
  }
  $('#pinGo').onclick = connect;
  $('#pin').addEventListener('keydown', (e) => { if (e.key === 'Enter') connect(); });
  if (pin) ping(pin).then((ok) => { if (ok) { $('#login').classList.add('hidden'); $('#app').classList.remove('hidden'); refreshLibrary(); } });

  async function refreshLibrary() {
    try {
      const r = await fetch('/api/library', { headers: { 'X-Aria-Pin': pin } });
      if (!r.ok) return;
      const j = await r.json();
      $('#sLib').textContent = j.count;
    } catch (e) {}
  }

  function ext(name) { const i = name.lastIndexOf('.'); return i < 0 ? '' : name.slice(i + 1).toLowerCase(); }

  function addFiles(files) {
    let added = 0;
    for (const f of files) {
      if (!EXT.includes(ext(f.name)) || f.size === 0) continue;
      const row = document.createElement('div');
      row.className = 'row';
      row.innerHTML = '<span class="name"></span><span class="bar"><i></i></span><span class="st">Waiting</span>';
      row.querySelector('.name').textContent = f.name;
      if (items.length === 0) $('#list').textContent = '';
      $('#list').prepend(row);
      items.push({ file: f, row: row, state: 'waiting' });
      added++;
    }
    updateStats();
    pump();
    return added;
  }

  function updateStats() {
    $('#sQueued').textContent = items.filter((i) => i.state === 'waiting' || i.state === 'sending').length;
    $('#sDone').textContent = counts.done; $('#sSkip').textContent = counts.skip; $('#sFail').textContent = counts.fail;
  }

  function setStatus(item, text, cls) {
    const st = item.row.querySelector('.st');
    st.textContent = text; st.className = 'st' + (cls ? ' ' + cls : '');
  }

  function pump() {
    if (busy) return;
    const next = items.find((i) => i.state === 'waiting');
    if (!next) { refreshLibrary(); return; }
    busy = true;
    upload(next).then(() => { busy = false; updateStats(); pump(); });
  }

  function upload(item) {
    return new Promise((resolve) => {
      item.state = 'sending'; updateStats();
      setStatus(item, 'Sending');
      const bar = item.row.querySelector('.bar > i');
      const x = new XMLHttpRequest();
      x.open('PUT', '/upload');
      x.setRequestHeader('X-Aria-Pin', pin);
      x.setRequestHeader('X-File-Name', encodeURIComponent(item.file.name));
      x.upload.onprogress = (e) => {
        if (e.lengthComputable) {
          const pct = Math.round((e.loaded / e.total) * 100);
          bar.style.width = pct + '%';
          setStatus(item, pct < 100 ? pct + '%' : 'Importing…');
        }
      };
      x.onload = () => {
        let j = {};
        try { j = JSON.parse(x.responseText); } catch (e) {}
        bar.style.width = '100%';
        if (x.status === 200 && j.status === 'imported') { item.state = 'done'; counts.done++; setStatus(item, 'Imported', 'ok'); }
        else if (x.status === 200 && j.status === 'duplicate') { item.state = 'done'; counts.skip++; setStatus(item, 'Already there', 'warn'); }
        else if (x.status === 401) { item.state = 'failed'; counts.fail++; setStatus(item, 'Wrong PIN', 'bad'); }
        else { item.state = 'failed'; counts.fail++; setStatus(item, j.error || ('Error ' + x.status), 'bad'); }
        resolve();
      };
      x.onerror = () => { item.state = 'failed'; counts.fail++; setStatus(item, 'Connection lost', 'bad'); resolve(); };
      x.send(item.file);
    });
  }

  function readEntries(reader) {
    return new Promise((res) => reader.readEntries(res, () => res([])));
  }

  async function walk(entry) {
    if (entry.isFile) return new Promise((res) => entry.file((f) => res([f]), () => res([])));
    if (entry.isDirectory) {
      const reader = entry.createReader();
      let out = [];
      for (;;) {
        const batch = await readEntries(reader);
        if (!batch.length) break;
        for (const e of batch) out = out.concat(await walk(e));
      }
      return out;
    }
    return [];
  }

  const drop = $('#drop');
  ['dragenter', 'dragover'].forEach((t) => drop.addEventListener(t, (e) => { e.preventDefault(); drop.classList.add('over'); }));
  ['dragleave', 'drop'].forEach((t) => drop.addEventListener(t, () => drop.classList.remove('over')));
  drop.addEventListener('drop', async (e) => {
    e.preventDefault();
    const entries = [...e.dataTransfer.items].map((i) => i.webkitGetAsEntry && i.webkitGetAsEntry()).filter(Boolean);
    let files = [];
    if (entries.length) { for (const en of entries) files = files.concat(await walk(en)); }
    else { files = [...e.dataTransfer.files]; }
    files.sort((a, b) => a.name.localeCompare(b.name, undefined, { numeric: true }));
    addFiles(files);
  });
  $('#pickFiles').onclick = () => $('#fileInput').click();
  $('#pickFolder').onclick = () => $('#folderInput').click();
  $('#fileInput').onchange = (e) => { addFiles([...e.target.files]); e.target.value = ''; };
  $('#folderInput').onchange = (e) => { addFiles([...e.target.files]); e.target.value = ''; };
  window.addEventListener('beforeunload', (e) => { if (busy) { e.preventDefault(); e.returnValue = ''; } });
})();
</script>
</body>
</html>
"""#
}
