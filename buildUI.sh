#!/bin/bash
set -e

if [ ! -d "src" ]; then
  echo "Run this from the putttracker project root (where ./src exists)."
  exit 1
fi

# --- settings.json (created if missing) ---
if [ ! -f settings.json ]; then
cat > settings.json << 'EOF'
{
  "ball_color": "white",
  "min_ball_radius_px": 3,
  "show_mask": false,
  "target_width": 960,
  "roi": { "startx": null, "endx": null, "starty": null, "endy": null }
}
EOF
fi

# --- src/settings.py (JSON-backed settings with load/save) ---
cat > src/settings.py << 'EOF'
import json, os
from typing import Any, Dict

SETTINGS_PATH = os.path.join(os.path.dirname(os.path.dirname(__file__)), "settings.json")

_DEFAULTS: Dict[str, Any] = {
    "ball_color": "white",
    "min_ball_radius_px": 3,
    "show_mask": False,
    "target_width": 960,
    # ROI in absolute pixels; if null, will be set to full frame on first run
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
EOF

# --- update draw utils: ROI + banners ---
cat > src/utils/draw_utils.py << 'EOF'
import cv2

def draw_ball(frame, center, radius):
    if center is None:
        return
    (x, y) = center
    cv2.circle(frame, (int(x), int(y)), int(max(2, radius)), (0, 255, 0), 2)
    cv2.circle(frame, (int(x), int(y)), 3, (0, 0, 255), -1)

def draw_vector(frame, p1, p2):
    if p1 is None or p2 is None:
        return
    (x1, y1) = map(int, p1)
    (x2, y2) = map(int, p2)
    cv2.arrowedLine(frame, (x1, y1), (x2, y2), (255, 0, 0), 2, tipLength=0.25)

def put_hud(frame, velocity=None, direction=None, fps=None):
    y = 24
    parts = []
    if velocity is not None:
        parts.append(f"vel: {velocity:.1f} px/s")
    if direction is not None:
        parts.append(f"dir: {direction:.1f}°")
    if fps is not None:
        parts.append(f"fps: {fps:.1f}")
    if not parts:
        parts.append(f"fps: {fps:.1f}" if fps is not None else "")
    text = " | ".join([p for p in parts if p])
    if text:
        cv2.rectangle(frame, (8, 6), (8 + 300, 6 + 24), (0, 0, 0), -1)
        cv2.putText(frame, text, (12, y), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (255,255,255), 1, cv2.LINE_AA)

def draw_roi(frame, roi, color=(0, 200, 255), thickness=2):
    x1, y1, x2, y2 = roi
    cv2.rectangle(frame, (x1, y1), (x2, y2), color, thickness)

def banner(frame, text, color=(0,0,255)):
    h = 32
    w = 10 + len(text) * 14
    cv2.rectangle(frame, (8, 40), (8 + w, 40 + h), (0,0,0), -1)
    cv2.putText(frame, text, (16, 64), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (255,255,255), 2, cv2.LINE_AA)

def help_box(frame, lines):
    width = max([len(s) for s in lines]) if lines else 0
    w = 20 + width * 9
    h = 24 + len(lines) * 18
    cv2.rectangle(frame, (8, 80), (8 + w, 80 + h), (0,0,0), -1)
    y = 100
    for s in lines:
        cv2.putText(frame, s, (16, y), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (255,255,255), 1, cv2.LINE_AA)
        y += 18
EOF

# --- ball detector pulls thresholds from config & settings ---
cat > src/tracking/ball_detector.py << 'EOF'
import cv2
import numpy as np
from config import COLOR_RANGES
from src import settings as appsettings  # for ball_color & min radius

class BallDetector:
    def __init__(self):
        s = appsettings.load()
        color_name = s.get("ball_color", "white")
        color_range = COLOR_RANGES[color_name]
        self.lower = np.array(color_range["lower"], dtype=np.uint8)
        self.upper = np.array(color_range["upper"], dtype=np.uint8)
        self.min_radius = int(s.get("min_ball_radius_px", 3))
        self.last_mask = None

    def detect(self, frame):
        blurred = cv2.GaussianBlur(frame, (5, 5), 0)
        hsv = cv2.cvtColor(blurred, cv2.COLOR_BGR2HSV)

        mask = cv2.inRange(hsv, self.lower, self.upper)
        mask = cv2.erode(mask, None, iterations=1)
        mask = cv2.dilate(mask, None, iterations=2)
        self.last_mask = mask

        contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        if not contours:
            return None, None

        largest = max(contours, key=cv2.contourArea)
        (x, y), radius = cv2.minEnclosingCircle(largest)
        if radius < self.min_radius:
            return None, None

        return (float(x), float(y)), float(radius)
EOF

# --- main.py: ROI gating + 'a' editor + exit shot logging ---
cat > src/main.py << 'EOF'
import cv2
from tracking.ball_detector import BallDetector
from tracking.motion_tracker import MotionTracker
from camera.capture import Camera
from utils.draw_utils import draw_ball, draw_vector, put_hud, draw_roi, banner, help_box
from utils.logger import log
from src import settings as appsettings
from config import COLOR_RANGES  # keep ranges in config.py

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

class ROIEditor:
    def __init__(self, window_name):
        self.window = window_name
        self.editing = False
        self.drawing = False
        self.x1 = self.y1 = self.x2 = self.y2 = 0

    def start(self, frame, roi):
        self.editing = True
        self.drawing = False
        if roi:
            self.x1, self.y1, self.x2, self.y2 = roi
        cv2.setMouseCallback(self.window, self._on_mouse)

    def stop(self):
        self.editing = False
        cv2.setMouseCallback(self.window, lambda *args: None)

    def _on_mouse(self, event, x, y, flags, param):
        if not self.editing:
            return
        if event == cv2.EVENT_LBUTTONDOWN:
            self.drawing = True
            self.x1, self.y1 = x, y
            self.x2, self.y2 = x, y
        elif event == cv2.EVENT_MOUSEMOVE and self.drawing:
            self.x2, self.y2 = x, y
        elif event == cv2.EVENT_LBUTTONUP and self.drawing:
            self.drawing = False
            self.x2, self.y2 = x, y
            # persist immediately
            appsettings.set_roi(self.x1, self.y1, self.x2, self.y2)
            log(f"ROI set to x:[{min(self.x1,self.x2)}, {max(self.x1,self.x2)}] "
                f"y:[{min(self.y1,self.y2)}, {max(self.y1,self.y2)}]")

    def current(self):
        if self.x1==self.x2 or self.y1==self.y2:
            return None
        return (min(self.x1, self.x2), min(self.y1, self.y2),
                max(self.x1, self.x2), max(self.y1, self.y2))

def main():
    s = appsettings.load()
    show_mask = bool(s.get("show_mask", False))
    target_w = int(s.get("target_width", 960))

    camera = Camera(source=0)
    detector = BallDetector()
    tracker = MotionTracker()

    # Initialize ROI based on first frame size if needed
    first_frame = next(camera.stream())
    h0, w0 = first_frame.shape[:2]
    appsettings.ensure_roi_initialized(w0, h0)
    s = appsettings.load()
    roi = (int(s["roi"]["startx"]), int(s["roi"]["starty"]), int(s["roi"]["endx"]), int(s["roi"]["endy"]))

    cv2.namedWindow("PuttTracker", cv2.WINDOW_NORMAL)
    editor = ROIEditor("PuttTracker")

    log("Controls: q=quit | m=mask | a=ROI editor (click-drag, auto-save)")
    last_pos = None
    last_inside = False
    last_valid_velocity = None
    last_valid_direction = None

    # Re-use the first frame we already pulled
    frame_iter = camera.stream()
    def yield_with_first(first, gen):
        yield first
        for f in gen:
            yield f

    for frame in yield_with_first(first_frame, frame_iter):
        # Re-load settings in case user edited externally
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

        # EXIT EVENT: was inside, now outside (or lost)
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

        if editor.editing:
            banner(frame, "ROI EDIT MODE")
            help_box(frame, [
                "Mouse: click-drag to set ROI (auto-saves)",
                "a: exit edit mode",
                "m: toggle mask | q: quit"
            ])
            # also preview the current drag rect if any
            cur = editor.current()
            if cur:
                draw_roi(frame, cur, color=(0,255,255), thickness=2)

        preview = resize_keep_aspect(frame, target_w)
        cv2.imshow("PuttTracker", preview)

        key = cv2.waitKey(1) & 0xFF
        if key == ord('q'):
            break
        elif key == ord('m'):
            s["show_mask"] = not bool(s.get("show_mask", False))
            appsettings.save()
        elif key == ord('a'):
            if editor.editing:
                editor.stop()
            else:
                editor.start(frame, roi)

        last_pos = center if in_area else last_pos

    cv2.destroyAllWindows()

if __name__ == "__main__":
    main()
EOF

echo "✅ ROI & config editor added. Activate your venv and run:  python3 src/main.py"
