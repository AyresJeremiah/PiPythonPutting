#!/bin/bash
set -e

[ -d "src" ] || { echo "❌ Run from the project root (where ./src exists)."; exit 1; }

mkdir -p src/ui web/static

########################################
# 1) Replace/Install WebUI with settings endpoints & callbacks
########################################
cat > src/ui/webui.py << 'PY'
import cv2
import json
import time
import asyncio
import threading
from typing import Optional, Dict, Any, Callable
from pathlib import Path
from threading import Condition

from fastapi import FastAPI, WebSocket, WebSocketDisconnect, Request
from fastapi.responses import FileResponse, StreamingResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
import uvicorn

class WebUI:
    """
    FastAPI server embedded in the app:

      GET  /                 -> index.html
      GET  /video.mjpg       -> MJPEG stream
      WS   /ws               -> telemetry push (20Hz)
      GET  /settings         -> current in-memory settings (provided by app)
      POST /settings/preview -> apply live (no file write)
      POST /settings/save    -> persist to disk (app handles file write safely)

    Main should wire:
      web.set_cfg_provider(lambda: cfg)
      web.on_settings_preview(apply_preview_fn)
      web.on_settings_save(save_fn)

    Also call:
      web.push_frame(bgr_np)
      web.push_telemetry(dict)
    """
    def __init__(self, host: str = "0.0.0.0", port: int = 8080, jpeg_quality: int = 80):
        self.host = host
        self.port = int(port)
        self.jpeg_quality = int(max(40, min(95, jpeg_quality)))

        self._app = FastAPI()
        static_dir = Path(__file__).resolve().parents[2] / "web" / "static"
        self._app.mount("/static", StaticFiles(directory=str(static_dir)), name="static")
        self._app.get("/")(self._index)
        self._app.get("/video.mjpg")(self._mjpeg)
        self._app.websocket("/ws")(self._ws_handler)
        self._app.get("/settings")(self._get_settings)
        self._app.post("/settings/preview")(self._post_preview)
        self._app.post("/settings/save")(self._post_save)

        self._latest_jpeg: Optional[bytes] = None
        self._frame_cv = Condition()
        self._telemetry: Dict[str, Any] = {}

        self._stop = False
        self._thread = threading.Thread(target=self._run, daemon=True)

        # Callbacks supplied by main
        self._get_cfg_cb: Optional[Callable[[], Dict[str, Any]]] = None
        self._on_preview_cb: Optional[Callable[[Dict[str, Any]], None]] = None
        self._on_save_cb: Optional[Callable[[Dict[str, Any]], None]] = None

    # ---------- wiring from main ----------
    def set_cfg_provider(self, fn: Callable[[], Dict[str, Any]]):
        self._get_cfg_cb = fn

    def on_settings_preview(self, fn: Callable[[Dict[str, Any]], None]):
        self._on_preview_cb = fn

    def on_settings_save(self, fn: Callable[[Dict[str, Any]], None]):
        self._on_save_cb = fn

    # ---------- public API ----------
    def start(self):
        if not self._thread.is_alive():
            self._thread.start()

    def stop(self):
        self._stop = True

    def push_frame(self, bgr_image):
        try:
            ok, buf = cv2.imencode(".jpg", bgr_image,
                                   [int(cv2.IMWRITE_JPEG_QUALITY), self.jpeg_quality])
            if not ok:
                return
            jpg = buf.tobytes()
        except Exception:
            return
        with self._frame_cv:
            self._latest_jpeg = jpg
            self._frame_cv.notify_all()

    def push_telemetry(self, payload: Dict[str, Any]):
        self._telemetry = payload

    # ---------- server loop ----------
    def _run(self):
        uvicorn.run(self._app, host=self.host, port=self.port,
                    log_level="warning", access_log=False)

    # ---------- endpoints ----------
    async def _index(self):
        index = Path(__file__).resolve().parents[2] / "web" / "static" / "index.html"
        return FileResponse(str(index))

    async def _mjpeg(self):
        boundary = "frame"
        async def gen():
            from starlette.concurrency import run_in_threadpool
            while not self._stop:
                with self._frame_cv:
                    if self._latest_jpeg is None:
                        self._frame_cv.wait(timeout=0.25)
                        await run_in_threadpool(time.sleep, 0.02)
                        continue
                    data = self._latest_jpeg
                yield (f"--{boundary}\r\n"
                       f"Content-Type: image/jpeg\r\n"
                       f"Content-Length: {len(data)}\r\n\r\n").encode() + data + b"\r\n"
                await run_in_threadpool(time.sleep, 1/30.0)
        return StreamingResponse(gen(),
                                 media_type=f"multipart/x-mixed-replace; boundary={boundary}")

    async def _ws_handler(self, ws: WebSocket):
        await ws.accept()
        try:
            while True:
                await ws.send_json(self._telemetry)
                await asyncio.sleep(0.05)  # 20 Hz
        except WebSocketDisconnect:
            pass
        except Exception:
            pass

    async def _get_settings(self):
        if not self._get_cfg_cb:
            return JSONResponse({"error": "cfg provider not set"}, status_code=500)
        cfg = self._get_cfg_cb()
        # do not allow editing post.host/port from UI; keep but mark read-only client-side
        return JSONResponse(cfg)

    async def _post_preview(self, request: Request):
        payload = await request.json()
        if self._on_preview_cb:
            try:
                self._on_preview_cb(payload)
            except Exception as e:
                return JSONResponse({"ok": False, "error": str(e)}, status_code=400)
        return JSONResponse({"ok": True})

    async def _post_save(self, request: Request):
        payload = await request.json()
        if self._on_save_cb:
            try:
                self._on_save_cb(payload)
            except Exception as e:
                return JSONResponse({"ok": False, "error": str(e)}, status_code=400)
        return JSONResponse({"ok": True})
PY

########################################
# 2) Frontend: add settings panel (index.html & app.js)
########################################
cat > web/static/index.html << 'HTML'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8"/>
  <title>PuttTracker Web UI</title>
  <meta name="viewport" content="width=device-width,initial-scale=1"/>
  <style>
    :root { color-scheme: dark; }
    body { margin: 0; background: #0b0b0e; color: #e5e7eb; font-family: system-ui, -apple-system, Segoe UI, Roboto, sans-serif; }
    header { padding: 8px 12px; background:#111318; display:flex; align-items:center; gap:12px; position:sticky; top:0; z-index:10; }
    .dot { width:10px; height:10px; border-radius:50%; display:inline-block; }
    #status.green{ background:#16a34a; } #status.yellow{ background:#f59e0b; } #status.red{ background:#ef4444; }
    #wrap { position:relative; width:100%; max-width: 1100px; margin: 8px auto; }
    #video { width:100%; display:block; }
    #overlay { position:absolute; inset:0; pointer-events:none; }
    #metrics { padding:8px 12px; font-size: 14px; color:#cbd5e1; display:flex; gap:16px; flex-wrap:wrap }
    code { color:#93c5fd; }
    #panel { max-width:1100px; margin: 8px auto; background:#10131a; border:1px solid #222; border-radius:12px; padding:12px }
    fieldset { border:1px solid #222; border-radius:8px; padding:10px; margin:10px 0 }
    legend { padding: 0 6px; color:#a3b3d3; }
    label { display:flex; align-items:center; gap:8px; margin:6px 0; font-size:14px }
    input[type="number"] { width:90px; background:#0c0f14; color:#e5e7eb; border:1px solid #222; border-radius:6px; padding:6px }
    input[type="checkbox"] { transform: scale(1.1); }
    button { background:#1e293b; color:#e5e7eb; border:1px solid #334155; padding:8px 12px; border-radius:8px; cursor:pointer; }
    button:hover { background:#243244; }
    .row { display:flex; gap:12px; flex-wrap:wrap }
    .grow { flex:1 }
    .readonly { opacity: .6; }
  </style>
</head>
<body>
<header>
  <strong>PuttTracker</strong>
  <span id="state">IDLE</span>
  <span class="dot" id="status"></span>
  <div class="grow"></div>
  <button id="btnReload">Reload</button>
  <button id="btnApply">Apply (Live)</button>
  <button id="btnSave">Save to settings.json</button>
</header>

<div id="wrap">
  <img id="video" src="/video.mjpg" alt="video"/>
  <canvas id="overlay"></canvas>
</div>

<div id="metrics">
  <div>mph: <code id="mph">0.0</code></div>
  <div>yds/s: <code id="yps">0.00</code></div>
  <div>HLA: <code id="hla">0.0°</code></div>
  <div>FPS: <code id="fps">0</code></div>
</div>

<div id="panel">
  <fieldset>
    <legend>General</legend>
    <div class="row">
      <label>Target width <input type="number" id="target_width"></label>
      <label>Min report mph <input type="number" step="0.1" id="min_report_mph"></label>
      <label>Show mask <input type="checkbox" id="show_mask"></label>
    </div>
  </fieldset>

  <fieldset>
    <legend>Input</legend>
    <div class="row">
      <label>Source (camera/video) <input type="text" id="input.source"></label>
      <label>Video path <input class="grow" type="text" id="input.video_path"></label>
      <label>Loop <input type="checkbox" id="input.loop"></label>
      <label>Playback speed <input type="number" step="0.1" id="input.playback_speed"></label>
    </div>
  </fieldset>

  <fieldset>
    <legend>ROI / Zones</legend>
    <div>ROI: <label>x1 <input type="number" id="roi.startx"></label>
             <label>y1 <input type="number" id="roi.starty"></label>
             <label>x2 <input type="number" id="roi.endx"></label>
             <label>y2 <input type="number" id="roi.endy"></label></div>
    <div style="height:6px"></div>
    <div>Stage: <label>x1 <input type="number" id="zones.stage_roi.x1"></label>
               <label>y1 <input type="number" id="zones.stage_roi.y1"></label>
               <label>x2 <input type="number" id="zones.stage_roi.x2"></label>
               <label>y2 <input type="number" id="zones.stage_roi.y2"></label></div>
    <div>Track: <label>x1 <input type="number" id="zones.track_roi.x1"></label>
               <label>y1 <input type="number" id="zones.track_roi.y1"></label>
               <label>x2 <input type="number" id="zones.track_roi.x2"></label>
               <label>y2 <input type="number" id="zones.track_roi.y2"></label></div>
  </fieldset>

  <fieldset>
    <legend>Detection</legend>
    <div class="row">
      <label>Scale (0.25..1.0) <input type="number" step="0.05" id="detect.scale"></label>
      <label>Min radius px <input type="number" id="detect.min_radius"></label>
    </div>
  </fieldset>

  <fieldset>
    <legend>Calibration</legend>
    <div class="row">
      <label>px/yard <input type="number" step="0.01" id="calibration.px_per_yard"></label>
    </div>
  </fieldset>

  <fieldset>
    <legend>POST (read-only)</legend>
    <div class="row readonly">
      <label>host <input type="text" id="post.host" disabled></label>
      <label>port <input type="number" id="post.port" disabled></label>
      <label>path <input type="text" id="post.path"></label>
    </div>
  </fieldset>
</div>

<script src="/static/app.js"></script>
</body>
</html>
HTML

cat > web/static/app.js << 'JS'
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
JS

########################################
# 3) Patch main.py to wire live preview & save
########################################
python3 - << 'PY'
from pathlib import Path
import re, json, os

p = Path("src/main.py")
s = p.read_text()

# Ensure imports
if "from ui.webui import WebUI" not in s:
    s = s.replace(
        "from ui.preview import PreviewUI",
        "from ui.preview import PreviewUI\nfrom ui.webui import WebUI"
    )

# Ensure web is created/started (after ui.start())
if "web = WebUI(" not in s:
    s = s.replace("ui.start()\n", "ui.start()\n    web = WebUI(port=8080, jpeg_quality=80)\n    web.start()\n")

# Add settings handlers: preview & save
if "def _apply_preview(" not in s:
    insert_anchor = "    # First frame + zones"
    handler_block = '''
    # ---- Settings management (live preview + save) ----
    def _atomic_write_settings(cfg_dict):
        # write to project-root settings.json atomically
        import tempfile, json, os
        settings_path = os.path.join(os.path.dirname(os.path.dirname(__file__)), "settings.json")
        d = os.path.dirname(settings_path)
        os.makedirs(d, exist_ok=True)
        fd, tmp = tempfile.mkstemp(prefix="settings.", suffix=".json", dir=d)
        try:
            with os.fdopen(fd, "w") as f:
                json.dump(cfg_dict, f, indent=2)
            os.replace(tmp, settings_path)
        finally:
            try: os.remove(tmp)
            except Exception: pass

    def _rebuild_from_cfg():
        nonlocal target_w, min_mph, inp, px_per_yd, detect_scale, stage, track, zone_overlay, wait_ms, is_video
        # refresh scalars
        target_w   = int(cfg.get("target_width", target_w))
        min_mph    = float(cfg.get("min_report_mph", min_mph))
        inp        = cfg.get("input", inp)
        px_per_yd  = cfg.get("calibration",{}).get("px_per_yard", px_per_yd)
        detect_scale = float(cfg.get("detect",{}).get("scale", detect_scale))
        if detect_scale <= 0 or detect_scale > 1.0:
            detect_scale = 1.0
        # clamp & refresh rects from cfg
        stage = cfg["zones"]["stage_roi"]
        track = cfg["zones"]["track_roi"]
        # rebuild overlay
        canvas = np.zeros_like(first_frame)
        draw_zone(canvas, stage, "STAGE", (0, 200, 255))
        draw_zone(canvas, track, "TRACK", (0, 180, 0))
        zone_overlay = canvas
        # refresh UI width
        try:
            ui.set_target_width(target_w)
        except Exception:
            pass
        # refresh video pacing if source/video/playback changed
        is_video = (inp.get("source") == "video")
        if is_video:
            import cv2 as _cv2
            cap_tmp = _cv2.VideoCapture(inp.get("video_path", "testdata/my_putt.mp4"))
            vid_fps = cap_tmp.get(_cv2.CAP_PROP_FPS) or 30.0
            cap_tmp.release()
            try: tracker.set_dt_override(1.0/float(vid_fps))
            except Exception: pass
            try:
                wait_ms = max(1, int(round(1000.0 / (float(vid_fps) * max(0.01, float(inp.get("playback_speed",1.0)))))))
            except Exception:
                wait_ms = 33
        else:
            try: tracker.set_dt_override(None)
            except Exception: pass

    def _apply_preview(new_cfg: dict):
        # Merge shallow dicts safely (keep shapes)
        def deep_merge(dst, src):
            for k,v in src.items():
                if isinstance(v, dict) and isinstance(dst.get(k), dict):
                    deep_merge(dst[k], v)
                else:
                    dst[k] = v
        deep_merge(cfg, new_cfg)
        _rebuild_from_cfg()

    def _apply_save(new_cfg: dict):
        # same merge then persist
        _apply_preview(new_cfg)
        _atomic_write_settings(cfg)

    '''
    s = s.replace(insert_anchor, handler_block + "    # First frame + zones")

# Hook web callbacks and provider (after web.start())
if "web.set_cfg_provider(" not in s:
    s = s.replace(
        "web.start()\n",
        "web.start()\n    web.set_cfg_provider(lambda: cfg)\n    web.on_settings_preview(_apply_preview)\n    web.on_settings_save(_apply_save)\n"
    )

# Ensure after every ui.show(disp) we also push to web (if not already present). Keep existing ones.
# (Skip—assume previous web push code exists.)

Path("src/main.py").write_text(s)
print("✅ Wired main.py for live preview + save via WebUI.")
PY

echo "✅ Done. Start your app, open http://localhost:8080"
echo "If needed: source .venv/bin/activate && pip install fastapi 'uvicorn[standard]' starlette"
