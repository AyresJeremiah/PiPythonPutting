#!/bin/bash
set -e

if [ ! -d "src" ]; then
  echo "Run this from the project root (where ./src exists)."
  exit 1
fi

# 1) Extend settings schema: add ball_hsv (lower/upper)
python3 - << 'PY'
import json, os
p="settings.json"
if os.path.exists(p):
    s=json.load(open(p))
else:
    s={}
s.setdefault("ball_color","white")
s.setdefault("ball_hsv", {"lower": None, "upper": None})
json.dump(s, open(p,"w"), indent=2)
PY

cat > src/settings.py << 'EOF'
import json, os
from typing import Any, Dict

SETTINGS_PATH = os.path.join(os.path.dirname(os.path.dirname(__file__)), "settings.json")

_DEFAULTS: Dict[str, Any] = {
    "ball_color": "white",                 # named fallback ('white', 'yellow', etc.)
    "ball_hsv": {"lower": None, "upper": None},  # custom HSV overrides if set
    "min_ball_radius_px": 3,
    "show_mask": False,
    "target_width": 960,
    "min_report_mph": 1.0,
    "roi": {"startx": None, "endx": None, "starty": None, "endy": None},
    "calibration": {
        "px_per_yard": None,
        "yards_length": 1.0,
        "line": {"x1": 100, "y1": 100, "x2": 400, "y2": 100}
    },
    "post": {
        "enabled": True,
        "host": "10.10.10.23",
        "port": 8888,
        "path": "/putting",
        "timeout_sec": 2.5
    }
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
    """path like 'show_mask' or 'roi.startx' or 'ball_hsv.lower'."""
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

def clamp_calibration(width:int, height:int):
    s = load()
    L = s["calibration"]["line"]
    for k in ("x1","x2"):
        L[k] = max(0, min(int(L[k]), width-1))
    for k in ("y1","y2"):
        L[k] = max(0, min(int(L[k]), height-1))
    yl = float(s["calibration"].get("yards_length", 1.0))
    if yl <= 0: s["calibration"]["yards_length"] = 1.0
    save()
EOF

# 2) Ball detector refreshes thresholds each frame from settings (custom HSV wins)
cat > src/tracking/ball_detector.py << 'EOF'
import cv2
import numpy as np
from config import COLOR_RANGES
import settings as appsettings

class BallDetector:
    def __init__(self):
        self.last_mask = None
        self.lower = None
        self.upper = None
        self.min_radius = None
        self.refresh_from_settings()

    def refresh_from_settings(self):
        s = appsettings.load()
        self.min_radius = int(s.get("min_ball_radius_px", 3))
        custom = s.get("ball_hsv", {"lower": None, "upper": None})
        if custom and custom.get("lower") and custom.get("upper"):
            self.lower = np.array(custom["lower"], dtype=np.uint8)
            self.upper = np.array(custom["upper"], dtype=np.uint8)
        else:
            color_name = s.get("ball_color", "white")
            cr = COLOR_RANGES.get(color_name, COLOR_RANGES["white"])
            self.lower = np.array(cr["lower"], dtype=np.uint8)
            self.upper = np.array(cr["upper"], dtype=np.uint8)

    def detect(self, frame):
        # Refresh in case settings changed (cheap)
        self.refresh_from_settings()

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

# 3) UI: color picker (click to sample HSV, show swatch, save to settings)
mkdir -p src/ui
cat > src/ui/color_picker.py << 'EOF'
import cv2
import numpy as np
import settings as appsettings

def _clamp(v, lo, hi): return max(lo, min(int(v), hi))

class ColorPicker:
    def __init__(self, main_window_name="PuttTracker"):
        self.window = main_window_name
        self.active = False
        self.last_hsv = None
        self._w = None
        self._h = None
        self._picked = False
        # Tolerances around sampled HSV (tune if needed)
        self.dH = 12
        self.dS = 60
        self.dV = 70

    def _on_mouse(self, event, x, y, flags, param):
        if not self.active: return
        if event == cv2.EVENT_LBUTTONDOWN:
            # read small region around click
            frame_bgr = param  # current frame passed in setMouseCallback
            if frame_bgr is None: return
            h, w = frame_bgr.shape[:2]
            x1 = max(0, x-5); x2 = min(w-1, x+5)
            y1 = max(0, y-5); y2 = min(h-1, y+5)
            patch = frame_bgr[y1:y2+1, x1:x2+1]
            hsv = cv2.cvtColor(patch, cv2.COLOR_BGR2HSV)
            mean = hsv.reshape(-1,3).mean(axis=0)
            H,S,V = map(int, mean)
            self.last_hsv = (H,S,V)
            # Build tolerant lower/upper
            lower = [ _clamp(H - self.dH, 0, 180), _clamp(S - self.dS, 0, 255), _clamp(V - self.dV, 0, 255) ]
            upper = [ _clamp(H + self.dH, 0, 180), _clamp(S + self.dS, 0, 255), _clamp(V + self.dV, 0, 255) ]
            # Save to settings and flag picked
            appsettings.set_value("ball_hsv.lower", lower)
            appsettings.set_value("ball_hsv.upper", upper)
            # keep 'ball_color' as-is, but custom HSV overrides in detector
            self._picked = True

    def open(self, frame_width, frame_height, current_frame):
        self._w, self._h = frame_width, frame_height
        self.active = True
        # Pass current frame into mouse callback so we can sample from it
        cv2.setMouseCallback(self.window, lambda e,x,y,f, p=current_frame: self._on_mouse(e,x,y,f,p))

    def close(self):
        self.active = False
        self._picked = False
        self.last_hsv = None
        cv2.setMouseCallback(self.window, lambda *args: None)

    def toggle(self, frame_width, frame_height, current_frame):
        if self.active:
            self.close()
        else:
            self.open(frame_width, frame_height, current_frame)

    def picked(self):
        return self._picked

    def render_overlay(self, frame):
        # Show instructions and a color swatch of last_hsv if available
        h, w = frame.shape[:2]
        # Instruction banner
        text = "COLOR PICK MODE: click the BALL to sample color"
        cv2.rectangle(frame, (8, 40), (8 + 10 + len(text)*9, 72), (0,0,0), -1)
        cv2.putText(frame, text, (16, 64), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (255,255,255), 1, cv2.LINE_AA)
        if self.last_hsv is not None:
            H,S,V = self.last_hsv
            # swatch box
            sw = 60
            x0 = 16; y0 = 88
            hsv_img = np.uint8([[[H,S,V]]])
            bgr = cv2.cvtColor(hsv_img, cv2.COLOR_HSV2BGR)[0,0].tolist()
            cv2.rectangle(frame, (x0, y0), (x0+sw, y0+sw), (0,0,0), -1)
            cv2.rectangle(frame, (x0+2, y0+2), (x0+sw-2, y0+sw-2), bgr, -1)
            cv2.putText(frame, f"HSV: {H},{S},{V}", (x0+sw+10, y0+30), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (255,255,255), 1, cv2.LINE_AA)
            cv2.putText(frame, "Saved to settings", (x0+sw+10, y0+52), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (180,255,180), 1, cv2.LINE_AA)
EOF

# 4) Add a tiny swatch util (optional; we render in picker already) — no change to draw_utils needed

# 5) Wire into main.py: 'b' toggles color pick; pause processing while active; reuses new HSV immediately
#    (We assume your current main.py already has sliders/calibration/cooldown/etc. from prior scripts.)
#    We'll patch main.py wholesale for consistency with the latest features.
cat > src/main.py << 'EOF'
import time
import cv2
import requests
from tracking.ball_detector import BallDetector
from tracking.motion_tracker import MotionTracker
from camera.capture import Camera
from utils.draw_utils import (
    draw_ball, draw_vector, put_hud, draw_roi, banner, help_box, draw_calibration_line, draw_status_dot
)
from utils.logger import log
import settings as appsettings
from ui.slider_editor import SliderEditor
from ui.calibration_editor import CalibrationEditor, compute_px_per_yard
from ui.color_picker import ColorPicker

COOLDOWN_SEC = 1.0  # delay after a shot before tracking again

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

def to_real_units(px_velocity, px_per_yard):
    if px_velocity is None or px_per_yard is None or px_per_yard <= 0:
        return None, None
    yds_per_s = px_velocity / px_per_yard
    mph = yds_per_s * (3600.0/1760.0)
    return yds_per_s, mph

def post_shot(mph, yds_per_s, direction):
    s = appsettings.load()
    post = s.get("post", {})
    if not post.get("enabled", True):
        return False
    host = post.get("host", "10.10.10.23")
    port = int(post.get("port", 8888))
    path = post.get("path", "/putting")
    timeout = float(post.get("timeout_sec", 2.5))

    url = f"http://{host}:{port}{path}"
    data = {
        "ballData": {
            "BallSpeed": f"{mph:.2f}" if mph is not None else "0.00",
            "TotalSpin": 0,
            "LaunchDirection": f"{direction:.2f}" if direction is not None else "0.00"
        }
    }
    try:
        res = requests.post(url, json=data, timeout=timeout)
        res.raise_for_status()
        _ = res.json() if "application/json" in res.headers.get("Content-Type","") else {}
        log(f"POST OK -> {url}")
        return True
    except requests.exceptions.HTTPError as e:
        log(f"HTTP error posting shot: {e}")
    except requests.exceptions.RequestException as e:
        log(f"Request error posting shot: {e}")
    return False

def main():
    s = appsettings.load()
    show_mask = bool(s.get("show_mask", False))
    target_w = int(s.get("target_width", 960))
    min_report_mph = float(s.get("min_report_mph", 1.0))

    camera = Camera(source=0)
    detector = BallDetector()
    tracker = MotionTracker()

    # Prime first frame; initialize ROI
    frame_iter = camera.stream()
    first_frame = next(frame_iter)
    h0, w0 = first_frame.shape[:2]
    appsettings.ensure_roi_initialized(w0, h0)
    appsettings.clamp_roi(w0, h0)

    s = appsettings.load()
    roi = (int(s["roi"]["startx"]), int(s["roi"]["starty"]), int(s["roi"]["endx"]), int(s["roi"]["endy"]))

    cv2.namedWindow("PuttTracker", cv2.WINDOW_NORMAL)
    editor = SliderEditor()
    cal = CalibrationEditor()
    picker = ColorPicker("PuttTracker")

    log("Controls: q=quit | m=mask | a=settings | c=calibrate | b=pick ball color")
    last_pos = None
    last_inside = False
    last_valid_velocity = None
    last_valid_direction = None
    last_shot_time = 0.0
    sending_now = False

    def yield_with_first(first, gen):
        yield first
        for f in gen:
            yield f

    for frame in yield_with_first(first_frame, frame_iter):
        s = appsettings.load()
        show_mask = bool(s.get("show_mask", show_mask))
        target_w = int(s.get("target_width", target_w))
        roi = (int(s["roi"]["startx"]), int(s["roi"]["starty"]), int(s["roi"]["endx"]), int(s["roi"]["endy"]))
        min_report_mph = float(s.get("min_report_mph", min_report_mph))
        px_per_yard = s["calibration"]["px_per_yard"]

        paused = editor.active or cal.active or picker.active
        now = time.time()

        if paused:
            tracker.reset()
            last_pos = None
            last_inside = False
            draw_roi(frame, roi)

            if editor.active:
                banner(frame, "SLIDER EDIT MODE (processing paused)")
                help_box(frame, [
                    "Adjust ROI & settings in 'PuttTracker Settings'",
                    "a: close sliders | c: calibration | b: color pick | q: quit"
                ])
            if cal.active:
                L = s["calibration"]["line"]
                draw_calibration_line(frame, L)
                ppy = compute_px_per_yard()
                txt = f"CALIBRATION: px/yd={ppy:.2f}" if ppy else "CALIBRATION: adjust line to yardstick"
                banner(frame, txt)
                help_box(frame, [
                    "Align the YELLOW line with your yardstick",
                    "Use 'yards_len x10' if your stick != 1.0 yd",
                    "Press 'c' to close and save, then resume"
                ])
            if picker.active:
                picker.render_overlay(frame)
            draw_status_dot(frame, 'yellow')

        else:
            in_cooldown = (now - last_shot_time) < 1.0

            if in_cooldown:
                tracker.reset()
                draw_roi(frame, roi)
                banner(frame, "COOLDOWN...")
                draw_status_dot(frame, 'yellow')
            else:
                center, radius = detector.detect(frame)
                in_area = inside_roi(center, roi)

                velocity, direction = tracker.update(center if in_area else None)
                if velocity is not None:
                    last_valid_velocity = velocity
                    last_valid_direction = direction

                yds_per_s, mph = to_real_units(velocity, px_per_yard)

                if last_inside and not in_area and last_valid_velocity is not None:
                    yps_exit, mph_exit = to_real_units(last_valid_velocity, px_per_yard)
                    if mph_exit is None or mph_exit >= min_report_mph:
                        if mph_exit is not None:
                            log(f"SHOT: {mph_exit:.1f} mph ({yps_exit:.2f} yd/s) dir={last_valid_direction:.2f}° (exited ROI)")
                        else:
                            log(f"SHOT: vel={last_valid_velocity:.2f} px/s, dir={last_valid_direction:.2f}° (exited ROI)")
                        # POST
                        sending_now = True
                        draw_status_dot(frame, 'red')
                        cv2.imshow("PuttTracker", resize_keep_aspect(frame, target_w))
                        cv2.waitKey(1)
                        _ = post_shot(mph_exit if mph_exit is not None else 0.0,
                                      yps_exit if yps_exit is not None else 0.0,
                                      last_valid_direction if last_valid_direction is not None else 0.0)
                        sending_now = False
                        last_shot_time = time.time()
                    else:
                        log(f"IGNORED (under {min_report_mph:.1f} mph): {mph_exit if mph_exit is not None else 0.0:.1f} mph")
                        last_shot_time = time.time()
                last_inside = in_area

                draw_ball(frame, center if in_area else None, radius if in_area and radius else 0.0)
                draw_roi(frame, roi)
                if in_area:
                    draw_vector(frame, last_pos, center)
                put_hud(frame,
                        velocity if in_area else None,
                        direction if in_area else None,
                        tracker.fps,
                        mph=mph if in_area else None,
                        yds=yds_per_s if in_area else None)

                if show_mask and detector.last_mask is not None:
                    mask = cv2.cvtColor(detector.last_mask, cv2.COLOR_GRAY2BGR)
                    mh, mw = mask.shape[:2]
                    roi_small = frame[0:mh, 0:mw]
                    cv2.addWeighted(mask, 0.5, roi_small, 0.5, 0, roi_small)

                if center is None:
                    draw_status_dot(frame, 'yellow')
                else:
                    draw_status_dot(frame, 'green')

                last_pos = center if in_area else last_pos

        preview = resize_keep_aspect(frame, target_w)
        cv2.imshow("PuttTracker", preview)

        key = cv2.waitKey(1) & 0xFF
        if key == ord('q'):
            break
        elif key == ord('m'):
            appsettings.set_value("show_mask", not bool(s.get("show_mask", False)))
        elif key == ord('a'):
            editor.toggle(w0, h0)
        elif key == ord('c'):
            if cal.active:
                ppy = compute_px_per_yard()
                if ppy:
                    appsettings.set_value("calibration.px_per_yard", float(ppy))
                    log(f"Calibration saved: {float(ppy):.2f} px/yard")
                cal.toggle(w0, h0)
            else:
                cal.toggle(w0, h0)
        elif key == ord('b'):
            # Open/close picker; when opening, pass current frame to sample from
            if picker.active:
                picker.close()
            else:
                picker.open(w0, h0, frame)

    # Cleanup
    editor.close(); cal.close(); picker.close()
    cv2.destroyAllWindows()

if __name__ == "__main__":
    main()
EOF

echo "✅ Click-to-pick color added. Press 'b', click the ball, swatch shows; saved HSV used for tracking."
