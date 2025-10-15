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
  const modePill= document.getElementById('modePill') || { textContent: '' };
  const editPill= document.getElementById('editPill') || { textContent: '' };

  // Control elements (existing)
  const el = {
    // Stage sliders
    'st.x1': byId('st.x1'), 'st.y1': byId('st.y1'),
    'st.x2': byId('st.x2'), 'st.y2': byId('st.y2'),
    // Track sliders
    'tr.x1': byId('tr.x1'), 'tr.y1': byId('tr.y1'),
    'tr.x2': byId('tr.x2'), 'tr.y2': byId('tr.y2'),
    // misc toggles
    'show_mask': byId('show_mask'),
    'input.playback_speed': byId('input.playback_speed'),
    'cal.px_per_yard': byId('cal.px_per_yard'),
    // buttons
    'btnReload': byId('btnReload'),
    'btnSave': byId('btnSave'),
    // new edit buttons
    'btnEditStage': byId('btnEditStage'),
    'btnEditTrack': byId('btnEditTrack'),
    'btnEditDone':  byId('btnEditDone'),
    // optional color & cal already in your UI
    'btnPickColor': byId('btnPickColor'),
    'btnCalLine': byId('btnCalLine'),
    'btnCalSave': byId('btnCalSave'),
  };

  function byId(id){ return document.getElementById(id) }
  function outFor(id){ const n=document.getElementById(id + '.out'); return n || { textContent: ()=>{} } }

  // video dims from telemetry (server space)
  let dims = { w: 1280, h: 720 };
  let teleLatest = {};

  // client-side rects (server pixels)
  let localStage = {x1:0,y1:0,x2:1,y2:1};
  let localTrack = {x1:0,y1:0,x2:1,y2:1};

  // modes
  let colorPick = false;
  let calMode   = false;
  let calLine   = null;

  // NEW: edit rectangles on stream
  // editMode: 'none' | 'stage' | 'track'
  let editMode  = 'none';
  let dragging  = null; // { kind:'stage'|'track', op:'move'|'n'|'s'|'e'|'w'|'nw'|'ne'|'sw'|'se', start:{sx,sy}, rect:{...} }

  // --- debounce helper for preview POSTs
  let previewTimer = null;
  function postPreviewDebounced(payload, delay=40){
    clearTimeout(previewTimer);
    previewTimer = setTimeout(()=>postPreview(payload), delay);
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
  function drawRect(rc, color, label, showHandles=false) {
    ctx.strokeStyle = color; ctx.lineWidth = 2;
    ctx.strokeRect(rc.x1, rc.y1, rc.x2-rc.x1, rc.y2-rc.y1);
    if (label) { ctx.fillStyle=color; ctx.font='14px system-ui,sans-serif'; ctx.fillText(label, rc.x1+6, rc.y1+18); }
    if (showHandles) drawHandles(rc, color);
  }
  function drawHandles(rc, color){
    const h=7; const c=color || '#fff';
    const pts = [
      [rc.x1, rc.y1], [rc.x2, rc.y1], [rc.x1, rc.y2], [rc.x2, rc.y2], // corners
      [Math.round((rc.x1+rc.x2)/2), rc.y1], // top
      [Math.round((rc.x1+rc.x2)/2), rc.y2], // bottom
      [rc.x1, Math.round((rc.y1+rc.y2)/2)], // left
      [rc.x2, Math.round((rc.y1+rc.y2)/2)], // right
    ];
    ctx.fillStyle = c;
    for (const [x,y] of pts){
      ctx.fillRect(x-h, y-h, h*2, h*2);
    }
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
      // only override local if not actively dragging (avoid jump)
      if (!dragging) {
        localStage = data.stage;
        localTrack = data.track;
        pushSlidersFromRects();
      }
    }
    redrawOverlay();
  };

  function redrawOverlay() {
    ctx.clearRect(0,0,canvas.width,canvas.height);
    const st = scaleRect(localStage);
    const tr = scaleRect(localTrack);
    const editingStage = (editMode==='stage');
    const editingTrack = (editMode==='track');
    drawRect(st, '#0ff', 'STAGE', editingStage);
    drawRect(tr, '#0f0', 'TRACK', editingTrack);
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
  async function postPreview(payload){
    try {
      await fetch('/settings/preview', { method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(payload) });
    } catch(e){ /* ignore */ }
  }
  function bindRectSlider(kind, edge){
    const id = `${kind}.${edge}`;
    const r = el[id], o = outFor(id);
    if (!r) return;
    r.addEventListener('input', () => {
      const v = r.value|0;
      if (o) o.textContent = String(v);
      const rect = (kind==='st') ? localStage : localTrack;
      rect[edge] = v;
      clampRect(rect);
      setSlider(id, rect[edge]);
      redrawOverlay();
      if (kind==='st') postPreviewDebounced({ zones: { stage_roi: { ...rect } }});
      else             postPreviewDebounced({ zones: { track_roi: { ...rect } }});
    });
  }
  ['st','tr'].forEach(k => ['x1','y1','x2','y2'].forEach(e => bindRectSlider(k, e)));

  // quick toggles → preview
  if (el['show_mask']) el['show_mask'].addEventListener('change', () => postPreview({ show_mask: !!el['show_mask'].checked }));
  if (el['input.playback_speed']) el['input.playback_speed'].addEventListener('change', () => {
    const s = parseFloat(el['input.playback_speed'].value) || 1.0;
    postPreview({ input: { playback_speed: s }});
  });
  if (el['cal.px_per_yard']) el['cal.px_per_yard'].addEventListener('change', () => {
    const v = parseFloat(el['cal.px_per_yard'].value) || 1.0;
    postPreview({ calibration: { px_per_yard: v }});
  });

  // buttons
  if (el['btnReload']) el['btnReload'].onclick = loadSettings;
  if (el['btnSave']) el['btnSave'].onclick   = async () => {
    const payload = {
      zones: { stage_roi: { ...localStage }, track_roi: { ...localTrack } },
      show_mask: !!(el['show_mask'] && el['show_mask'].checked),
      input: { playback_speed: parseFloat(el['input.playback_speed']?.value || '1.0') || 1.0 },
      calibration: { px_per_yard: parseFloat(el['cal.px_per_yard']?.value || '1.0') || 1.0 }
    };
    await fetch('/settings/save', { method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(payload) });
  };

  // ---------- NEW: Edit on stream ----------
  function setEditMode(m){
    editMode = m; dragging = null;
    if (el['btnEditDone']) el['btnEditDone'].style.display = (m==='none') ? 'none' : 'inline-block';
    if (editPill) editPill.textContent = `edit: ${m}`;
    redrawOverlay();
  }
  if (el['btnEditStage']) el['btnEditStage'].onclick = () => setEditMode('stage');
  if (el['btnEditTrack']) el['btnEditTrack'].onclick = () => setEditMode('track');
  if (el['btnEditDone'])  el['btnEditDone'].onclick  = () => setEditMode('none');

  function screenToServerScale(){
    const sx = canvas.width / (dims.w || 1);
    const sy = canvas.height / (dims.h || 1);
    return { sx, sy };
  }
  function hitTest(rectScaled, px, py){
    // returns op: 'nw','ne','sw','se','n','s','e','w','move', or null
    const tol = 10;
    const x1=rectScaled.x1, y1=rectScaled.y1, x2=rectScaled.x2, y2=rectScaled.y2;
    const cx = Math.round((x1+x2)/2), cy = Math.round((y1+y2)/2);

    const near = (ax,ay)=> (Math.abs(px-ax)<=tol && Math.abs(py-ay)<=tol);
    if (near(x1,y1)) return 'nw';
    if (near(x2,y1)) return 'ne';
    if (near(x1,y2)) return 'sw';
    if (near(x2,y2)) return 'se';

    const within = (a, b, val) => (val>=Math.min(a,b)-tol && val<=Math.max(a,b)+tol);
    if (within(x1,x2,px) && Math.abs(py-y1)<=tol) return 'n';
    if (within(x1,x2,px) && Math.abs(py-y2)<=tol) return 's';
    if (within(y1,y2,py) && Math.abs(px-x1)<=tol) return 'w';
    if (within(y1,y2,py) && Math.abs(px-x2)<=tol) return 'e';

    if (px>=x1 && px<=x2 && py>=y1 && py<=y2) return 'move';
    return null;
  }

  function applyDrag(op, rect, dx, dy){
    // rect in *server* pixels; dx/dy are server-px deltas
    const MIN_W = 4, MIN_H = 4;
    let {x1,y1,x2,y2} = rect;
    if (op==='move'){
      x1+=dx; x2+=dx; y1+=dy; y2+=dy;
    } else {
      if (op.includes('n')) y1 += dy;
      if (op.includes('s')) y2 += dy;
      if (op.includes('w')) x1 += dx;
      if (op.includes('e')) x2 += dx;
    }
    // normalize & clamp
    if (x1>x2) [x1,x2] = [x2,x1];
    if (y1>y2) [y1,y2] = [y2,y1];
    x1 = Math.max(0, Math.min(x1, dims.w-1));
    y1 = Math.max(0, Math.min(y1, dims.h-1));
    x2 = Math.max(x1+MIN_W, Math.min(x2, dims.w));
    y2 = Math.max(y1+MIN_H, Math.min(y2, dims.h));
    rect.x1=x1; rect.y1=y1; rect.x2=x2; rect.y2=y2;
  }

  canvas.addEventListener('mousedown', (ev) => {
    if (editMode==='none') return;
    // don’t interfere with color or line modes
    if (colorPick || calMode) return;

    const st = scaleRect(localStage);
    const tr = scaleRect(localTrack);
    const target = (editMode==='stage') ? { kind:'stage', rScaled: st, r: localStage }
                                        : { kind:'track', rScaled: tr, r: localTrack };

    const op = hitTest(target.rScaled, ev.offsetX, ev.offsetY);
    if (!op) return;
    const { sx, sy } = screenToServerScale();
    dragging = {
      kind: target.kind,
      op,
      start: { sx: ev.offsetX, sy: ev.offsetY },
      rect:  { ...target.r } // snapshot
    };
  });

  canvas.addEventListener('mousemove', (ev) => {
    if (!dragging) return;
    const { sx, sy } = screenToServerScale();
    const dx = Math.round((ev.offsetX - dragging.start.sx) / sx);
    const dy = Math.round((ev.offsetY - dragging.start.sy) / sy);

    const rectRef = (dragging.kind==='stage') ? localStage : localTrack;
    // start from snapshot
    rectRef.x1 = dragging.rect.x1; rectRef.y1 = dragging.rect.y1;
    rectRef.x2 = dragging.rect.x2; rectRef.y2 = dragging.rect.y2;

    applyDrag(dragging.op, rectRef, dx, dy);
    // keep sliders in sync visually
    pushSlidersFromRects();
    redrawOverlay();

    // live preview, but debounce to avoid spamming server
    const payload = (dragging.kind==='stage')
      ? { zones: { stage_roi: { ...rectRef } } }
      : { zones: { track_roi: { ...rectRef } } };
    postPreviewDebounced(payload, 40);
  });

  document.addEventListener('mouseup', () => {
    if (!dragging) return;
    dragging = null;
  });

  // ----- Color pick & calibration (unchanged behavior; optional in your UI) -----
  if (el['btnPickColor']) el['btnPickColor'].onclick = () => {
    colorPick = true; calMode = false; setMode('pick color (click on ball)');
    if (el['btnCalSave']) el['btnCalSave'].style.display = 'none';
    redrawOverlay();
  };
  canvas.addEventListener('click', async (ev) => {
    if (!colorPick) return;
    const {sx, sy} = screenToServerScale();
    const x = Math.round(ev.offsetX / sx);
    const y = Math.round(ev.offsetY / sy);
    colorPick = false; setMode('view');
    try {
      await fetch('/pick/ball', { method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({ x, y }) });
    } catch(e) {}
  });

  if (el['btnCalLine']) el['btnCalLine'].onclick = () => {
    calMode = true; colorPick = false;
    if (!calLine) {
      calLine = { x1: Math.round(dims.w*0.2), y1: Math.round(dims.h*0.5),
                  x2: Math.round(dims.w*0.8), y2: Math.round(dims.h*0.5) };
    }
    setMode('calibrate line (drag ends)');
    if (el['btnCalSave']) el['btnCalSave'].style.display = 'inline-block';
    redrawOverlay();
  };
  if (el['btnCalSave']) el['btnCalSave'].onclick = async () => {
    if (!calLine) return;
    const yards = 1.0;
    try {
      await fetch('/calibration/line', {
        method:'POST', headers:{'Content-Type':'application/json'},
        body: JSON.stringify({ ...calLine, yards, save: true })
      });
      setMode('view'); calMode = false; el['btnCalSave'].style.display = 'none';
    } catch(e){}
  };

  function setMode(str){
    if (modePill) modePill.textContent = `mode: ${str}`;
  }

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

    if (el['show_mask']) el['show_mask'].checked = !!cfg.show_mask;
    if (el['input.playback_speed']) el['input.playback_speed'].value = cfg.input?.playback_speed ?? 1.0;
    if (el['cal.px_per_yard']) el['cal.px_per_yard'].value = cfg.calibration?.px_per_yard ?? 1.0;

    redrawOverlay();
  }

  // init
  loadSettings();
})();
