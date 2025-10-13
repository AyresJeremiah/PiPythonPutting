#!/bin/bash
set -e

if [ ! -d "src" ]; then
  echo "Run this from the putttracker project root (where ./src exists)."
  exit 1
fi

mkdir -p src/ui
: > src/ui/__init__.py

# --- settings helpers: add clamp + set_value (idempotent) ---
cat > src/settings.py << 'EOF'
import json, os
from typing import Any, Dict

SETTINGS_PATH = os.path.join(os.path.dirname(os.path.dirname(__file__)), "settings.json")

_DEFAULTS: Dict[str, Any] = {
    "ball_color": "white",
    "min_ball_radius_px": 3,
    "show_mask": False,
    "target_width": 960,
    "roi": {"startx": None, "endx": None, "starty": None, "endy": None},
}

_cache: Dict[str, Any] = None

def _merge(d, defaults):
    for k, v in defaults.items():
        if k not in d:
            d[k] = v
        elif isinstance(v, dict) and isinstance(d[k], dict):
            _merge(d[k], v)
    return d

def load() -> Dict[str, Any]:
    global _cache
    if _cache is not None:
        return _cache
    if os.path.exists(SETTINGS_PATH):
        with open(SETTINGS_PATH, "r") as f:
            try:
                data = json.load(f)
            except Exception:
                data = {}
    else:
        data = {}
    _cache = _merge(data, _DEFAULTS.copy())
    return _cache

def save():
    if _cache is None:
        return
    with open(SETTINGS_PATH, "w") as f:
        json.dump(_cache, f, indent=2)

def set_value(path, value):
    """path like 'show_mask' or 'roi.startx'."""
    s = load()
    parts = path.split(".")
    ref = s
    for p in parts[:-1]:
        ref = ref[p]
    ref[parts[-1]] = value
    save()

def set_roi(x1, y1, x2, y2):
    s = load()
    s["roi"]["startx"] = int(min(x1, x2))
    s["roi"]["endx"]   = int(max(x1, x2))
    s["roi"]["starty"] = int(min(y1, y2))
    s["roi"]["endy"]   = int(max(y1, y2))
    save()

def ensure_roi_initialized(width: int, height: int):
    s = load()
    roi = s["roi"]
    if None in (roi["startx"], roi["endx"], roi["starty"], roi["endy"]):
        roi["startx"] = 0
        roi["starty"] = 0
        roi["endx"]   = int(width)
        roi["endy"]   = int(height)
        save()

def clamp_roi(width: int, height: int):
    s = load()
    r = s["roi"]
    r["startx"] = max(0, min(int(r["startx"]), width-1))
    r["endx"]   = max(1, min(int(r["endx"]), width))
    r["starty"] = max(0, min(int(r["starty"]), height-1))
    r["endy"]   = max(1, min(int(r["endy"]), height))
    if r["startx"] >= r["endx"]:
        r["endx"] = min(width, r["startx"] + 1)
    if r["starty"] >= r["endy"]:
        r["endy"] = min(height, r["starty"] + 1)
    save()
EOF

# --- slider editor UI ---
cat > src/ui/slider_editor.py << 'EOF'
import cv2
import settings as appsettings

class SliderEditor:
    def __init__(self, window_name="PuttTracker Settings"):
        self.name = window_name
        self.active = False
        self._w = None
        self._h = None
        self._lock = False  # avoid callback recursion

    def _safe_set(self, keypath, value):
        if self._lock:
            return
        self._lock = True
        appsettings.set_value(keypath, value)
        appsettings.save()
        self._lock = False

    def _sync_bounds(self):
        # Keep ROI valid: start < end, within frame
        appsettings.clamp_roi(self._w, self._h)

        s = appsettings.load()
        r = s["roi"]
        cv2.setTrackbarPos("startx", self.name, r["startx"])
        cv2.setTrackbarPos("endx",   self.name, r["endx"])
        cv2.setTrackbarPos("starty", self.name, r["starty"])
        cv2.setTrackbarPos("endy",   self.name, r["endy"])
        cv2.setTrackbarPos("min_radius", self.name, int(s.get("min_ball_radius_px", 3)))
        cv2.setTrackbarPos("mask",       self.name, 1 if s.get("show_mask", False) else 0)
        cv2.setTrackbarPos("preview_w",  self.name, int(s.get("target_width", 960)))

    def _on_startx(self, v):
        self._safe_set("roi.startx", v); appsettings.clamp_roi(self._w, self._h)
    def _on_endx(self, v):
        self._safe_set("roi.endx", v); appsettings.clamp_roi(self._w, self._h)
    def _on_starty(self, v):
        self._safe_set("roi.starty", v); appsettings.clamp_roi(self._w, self._h)
    def _on_endy(self, v):
        self._safe_set("roi.endy", v); appsettings.clamp_roi(self._w, self._h)
    def _on_minr(self, v):
        self._safe_set("min_ball_radius_px", max(0, v))
    def _on_mask(self, v):
        self._safe_set("show_mask", bool(v))
    def _on_previeww(self, v):
        self._safe_set("target_width", max(320, v))

    def open(self, frame_width, frame_height):
        self._w, self._h = int(frame_width), int(frame_height)
        appsettings.ensure_roi_initialized(self._w, self._h)
        appsettings.clamp_roi(self._w, self._h)

        cv2.namedWindow(self.name, cv2.WINDOW_NORMAL)
        cv2.resizeWindow(self.name, 420, 260)

        # Trackbars
        cv2.createTrackbar("startx",   self.name, 0, self._w-1, lambda v: self._on_startx(v))
        cv2.createTrackbar("endx",     self.name, 1, self._w,   lambda v: self._on_endx(v))
        cv2.createTrackbar("starty",   self.name, 0, self._h-1, lambda v: self._on_starty(v))
        cv2.createTrackbar("endy",     self.name, 1, self._h,   lambda v: self._on_endy(v))
        cv2.createTrackbar("min_radius", self.name, 3, 50,      lambda v: self._on_minr(v))
        cv2.createTrackbar("mask",       self.name, 0, 1,       lambda v: self._on_mask(v))
        cv2.createTrackbar("preview_w",  self.name, 960, 1920,  lambda v: self._on_previeww(v))

        self._sync_bounds()
        self.active = True

    def close(self):
        if self.active:
            try:
                cv2.destroyWindow(self.name)
            except Exception:
                pass
        self.active = False

    def toggle(self, frame_width, frame_height):
        if self.active:
            self.close()
        else:
            self.open(frame_width, frame_height)
EOF

# --- main.py: integrate slider editor, remove mouse editor ---
cat > src/main.py << 'EOF'
import cv2
from tracking.ball_detector import BallDetector
from tracking.motion_tracker import MotionTracker
from camera.capture import Camera
from utils.draw_utils import draw_ball, draw_vector, put_hud, draw_roi, banner, help_box
from utils.logger import log
import settings as appsettings
from ui.slider_editor import SliderEditor

def resize_keep_aspect(frame, target_w):
    h, w = frame.shape[:2]
    if w == 0 or h == 0:
        return frame
    scale = target_w / float(w)
    return cv2.resize(frame, (int(w*scale), int(h*scale)))

def inside_roi(pt, roi):
    if pt is None or roi is None:
        return False
    x, y = pt
    x1, y1, x2, y2 = roi
    return x1 <= x <= x2 and y1 <= y <= y2

def main():
    s = appsettings.load()
    show_mask = bool(s.get("show_mask", False))
    target_w = int(s.get("target_width", 960))

    camera = Camera(source=0)
    detector = BallDetector()
    tracker = MotionTracker()

    # Prime first frame to know bounds
    first_frame = next(camera.stream())
    h0, w0 = first_frame.shape[:2]
    appsettings.ensure_roi_initialized(w0, h0)
    appsettings.clamp_roi(w0, h0)
    s = appsettings.load()
    roi = (int(s["roi"]["startx"]), int(s["roi"]["starty"]), int(s["roi"]["endx"]), int(s["roi"]["endy"]))

    cv2.namedWindow("PuttTracker", cv2.WINDOW_NORMAL)
    editor = SliderEditor()

    log("Controls: q=quit | m=mask | a=settings sliders")
    last_pos = None
    last_inside = False
    last_valid_velocity = None
    last_valid_direction = None

    # Iterate with first frame included
    frame_iter = camera.stream()
    def yield_with_first(first, gen):
        yield first
        for f in gen:
            yield f

    for frame in yield_with_first(first_frame, frame_iter):
        s = appsettings.load()
        show_mask = bool(s.get("show_mask", show_mask))
        target_w = int(s.get("target_width", target_w))
        roi = (int(s["roi"]["startx"]), int(s["roi"]["starty"]), int(s["roi"]["endx"]), int(s["roi"]["endy"]))

        center, radius = detector.detect(frame)
        in_area = inside_roi(center, roi)

        velocity, direction = tracker.update(center if in_area else None)
        if velocity is not None:
            last_valid_velocity = velocity
            last_valid_direction = direction

        if last_inside and not in_area:
            if last_valid_velocity is not None:
                log(f"SHOT: vel={last_valid_velocity:.2f} px/s, dir={last_valid_direction:.2f}° (exited ROI)")
        last_inside = in_area

        # Overlays
        draw_ball(frame, center if in_area else None, radius if in_area and radius else 0.0)
        draw_roi(frame, roi)
        if in_area:
            draw_vector(frame, last_pos, center)
        put_hud(frame, velocity if in_area else None, direction if in_area else None, tracker.fps)

        if show_mask and detector.last_mask is not None:
            mask = cv2.cvtColor(detector.last_mask, cv2.COLOR_GRAY2BGR)
            mh, mw = mask.shape[:2]
            roi_small = frame[0:mh, 0:mw]
            cv2.addWeighted(mask, 0.5, roi_small, 0.5, 0, roi_small)

        if editor.active:
            banner(frame, "SLIDER EDIT MODE")
            help_box(frame, [
                "Adjust ROI & settings in the sliders window",
                "a: close sliders | m: toggle mask | q: quit"
            ])

        preview = resize_keep_aspect(frame, target_w)
        cv2.imshow("PuttTracker", preview)

        key = cv2.waitKey(1) & 0xFF
        if key == ord('q'):
            break
        elif key == ord('m'):
            appsettings.set_value("show_mask", not bool(s.get("show_mask", False)))
        elif key == ord('a'):
            editor.toggle(w0, h0)

        last_pos = center if in_area else last_pos

    editor.close()
    cv2.destroyAllWindows()

if __name__ == "__main__":
    main()
EOF

echo "✅ Switched to slider-based settings. Run with:  python3 src/main.py   (press 'a' to open sliders)"
