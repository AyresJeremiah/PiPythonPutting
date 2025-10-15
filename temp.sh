#!/bin/bash
set -e

[ -d "src" ] || { echo "❌ Run from the repo root (where ./src exists)."; exit 1; }

#############################################
# 1) Overwrite src/ui/webui.py with new APIs
#############################################
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

      GET  /                  -> index.html
      GET  /video.mjpg        -> MJPEG stream
      WS   /ws                -> telemetry push (20Hz)

      GET  /settings          -> current in-memory settings (provided by app)
      POST /settings/preview  -> apply live (no file write)
      POST /settings/save     -> persist to disk

      POST /pick/ball         -> {"x":int,"y":int}
      POST /calibration/line  -> {"x1":int,"y1":int,"x2":int,"y2":int,"yards":float,"save":bool}

    Main should wire:
      web.set_cfg_provider(lambda: cfg)
      web.on_settings_preview(fn_dict)
      web.on_settings_save(fn_dict)
      web.on_ball_pick(fn_dict)           # receives {"x","y"}; return dict for JSON
      web.on_calibration_line(fn_dict)    # receives {...}; return dict for JSON

    Also call:
      web.push_frame(bgr_np)
      web.push_telemetry(dict)

    You can also fetch latest BGR frame:
      frame = web.get_latest_frame()
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

        # NEW endpoints
        self._app.post("/pick/ball")(self._post_pick_ball)
        self._app.post("/calibration/line")(self._post_cal_line)

        self._latest_jpeg: Optional[bytes] = None
        self._latest_bgr = None
        self._frame_cv = Condition()
        self._telemetry: Dict[str, Any] = {}

        self._stop = False
        self._thread = threading.Thread(target=self._run, daemon=True)

        # Callbacks supplied by main
        self._get_cfg_cb: Optional[Callable[[], Dict[str, Any]]] = None
        self._on_preview_cb: Optional[Callable[[Dict[str, Any]], None]] = None
        self._on_save_cb: Optional[Callable[[Dict[str, Any]], None]] = None
        self._on_ball_pick_cb: Optional[Callable[[Dict[str, Any]], Dict[str, Any]]] = None
        self._on_cal_line_cb: Optional[Callable[[Dict[str, Any]], Dict[str, Any]]] = None

    # ---------- wiring from main ----------
    def set_cfg_provider(self, fn: Callable[[], Dict[str, Any]]):
        self._get_cfg_cb = fn

    def on_settings_preview(self, fn: Callable[[Dict[str, Any]], None]):
        self._on_preview_cb = fn

    def on_settings_save(self, fn: Callable[[Dict[str, Any]], None]):
        self._on_save_cb = fn

    def on_ball_pick(self, fn: Callable[[Dict[str, Any]], Dict[str, Any]]):
        self._on_ball_pick_cb = fn

    def on_calibration_line(self, fn: Callable[[Dict[str, Any]], Dict[str, Any]]):
        self._on_cal_line_cb = fn

    # ---------- public API ----------
    def start(self):
        if not self._thread.is_alive():
            self._thread.start()

    def stop(self):
        self._stop = True

    def push_frame(self, bgr_image):
        # Keep raw BGR around for color sampling
        try:
            self._latest_bgr = bgr_image.copy()
        except Exception:
            self._latest_bgr = None

        # Encode once for MJPEG
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

    def get_latest_frame(self):
        return None if self._latest_bgr is None else self._latest_bgr.copy()

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

    # ---- NEW: color pick & calibration line ----
    async def _post_pick_ball(self, request: Request):
        payload = await request.json()
        if self._on_ball_pick_cb:
            try:
                resp = self._on_ball_pick_cb(payload) or {"ok": True}
                return JSONResponse(resp)
            except Exception as e:
                return JSONResponse({"ok": False, "error": str(e)}, status_code=400)
        return JSONResponse({"ok": False, "error": "no handler"}, status_code=500)

    async def _post_cal_line(self, request: Request):
        payload = await request.json()
        if self._on_cal_line_cb:
            try:
                resp = self._on_cal_line_cb(payload) or {"ok": True}
                return JSONResponse(resp)
            except Exception as e:
                return JSONResponse({"ok": False, "error": str(e)}, status_code=400)
        return JSONResponse({"ok": False, "error": "no handler"}, status_code=500)
PY

#############################################
# 2) Patch src/main.py to wire handlers
#############################################
python3 - << 'PY'
from pathlib import Path
import re

p = Path("src/main.py")
src = p.read_text()

# Ensure imports for cv2 & numpy already exist (they do in user's file). We'll just be safe.
if "import cv2" not in src:
    src = "import cv2\n" + src
if "import numpy as np" not in src:
    src = "import numpy as np\n" + src

# Insert handler block if missing
if "_on_ball_pick(" not in src or "_on_cal_line(" not in src:
    # Find a reasonable insertion point: after rebuild_zone_overlay() or after web UI setup comments
    anchor = "rebuild_zone_overlay()"
    pos = src.find(anchor)
    if pos == -1:
        # fallback: after creation of detector/tracker
        anchor = "tracker  = MotionTracker()"
        pos = src.find(anchor)
    insert_after = src.find("\n", pos) + 1 if pos != -1 else len(src)

    handlers = r'''
    # ---- WebUI: ball color pick & calibration-line handlers ----
    def _on_ball_pick(payload: dict):
        """payload: {"x":int,"y":int}
        Samples a 5x5 patch around (x,y) from the latest frame, converts to HSV,
        builds +/- bands, updates cfg['ball_hsv'], and tries to live-apply to detector."""
        try:
            x = int(payload.get("x", 0)); y = int(payload.get("y", 0))
        except Exception:
            return {"ok": False, "error": "invalid xy"}
        # get latest frame (or last frozen)
        try:
            frame = web.get_latest_frame()
        except Exception:
            frame = None
        if frame is None:
            # try to fall back to last displayed frame 'frozen_frame' if exists
            try:
                frame = frozen_frame.copy()
            except Exception:
                return {"ok": False, "error": "no frame available"}

        h, w = frame.shape[:2]
        x1 = max(0, min(w-1, x-2)); x2 = max(1, min(w, x+3))
        y1 = max(0, min(h-1, y-2)); y2 = max(1, min(h, y+3))
        patch = frame[y1:y2, x1:x2].copy()
        if patch.size == 0:
            return {"ok": False, "error": "empty patch"}

        hsv = cv2.cvtColor(patch, cv2.COLOR_BGR2HSV)
        H = int(np.median(hsv[:,:,0])); S = int(np.median(hsv[:,:,1])); V = int(np.median(hsv[:,:,2]))

        # tolerance bands (tweak as needed)
        dh, ds, dv = 10, 70, 70
        lower = [max(0, H-dh), max(0, S-ds), max(0, V-dv)]
        upper = [min(179, H+dh), min(255, S+ds), min(255, V+dv)]

        # update config + live-apply to detector if supported
        try:
            cfg["ball_hsv"] = {"lower": lower, "upper": upper}
        except Exception:
            pass
        if hasattr(detector, "set_hsv"):
            try:
                detector.set_hsv(tuple(lower), tuple(upper))
            except Exception:
                pass

        return {"ok": True, "hsv": [H,S,V], "bounds": {"lower": lower, "upper": upper}}

    def _on_cal_line(payload: dict):
        """payload: {"x1","y1","x2","y2","yards":float (default 1.0), "save":bool}"""
        try:
            x1 = int(payload.get("x1")); y1 = int(payload.get("y1"))
            x2 = int(payload.get("x2")); y2 = int(payload.get("y2"))
        except Exception:
            return {"ok": False, "error": "invalid line endpoints"}
        yards = payload.get("yards", 1.0)
        try:
            yards = float(yards)
            if yards <= 0: yards = 1.0
        except Exception:
            yards = 1.0

        # compute px distance
        dx = float(x2 - x1); dy = float(y2 - y1)
        px = (dx*dx + dy*dy) ** 0.5
        px_per_yard = px / max(1e-6, yards)

        # update cfg
        try:
            cfg.setdefault("calibration", {})
            cfg["calibration"]["px_per_yard"] = float(px_per_yard)
            cfg["calibration"]["line"] = {"x1": int(x1), "y1": int(y1), "x2": int(x2), "y2": int(y2)}
        except Exception:
            pass

        # If your overlay draws the line, you could rebuild here (optional):
        try:
            _rebuild_from_cfg()
        except Exception:
            pass

        # persist if requested
        if bool(payload.get("save", False)):
            try:
                _atomic_write_settings(cfg)
            except Exception:
                pass

        return {"ok": True, "px_per_yard": round(float(px_per_yard), 4)}
'''
    src = src[:insert_after] + handlers + src[insert_after:]

# Ensure we register handlers on the web instance
if "web.on_ball_pick(" not in src or "web.on_calibration_line(" not in src:
    # Find where web is created & started
    m = re.search(r'web\s*=\s*WebUI\(.*?\)\s*\n', src)
    if m:
        insert_at = m.end()
        wiring = "    web.set_cfg_provider(lambda: cfg)\n" \
                 "    web.on_settings_preview(_apply_preview)\n" \
                 "    web.on_settings_save(_apply_save)\n" \
                 "    web.on_ball_pick(_on_ball_pick)\n" \
                 "    web.on_calibration_line(_on_cal_line)\n" \
                 "    web.start()\n"
        # Remove any duplicate set_cfg_provider/on_settings... lines that may already exist
        src = re.sub(r'^\s*web\.set_cfg_provider.*\n', '', src, flags=re.M)
        src = re.sub(r'^\s*web\.on_settings_preview.*\n', '', src, flags=re.M)
        src = re.sub(r'^\s*web\.on_settings_save.*\n', '', src, flags=re.M)
        src = re.sub(r'^\s*web\.start\(\).*\n', '', src, flags=re.M)
        # Insert fresh wiring block
        src = src[:insert_at] + wiring + src[insert_at:]

p.write_text(src)
print("✅ Backend patched: /pick/ball & /calibration/line added, handlers wired in main.py.")
PY

echo "✅ Done. Restart your app and open http://localhost:8080"
echo "• Click “Set ball color” in the web UI, then click on the ball."
echo "• Click “Set pixel→yard”, drag the yellow line ends, then “Save Cal”."
