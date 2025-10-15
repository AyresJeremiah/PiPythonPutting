(() => {
  // ----- Elements & overlay -----
  const img = document.getElementById('video');
  const canvas = document.getElementById('overlay');
  const ctx = canvas.getContext('2d');

  const elState = document.getElementById('state');
  const elStatus= document.getElementById('status');
  const elMPH   = document.getElementById('mph');
  const elYPS   = document.getElementById('yps');
  const elHLA   = document.getElementById('hla');
  const elFPS   = document.getElementById('fps');
  const modePill= document.getElementById('modePill');

  const el = {
    // Stage sliders
    'st.x1': byId('st.x1'), 'st.y1': byId('st.y1'),
    'st.x2': byId('st.x2'), 'st.y2': byId('st.y2'),
    // Track sliders
    'tr.x1': byId('tr.x1'), 'tr.y1': byId('tr.y1'),
    'tr.x2': byId('tr.x2'), 'tr.y2': byId('tr.y2'),
    // misc
    'show_mask': byId('show_mask'),
    'input.playback_speed': byId('input.playback_speed'),
    // calibration
    'btnPickColor': byId('btnPickColor'),
    'btnCalLine': byId('btnCalLine'),
    'btnCalSave': byId('btnCalSave'),
    'cal.px_per_yard': byId('cal.px_per_yard'),
    'btnReload': byId('btnReload'),
    'btnSave': byId('btnSave'),
  };

  function byId(id){ return document.getElementById(id) }
  function outFor(id){ return document.getElementById(id + '.out') }

  // video dims from telemetry (server space)
  let dims = { w: 1280, h: 720 };
  let teleLatest = {};

  // client-side live rectangles (draw immediately)
  let localStage = {x1:0,y1:0,x2:1,y2:1};
  let localTrack = {x1:0,y1:0,x2:1,y2:1};

  // calibration line state (client)
  let calMode = false;
  let calLine = null; // {x1,y1,x2,y2} in server pixels
  let dragging = null; // 'start' | 'end' | null

  // color pick mode
  let colorPick = false;

  function setMode(str){
    modePill.textContent = `mode: ${str}`;
  }

  function fitCanvas() {
    canvas.width  = img.clientWidth || canvas.width;
    canvas.height = img.clientHeight || canvas.height;
  }
  window.addEventListener('resize', fitCanvas);
  img.addEventListener('load', fitCanvas);
  fitCanvas();

  // ----- drawing helpers -----
  function scaleRect(rc) {
    const sx = canvas.width / (dims.w || 1);
    const sy = canvas.height / (dims.h || 1);
    return { x1: Math.round(rc.x1*sx), y1: Math.round(rc.y1*sy), x2: Math.round(rc.x2*sx), y2: Math.round(rc.y2*sy) };
  }
  function drawRect(rc, color, label) {
    ctx.strokeStyle = color; ctx.lineWidth = 2;
    ctx.strokeRect(rc.x1, rc.y1, rc.x2-rc.x1, rc.y2-rc.y1);
    if (label) { ctx.fillStyle=color; ctx.font='14px system-ui,sans-serif'; ctx.fillText(label, rc.x1+6, rc.y1+18); }
  }
  function drawDot(x, y, r, color) {
    ctx.beginPath(); ctx.arc(x, y, r||5, 0, Math.PI*2); ctx.fillStyle=color; ctx.fill();
  }
  function drawCalLine(line){
    if (!line) return;
    const sx = canvas.width / (dims.w || 1);
    const sy = canvas.height / (dims.h || 1);
    const x1 = Math.round(line.x1*sx), y1 = Math.round(line.y1*sy);
    const x2 = Math.round(line.x2*sx), y2 = Math.round(line.y2*sy);
    ctx.strokeStyle = '#fde047'; ctx.lineWidth = 3;
    ctx.beginPath(); ctx.moveTo(x1,y1); ctx.lineTo(x2,y2); ctx.stroke();
    // handles
    drawDot(x1,y1,6,'#fde047'); drawDot(x2,y2,6,'#fde047');
  }
  function setStatus(state, hasBall) {
    elState.textContent = state || 'IDLE';
    let c='yellow'; if (state==='TRACKING') c='green'; if (state==='COOLDOWN') c='yellow'; if (state&&state.startsWith('SHOT')) c='red';
    if (!hasBall) c='yellow';
    elStatus.className = `dot ${c}`;
  }

  // ----- telemetry WS -----
  const proto = (location.protocol === 'https:') ? 'wss' : 'ws';
  const ws = new WebSocket(`${proto}://${location.host}/ws`);
  ws.onmessage = (ev) => {
    let data; try { data = JSON.parse(ev.data) } catch { return; }
    teleLatest = data;
    if (data.dims && (data.dims.w|0) && (data.dims.h|0)) {
      dims = { w: data.dims.w|0, h: data.dims.h|0 };
      setSliderRanges();
    }
    elMPH.textContent = (data.mph ?? 0).toFixed(1);
    elYPS.textContent = (data.yps ?? 0).toFixed(2);
    elHLA.textContent = (data.hla ?? 0).toFixed(1) + '°';
    elFPS.textContent = Math.round(data.fps ?? 0);
    setStatus(data.state, !!data.ball);
    if (data.stage && data.track) {
      localStage = data.stage;
      localTrack = data.track;
      pushSlidersFromRects();
    }
    redrawOverlay();
  };

  function redrawOverlay() {
    ctx.clearRect(0,0,canvas.width,canvas.height);
    drawRect(scaleRect(localStage), '#0ff', 'STAGE');
    drawRect(scaleRect(localTrack), '#0f0', 'TRACK');
    if (calMode) drawCalLine(calLine);
    const b = teleLatest.ball;
    if (b) {
      const sx = canvas.width / (dims.w||1), sy = canvas.height / (dims.h||1);
      drawDot(b.x * sx, b.y * sy, 5, '#fff');
    }
  }

  // ----- sliders → live update & server preview -----
  function clampRect(rc){
    rc.x1 = Math.max(0, Math.min(rc.x1|0, dims.w-1));
    rc.y1 = Math.max(0, Math.min(rc.y1|0, dims.h-1));
    rc.x2 = Math.max(rc.x1+1, Math.min(rc.x2|0, dims.w));
    rc.y2 = Math.max(rc.y1+1, Math.min(rc.y2|0, dims.h));
  }

  function setSliderRanges(){
    ['st.x1','st.x2','tr.x1','tr.x2'].forEach(id => { const r=el[id]; if(r) r.max=String(dims.w); });
    ['st.y1','st.y2','tr.y1','tr.y2'].forEach(id => { const r=el[id]; if(r) r.max=String(dims.h); });
  }

  function pushSlidersFromRects(){
    setSlider('st.x1', localStage.x1); setSlider('st.y1', localStage.y1);
    setSlider('st.x2', localStage.x2); setSlider('st.y2', localStage.y2);
    setSlider('tr.x1', localTrack.x1); setSlider('tr.y1', localTrack.y1);
    setSlider('tr.x2', localTrack.x2); setSlider('tr.y2', localTrack.y2);
  }

  function setSlider(id, val){
    const r = el[id], o = outFor(id);
    if (!r) return;
    r.value = String(val|0);
    if (o) o.textContent = String(val|0);
  }

  async function postPreview(partialCfg){
    try {
      await fetch('/settings/preview', { method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(partialCfg) });
    } catch(e){ /* ignore */ }
  }

  function bindRectSlider(kind, edge){
    // kind: 'st' | 'tr'; edge: 'x1'|'y1'|'x2'|'y2'
    const id = `${kind}.${edge}`;
    const r = el[id], o = outFor(id);
    if (!r) return;
    r.addEventListener('input', () => {
      const v = r.value|0;
      if (o) o.textContent = String(v);
      const rect = (kind==='st') ? localStage : localTrack;
      rect[edge] = v;
      clampRect(rect);
      setSlider(id, rect[edge]);  // keep slider sane if clamped
      redrawOverlay();
      if (kind==='st') {
        postPreview({ zones: { stage_roi: { ...rect } }});
      } else {
        postPreview({ zones: { track_roi: { ...rect } }});
      }
    });
  }
  ['st','tr'].forEach(k => ['x1','y1','x2','y2'].forEach(e => bindRectSlider(k, e)));

  // quick toggles → preview
  el['show_mask'].addEventListener('change', () => postPreview({ show_mask: !!el['show_mask'].checked }));
  el['input.playback_speed'].addEventListener('change', () => {
    const s = parseFloat(el['input.playback_speed'].value) || 1.0;
    postPreview({ input: { playback_speed: s }});
  });

  // px/yard manual live preview
  el['cal.px_per_yard'].addEventListener('change', () => {
    const v = parseFloat(el['cal.px_per_yard'].value) || 1.0;
    postPreview({ calibration: { px_per_yard: v }});
  });

  // buttons
  el['btnReload'].onclick = loadSettings;
  el['btnSave'].onclick   = async () => {
    const payload = {
      zones: { stage_roi: { ...localStage }, track_roi: { ...localTrack } },
      show_mask: !!el['show_mask'].checked,
      input: { playback_speed: parseFloat(el['input.playback_speed'].value) || 1.0 },
      calibration: { px_per_yard: parseFloat(el['cal.px_per_yard'].value) || 1.0 }
    };
    await fetch('/settings/save', { method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(payload) });
  };

  // ----- Color pick mode -----
  el['btnPickColor'].onclick = () => {
    colorPick = true; calMode = false; dragging = null;
    setMode('pick color (click on ball)');
    el['btnCalSave'].style.display = 'none';
    redrawOverlay();
  };

  canvas.addEventListener('click', async (ev) => {
    if (!colorPick) return;
    const {sx, sy} = screenToServerScale();
    const x = Math.round(ev.offsetX / sx);
    const y = Math.round(ev.offsetY / sy);
    colorPick = false; setMode('view');
    try {
      const res = await fetch('/pick/ball', { method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({ x, y }) });
      const data = await res.json().catch(()=>null);
      // Optionally display what was chosen:
      if (data && data.ok) {
        console.log('Picked HSV:', data.hsv, 'bounds:', data.bounds);
      }
    } catch(e) { /* ignore */ }
  });

  // ----- Calibration line drag mode -----
  el['btnCalLine'].onclick = () => {
    calMode = true; colorPick = false;
    if (!calLine) {
      // default horizontal line mid-screen
      calLine = { x1: Math.round(dims.w*0.2), y1: Math.round(dims.h*0.5),
                  x2: Math.round(dims.w*0.8), y2: Math.round(dims.h*0.5) };
    }
    setMode('calibrate line (drag ends)'); el['btnCalSave'].style.display = 'inline-block';
    redrawOverlay();
  };

  el['btnCalSave'].onclick = async () => {
    if (!calLine) return;
    const yards = 1.0; // you can add a UI input for yards length if needed
    try {
      await fetch('/calibration/line', {
        method:'POST',
        headers:{'Content-Type':'application/json'},
        body: JSON.stringify({ ...calLine, yards, save: true })
      });
      setMode('view'); calMode = false; el['btnCalSave'].style.display = 'none';
    } catch(e){ /* ignore */ }
  };

  function screenToServerScale(){
    const sx = canvas.width / (dims.w || 1);
    const sy = canvas.height / (dims.h || 1);
    return { sx, sy };
  }
  function nearestHandle(px, py){
    if (!calLine) return null;
    const {sx, sy} = screenToServerScale();
    const x1 = calLine.x1*sx, y1 = calLine.y1*sy;
    const x2 = calLine.x2*sx, y2 = calLine.y2*sy;
    const d1 = Math.hypot(px-x1, py-y1);
    const d2 = Math.hypot(px-x2, py-y2);
    const tol = 12;
    if (d1 <= tol) return 'start';
    if (d2 <= tol) return 'end';
    return null;
  }

  canvas.addEventListener('mousedown', (ev) => {
    if (!calMode) return;
    const h = nearestHandle(ev.offsetX, ev.offsetY);
    dragging = h;
  });
  canvas.addEventListener('mousemove', (ev) => {
    if (!calMode || !dragging) return;
    const {sx, sy} = screenToServerScale();
    const x = Math.round(ev.offsetX / sx);
    const y = Math.round(ev.offsetY / sy);
    if (dragging === 'start') { calLine.x1 = x; calLine.y1 = y; }
    else { calLine.x2 = x; calLine.y2 = y; }
    redrawOverlay();
  });
  document.addEventListener('mouseup', () => { dragging = null; });

  // ----- Load settings -----
  async function loadSettings(){
    const res = await fetch('/settings'); const cfg = await res.json();
    if (cfg.dims && cfg.dims.w && cfg.dims.h) { dims = { w: cfg.dims.w|0, h: cfg.dims.h|0 }; }
    setSliderRanges();

    const st  = cfg.zones?.stage_roi || {};
    const tr  = cfg.zones?.track_roi || {};
    localStage = { x1: st.x1|0, y1: st.y1|0, x2: st.x2|0, y2: st.y2|0 };
    localTrack = { x1: tr.x1|0, y1: tr.y1|0, x2: tr.x2|0, y2: tr.y2|0 };
    pushSlidersFromRects();

    el['show_mask'].checked = !!cfg.show_mask;
    el['input.playback_speed'].value = cfg.input?.playback_speed ?? 1.0;
    el['cal.px_per_yard'].value = cfg.calibration?.px_per_yard ?? 1.0;

    redrawOverlay();
  }

  // init
  loadSettings();
})();
