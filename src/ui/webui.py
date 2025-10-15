import cv2
import json
import time
import asyncio
import threading
from typing import Optional, Dict, Any, List
from pathlib import Path
from threading import Condition

from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
import uvicorn

class WebUI:
    """
    Tiny FastAPI server:

      GET  /            -> index.html
      GET  /video.mjpg  -> MJPEG live stream (downsampled by JPEG quality)
      WS   /ws          -> server-push telemetry ~20 Hz (client doesn't need to send)

    Use:
      web = WebUI(port=8080)
      web.start()
      ...
      web.push_frame(bgr_frame)
      web.push_telemetry({...})
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

        self._latest_jpeg: Optional[bytes] = None
        self._frame_cv = Condition()
        self._telemetry: Dict[str, Any] = {}

        self._clients: List[WebSocket] = []
        self._stop = False
        self._thread = threading.Thread(target=self._run, daemon=True)

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

    # ---------- server ----------
    def _run(self):
        uvicorn.run(self._app, host=self.host, port=self.port,
                    log_level="warning", access_log=False)

    async def _index(self):
        index = Path(__file__).resolve().parents[2] / "web" / "static" / "index.html"
        return FileResponse(str(index))

    async def _mjpeg(self):
        boundary = "frame"

        async def gen():
            from starlette.concurrency import run_in_threadpool
            # simple keep-alive frame-less chunks until first frame arrives
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
                await run_in_threadpool(time.sleep, 1/30.0)  # ~30 fps write
        return StreamingResponse(gen(),
                                 media_type=f"multipart/x-mixed-replace; boundary={boundary}")

    async def _ws_handler(self, ws: WebSocket):
        await ws.accept()
        self._clients.append(ws)
        try:
            while True:
                # Push telemetry ~20 Hz; don't wait for client messages
                try:
                    await ws.send_text(json.dumps(self._telemetry))
                except Exception:
                    break
                await asyncio.sleep(0.05)
        except WebSocketDisconnect:
            pass
        except Exception:
            pass
        finally:
            if ws in self._clients:
                self._clients.remove(ws)
