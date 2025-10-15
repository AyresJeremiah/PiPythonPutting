(() => {
  const img = document.getElementById('video');
  const canvas = document.getElementById('overlay');
  const ctx = canvas.getContext('2d');

  const elState = document.getElementById('state');
  const elStatus= document.getElementById('status');
  const elMPH   = document.getElementById('mph');
  const elYPS   = document.getElementById('yps');
  const elHLA   = document.getElementById('hla');
  const elFPS   = document.getElementById('fps');

  function fitCanvas() {
    canvas.width  = img.clientWidth || canvas.width;
    canvas.height = img.clientHeight || canvas.height;
  }
  window.addEventListener('resize', fitCanvas);
  img.addEventListener('load', fitCanvas);
  fitCanvas();

  function drawRect(rc, color, label) {
    if (!rc) return;
    ctx.strokeStyle = color;
    ctx.lineWidth = 2;
    ctx.strokeRect(rc.x1, rc.y1, rc.x2-rc.x1, rc.y2-rc.y1);
    if (label) {
      ctx.fillStyle = color;
      ctx.font = '14px system-ui, sans-serif';
      ctx.fillText(label, rc.x1+6, rc.y1+18);
    }
  }
  function drawDot(x, y, r, color) {
    ctx.beginPath();
    ctx.arc(x, y, r || 5, 0, Math.PI*2);
    ctx.fillStyle = color;
    ctx.fill();
  }
  function setStatus(state, centerPresent) {
    elState.textContent = state || 'IDLE';
    let c = 'yellow';
    if (state === 'TRACKING') c = 'green';
    if (state === 'COOLDOWN') c = 'yellow';
    if (state && state.startsWith('SHOT')) c = 'red';
    if (!centerPresent) c = 'yellow';
    elStatus.className = `dot ${c}`;
  }

  // ---- Telemetry WS ----
  const proto = (location.protocol === 'https:') ? 'wss' : 'ws';
  const ws = new WebSocket(`${proto}://${location.host}/ws`);
  ws.onmessage = (ev) => {
    let data; try { data = JSON.parse(ev.data) } catch { return; }
    const W = (data.dims && data.dims.w) || img.naturalWidth || canvas.width;
    const H = (data.dims && data.dims.h) || img.naturalHeight || canvas.height;
    const sx = canvas.width / (W || 1);
    const sy = canvas.height / (H || 1);

    ctx.clearRect(0, 0, canvas.width, canvas.height);
    if (data.stage) drawRect(scaleRect(data.stage, sx, sy), '#0ff', 'STAGE');
    if (data.track) drawRect(scaleRect(data.track, sx, sy), '#0f0', 'TRACK');
    if (data.ball) drawDot(data.ball.x * sx, data.ball.y * sy, 5, '#fff');

    elMPH.textContent = (data.mph ?? 0).toFixed(1);
    elYPS.textContent = (data.yps ?? 0).toFixed(2);
    elHLA.textContent = ((data.hla ?? 0)).toFixed(1) + '°';
    elFPS.textContent = Math.round(data.fps ?? 0);
    setStatus(data.state, !!data.ball);
  };
  function scaleRect(rc, sx, sy) {
    return { x1: Math.round(rc.x1*sx), y1: Math.round(rc.y1*sy), x2: Math.round(rc.x2*sx), y2: Math.round(rc.y2*sy) };
  }

  // ---- Settings panel ----
  const ids = [
    "target_width","min_report_mph","show_mask",
    "input.source","input.video_path","input.loop","input.playback_speed",
    "roi.startx","roi.starty","roi.endx","roi.endy",
    "zones.stage_roi.x1","zones.stage_roi.y1","zones.stage_roi.x2","zones.stage_roi.y2",
    "zones.track_roi.x1","zones.track_roi.y1","zones.track_roi.x2","zones.track_roi.y2",
    "detect.scale","detect.min_radius",
    "calibration.px_per_yard",
    "post.host","post.port","post.path"
  ];
  const el = Object.fromEntries(ids.map(id => [id, document.getElementById(id)]));

  async function loadSettings() {
    const res = await fetch('/settings');
    const cfg = await res.json();
    set('target_width', cfg.target_width);
    set('min_report_mph', cfg.min_report_mph);
    set('show_mask', !!cfg.show_mask);

    set('input.source', cfg.input?.source ?? 'camera');
    set('input.video_path', cfg.input?.video_path ?? '');
    set('input.loop', !!cfg.input?.loop);
    set('input.playback_speed', cfg.input?.playback_speed ?? 1.0);

    const roi = cfg.roi || {};
    set('roi.startx', roi.startx); set('roi.starty', roi.starty);
    set('roi.endx', roi.endx);     set('roi.endy', roi.endy);

    const st = cfg.zones?.stage_roi || {};
    set('zones.stage_roi.x1', st.x1); set('zones.stage_roi.y1', st.y1);
    set('zones.stage_roi.x2', st.x2); set('zones.stage_roi.y2', st.y2);

    const tr = cfg.zones?.track_roi || {};
    set('zones.track_roi.x1', tr.x1); set('zones.track_roi.y1', tr.y1);
    set('zones.track_roi.x2', tr.x2); set('zones.track_roi.y2', tr.y2);

    set('detect.scale', cfg.detect?.scale ?? 1.0);
    set('detect.min_radius', cfg.detect?.min_radius ?? 3);

    set('calibration.px_per_yard', cfg.calibration?.px_per_yard ?? 1);

    set('post.host', cfg.post?.host ?? '');   // read-only
    set('post.port', cfg.post?.port ?? 0);    // read-only
    set('post.path', cfg.post?.path ?? '/putting');
  }
  function set(id, v) {
    if (!(id in el) || el[id] === null) return;
    if (el[id].type === 'checkbox') el[id].checked = !!v;
    else el[id].value = (v ?? '');
  }
  function getCfgFromInputs() {
    const v = (id) => (el[id]?.type === 'checkbox' ? !!el[id].checked : (Number.isNaN(+el[id].value) ? el[id].value : +el[id].value));
    return {
      target_width: +el["target_width"].value || 960,
      min_report_mph: +el["min_report_mph"].value || 1.0,
      show_mask: !!el["show_mask"].checked,
      input: {
        source: el["input.source"].value || "camera",
        video_path: el["input.video_path"].value || "",
        loop: !!el["input.loop"].checked,
        playback_speed: +el["input.playback_speed"].value || 1.0
      },
      roi: {
        startx: +el["roi.startx"].value || 0,
        starty: +el["roi.starty"].value || 0,
        endx: +el["roi.endx"].value || 0,
        endy: +el["roi.endy"].value || 0
      },
      zones: {
        stage_roi: {
          x1: +el["zones.stage_roi.x1"].value || 0,
          y1: +el["zones.stage_roi.y1"].value || 0,
          x2: +el["zones.stage_roi.x2"].value || 1,
          y2: +el["zones.stage_roi.y2"].value || 1
        },
        track_roi: {
          x1: +el["zones.track_roi.x1"].value || 0,
          y1: +el["zones.track_roi.y1"].value || 0,
          x2: +el["zones.track_roi.x2"].value || 1,
          y2: +el["zones.track_roi.y2"].value || 1
        }
      },
      detect: {
        scale: +el["detect.scale"].value || 1.0,
        min_radius: +el["detect.min_radius"].value || 3
      },
      calibration: {
        px_per_yard: +el["calibration.px_per_yard"].value || 1.0
      },
      post: {
        host: el["post.host"].value,  // read-only in UI, but keep in payload
        port: +el["post.port"].value,
        path: el["post.path"].value || "/putting"
      }
    };
  }

  document.getElementById('btnReload').onclick = loadSettings;
  document.getElementById('btnApply').onclick = async () => {
    const cfg = getCfgFromInputs();
    await fetch('/settings/preview', { method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(cfg) });
  };
  document.getElementById('btnSave').onclick = async () => {
    const cfg = getCfgFromInputs();
    await fetch('/settings/save', { method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(cfg) });
  };

  loadSettings();
})();
