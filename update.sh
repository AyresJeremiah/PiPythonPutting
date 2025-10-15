#!/bin/bash
set -euo pipefail

ROOT="$(pwd)"
CAP="src/camera/capture.py"
MAIN="src/main.py"
SETT="settings.json"

[ -f "$CAP" ]  || { echo "❌ $CAP not found"; exit 1; }
[ -f "$MAIN" ] || { echo "❌ $MAIN not found"; exit 1; }
[ -f "$SETT" ] || { echo "❌ $SETT not found"; exit 1; }

# 0) Ensure package inits exist
for d in src src/camera src/tracking src/services src/ui src/utils; do
  [ -d "$d" ] || { echo "❌ missing dir $d"; exit 1; }
  [ -f "$d/__init__.py" ] || : > "$d/__init__.py"
done

###############################################################################
# 1) Patch src/camera/capture.py
###############################################################################
python3 - "$CAP" <<'PY'
from pathlib import Path
import re, sys

p = Path(sys.argv[1])
s = p.read_text()

# A) Ensure Camera.__init__ accepts pixel_format and fps; only set FPS if >0
s = re.sub(
r"def __init__\(\s*self,\s*\n\s*source: Union\[int, str] = 0,\s*\n\s*width: Optional\[int] = None,\s*\n\s*height: Optional\[int] = None,\s*\n\s*loop: bool = False,\s*\n\s*request_mjpg60: bool = True\s*\n\s*\)",
"""def __init__(
        self,
        source: Union[int, str] = 0,
        width: Optional[int] = None,
        height: Optional[int] = None,
        loop: bool = False,
        request_mjpg60: bool = True,
        pixel_format: Optional[str] = None,
        fps: Optional[int] = None
    )""",
    s, count=1
)

# B) Prefer provided pixel_format; otherwise keep MJPG hint
s = s.replace(
"""if request_mjpg60:
                try:
                    self._cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"MJPG"))
                except Exception:
                    pass""",
"""if pixel_format:
                try:
                    self._cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*pixel_format))
                except Exception:
                    pass
            elif request_mjpg60:
                try:
                    self._cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"MJPG"))
                except Exception:
                    pass"""
)

# C) Only set FPS if >0
s = s.replace(
"""# Ask for 60 FPS (camera/driver may negotiate differently)
            try:
                self._cap.set(cv2.CAP_PROP_FPS, 60)
            except Exception:
                pass""",
"""# Ask for FPS if provided (driver may negotiate differently)
            try:
                if fps and int(fps) > 0:
                    self._cap.set(cv2.CAP_PROP_FPS, int(fps))
            except Exception:
                pass"""
)

# D) Add apply_format() for live preview changes (idempotent)
if "def apply_format(" not in s:
    s = s.replace(
        "# ---------------- public API ----------------",
        """def apply_format(self, fourcc: str = None, width: int = None, height: int = None, fps: int = None):
        \"\"\"Best-effort live reconfigure. Some backends require reopen; we try in-place.\"\"\"\n        try:
            if fourcc:
                self._cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*fourcc))
            if width:
                self._cap.set(cv2.CAP_PROP_FRAME_WIDTH, int(width))
            if height:
                self._cap.set(cv2.CAP_PROP_FRAME_HEIGHT, int(height))
            if fps and int(fps) > 0:
                self._cap.set(cv2.CAP_PROP_FPS, int(fps))
        except Exception:
            pass

    # ---------------- public API ----------------""",
        1
    )

# E) Add PiCam2Camera if missing (keeps OpenCV Camera intact)
if "class PiCam2Camera" not in s:
    s += """

class PiCam2Camera:
    \"\"\"Picamera2 capture feeding numpy frames to OpenCV pipeline.\"\"\"
    def __init__(self, width=1332, height=990, fps=120, shutter_us=None, gain=None, denoise="off"):
        from picamera2 import Picamera2
        try:
            from libcamera import controls  # noqa: F401
        except Exception:
            pass
        import threading, time

        self.picam2 = Picamera2()
        cfg = self.picam2.create_video_configuration(
            main={\"size\": (int(width), int(height)), \"format\": \"RGB888\"},
        )
        self.picam2.configure(cfg)

        # FrameDurationLimits = 1e6/fps (microseconds). If fps is falsy, skip.
        if fps:
            try:
                self.picam2.set_controls({\"FrameDurationLimits\": (int(1e6//fps), int(1e6//fps))})
            except Exception:
                pass

        if shutter_us:
            try: self.picam2.set_controls({\"ExposureTime\": int(shutter_us)})
            except Exception: pass

        if gain:
            try: self.picam2.set_controls({\"AnalogueGain\": float(gain)})
            except Exception: pass

        if denoise:
            try: self.picam2.set_controls({\"NoiseReductionMode\": denoise})
            except Exception: pass

        self.picam2.start()
        self._frame = None
        self._lock = threading.Lock()
        self._stop = False

        def _reader():
            while not self._stop:
                arr = self.picam2.capture_array()  # RGB888 numpy
                with self._lock:
                    self._frame = arr
            try:
                self.picam2.stop()
            except Exception:
                pass

        self._t = threading.Thread(target=_reader, daemon=True)
        self._t.start()

    def stream(self):
        import time
        while not self._stop and self._frame is None:
            time.sleep(0.001)
        while not self._stop:
            with self._lock:
                f = None if self._frame is None else self._frame.copy()
            if f is not None:
                yield f
            else:
                time.sleep(0.001)

    def read_once(self):
        with self._lock:
            return None if self._frame is None else self._frame.copy()

    def pause(self):
        self._stop = True

    def resume(self):
        if self._stop:
            self._stop = False

    def close(self):
        self._stop = True
        try:
            self.picam2.stop()
        except Exception:
            pass

    def negotiated(self):
        try:
            s = self.picam2.stream_configuration(\"main\")[\"size\"]
            return int(s[0]), int(s[1]), 0.0
        except Exception:
            return 0,0,0.0
"""

p.write_text(s)
print("✅ Patched:", p)
PY

###############################################################################
# 2) Patch src/main.py to select backend and use absolute src.* imports
###############################################################################
python3 - "$MAIN" <<'PY'
from pathlib import Path
import re, sys

p = Path(sys.argv[1])
s = p.read_text()

# A) Ensure absolute imports from src.
s = re.sub(r"\bfrom\s+camera\.capture\s+import\s+Camera\b", "from src.camera.capture import Camera as CvCamera", s)
s = re.sub(r"\bfrom\s+src\.camera\.capture\s+import\s+Camera\b", "from src.camera.capture import Camera as CvCamera", s)
if "PiCam2Camera" not in s:
    # add PiCam2Camera import alongside CvCamera
    s = s.replace("from src.camera.capture import Camera as CvCamera", "from src.camera.capture import Camera as CvCamera, PiCam2Camera")

# Allow absolute src imports for others too (idempotent no-ops if already absolute)
s = re.sub(r"\bfrom\s+tracking\.", "from src.tracking.", s)
s = re.sub(r"\bfrom\s+services\.", "from src.services.", s)
s = re.sub(r"\bfrom\s+utils\.", "from src.utils.", s)
s = re.sub(r"\bfrom\s+ui\.", "from src.ui.", s)
s = re.sub(r"\bimport\s+settings\s+as\s+appsettings\b", "from src import settings as appsettings", s)
s = s.replace("from src.services.gspro import post_shot", "from src.services.gspro import post_shot")

# B) Replace camera creation with backend switch (video | picam2 | v4l2)
if "backend = inp.get(\"backend\"" not in s:
    s = re.sub(
        r"(# Input source[\s\S]+?)(\n\s*detector\s*=\s*BallDetector\(\))",
        r"""# Input source
    inp = cfg.get("input", {})
    cam_cfg = cfg.get("camera", {})
    backend = inp.get("backend", "v4l2")  # "picam2" on Pi, "v4l2" elsewhere

    if inp.get("source", "camera") == "video":
        camera = CvCamera(source=inp.get("video_path","testdata/my_putt.mp4"), loop=bool(inp.get("loop", True)))
        is_video = True
    else:
        is_video = False
        if backend == "picam2":
            camera = PiCam2Camera(
                width=cam_cfg.get("width", 1332),
                height=cam_cfg.get("height", 990),
                fps=cam_cfg.get("fps", 120),
                shutter_us=cam_cfg.get("shutter_us", 5000),
                gain=cam_cfg.get("gain", 1.5),
                denoise=cam_cfg.get("denoise", "off"),
            )
        else:
            camera = CvCamera(
                source=inp.get("camera_index", 0),
                width=cam_cfg.get("width", 1280),
                height=cam_cfg.get("height", 720),
                pixel_format=cam_cfg.get("fourcc", "YUYV"),
                fps=cam_cfg.get("fps", 0)  # 0 => don't force fps
            )
"""+r"\2",
        s, count=1, flags=re.S
    )

# C) After tracker creation, set dt override when video or picam2 fps known
if "tracker.set_dt_override" not in s:
    s = s.replace(
        "tracker  = MotionTracker()",
        """tracker  = MotionTracker()
    try:
        if 'is_video' in locals() and is_video:
            # use encoded fps for dt if possible
            pass
        else:
            # picam2/v4l2 dt: use camera fps if given
            fps_cfg = cam_cfg.get("fps", 0)
            if fps_cfg and int(fps_cfg) > 0:
                tracker.set_dt_override(1.0/float(fps_cfg))
    except Exception:
        pass"""
    )

p.write_text(s)
print("✅ Patched:", p)
PY

###############################################################################
# 3) Update settings.json with backend + camera fields
###############################################################################
python3 - "$SETT" <<'PY'
import json, sys, os
path = sys.argv[1]
with open(path, "r") as f:
    cfg = json.load(f)

inp = cfg.setdefault("input", {})
inp.setdefault("source", "camera")
inp.setdefault("camera_index", 0)
inp.setdefault("backend", "picam2")  # default to picam2 on Pi; change to v4l2 if needed
inp.setdefault("playback_speed", 1.0)
inp.setdefault("loop", True)

cam = cfg.setdefault("camera", {})
cam.setdefault("fourcc", "YUYV")   # used only for v4l2 path
cam.setdefault("width", 1332)
cam.setdefault("height", 990)
cam.setdefault("fps", 120)         # Picamera2 target FPS; v4l2 ignores if driver doesn't support
cam.setdefault("shutter_us", 5000) # 5ms exposure (Picamera2)
cam.setdefault("gain", 1.5)
cam.setdefault("denoise", "off")
cam.setdefault("exposure_auto", 1) # v4l2 path only
cam.setdefault("wb_auto", 1)       # v4l2 path only

with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
print("✅ Updated settings.json with input.backend and camera fields")
PY

cat <<'INFO'

All set ✅

• Backend switch:
  settings.json → "input": { "backend": "picam2" }  # use "v4l2" for USB cams/desktops

• Camera config on Pi (Picamera2):
  "camera": { "width": 1332, "height": 990, "fps": 120, "shutter_us": 5000, "gain": 1.5, "denoise": "off" }

• Camera config on V4L2 (OpenCV):
  "camera": { "fourcc": "YUYV", "width": 640, "height": 480, "fps": 0, "exposure_auto": 1, "wb_auto": 1 }

Run:
  python -m src.main

If Picamera2 isn't installed yet:
  sudo apt update
  sudo apt install -y python3-picamera2 libcamera-apps

INFO

