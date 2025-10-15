import cv2
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
