#!/bin/bash
set -e

if [ ! -d "src" ]; then
  echo "Run this from the putttracker project root (where ./src exists)."
  exit 1
fi

# Ensure settings.json exists and has calibration defaults
if [ ! -f settings.json ]; then
  cat > settings.json << 'EOF'
{
  "ball_color": "white",
  "min_ball_radius_px": 3,
  "show_mask": false,
  "target_width": 960,
  "roi": { "startx": null, "endx": null, "starty": null, "endy": null },
  "calibration": {
    "px_per_yard": null,
    "yards_length": 1.0,
    "line": {"x1": 100, "y1": 100, "x2": 400, "y2": 100}
  }
}
EOF
else
  # Merge in calibration defaults if missing
  python3 - << 'PY'
import json, os
p="settings.json"
s=json.load(open(p))
s.setdefault("calibration",{})
s["calibration"].setdefault("px_per_yard", None)
s["calibration"].setdefault("yards_length", 1.0)
s["calibration"].setdefault("line", {}).setdefault("x1", 100)
s["calibration"]["line"].setdefault("y1", 100)
s["calibration"]["line"].setdefault("x2", 400)
s["calibration"]["line"].setdefault("y2", 100)
json.dump(s, open(p,"w"), indent=2)
PY
fi

# ---- Update settings.py with calibration helpers ----
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
    "calibration": {
        "px_per_yard": None,
        "yards_length": 1.0,
        "line": {"x1": 100, "y1": 100, "x2": 400, "y2": 100}
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

# ---- Calibration helpers ----
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

# ---- Calibration UI ----
mkdir -p src/ui
cat > src/ui/calibration_editor.py << 'EOF'
import cv2
import math
import settings as appsettings

class CalibrationEditor:
    def __init__(self, window_name="PuttTracker Calibration"):
        self.name = window_name
        self.active = False
        self._w = None
        self._h = None
        self._lock = False

    def _safe_set(self, keypath, value):
        if self._lock: return
        self._lock = True
        appsettings.set_value(keypath, value)
        self._lock = False

    def _sync(self):
        appsettings.clamp_calibration(self._w, self._h)
        s = appsettings.load()
        L = s["calibration"]["line"]
        cv2.setTrackbarPos("x1", self.name, int(L["x1"]))
        cv2.setTrackbarPos("y1", self.name, int(L["y1"]))
        cv2.setTrackbarPos("x2", self.name, int(L["x2"]))
        cv2.setTrackbarPos("y2", self.name, int(L["y2"]))
        cv2.setTrackbarPos("yards_len x10", self.name, int(round(float(s["calibration"]["yards_length"])*10)))

    def _on_x1(self, v): self._safe_set("calibration.line.x1", v); appsettings.clamp_calibration(self._w, self._h)
    def _on_y1(self, v): self._safe_set("calibration.line.y1", v); appsettings.clamp_calibration(self._w, self._h)
    def _on_x2(self, v): self._safe_set("calibration.line.x2", v); appsettings.clamp_calibration(self._w, self._h)
    def _on_y2(self, v): self._safe_set("calibration.line.y2", v); appsettings.clamp_calibration(self._w, self._h)
    def _on_len(self, v): self._safe_set("calibration.yards_length", max(0.1, v/10.0))

    def open(self, frame_width, frame_height):
        self._w, self._h = int(frame_width), int(frame_height)
        appsettings.clamp_calibration(self._w, self._h)
        cv2.namedWindow(self.name, cv2.WINDOW_NORMAL)
        cv2.resizeWindow(self.name, 420, 260)
        s = appsettings.load()
        L = s["calibration"]["line"]
        cv2.createTrackbar("x1", self.name, int(L["x1"]), self._w-1, lambda v: self._on_x1(v))
        cv2.createTrackbar("y1", self.name, int(L["y1"]), self._h-1, lambda v: self._on_y1(v))
        cv2.createTrackbar("x2", self.name, int(L["x2"]), self._w-1, lambda v: self._on_x2(v))
        cv2.createTrackbar("y2", self.name, int(L["y2"]), self._h-1, lambda v: self._on_y2(v))
        cv2.createTrackbar("yards_len x10", self.name, int(round(float(s["calibration"]["yards_length"])*10)), 50, lambda v: self._on_len(v))
        self._sync()
        self.active = True

    def close(self):
        if self.active:
            try: cv2.destroyWindow(self.name)
            except Exception: pass
        self.active = False

    def toggle(self, frame_width, frame_height):
        if self.active: self.close()
        else: self.open(frame_width, frame_height)

def compute_px_per_yard():
    s = appsettings.load()
    L = s["calibration"]["line"]
    yards_len = float(s["calibration"].get("yards_length", 1.0))
    if yards_len <= 0: return None
    dx = float(L["x2"]) - float(L["x1"])
    dy = float(L["y2"]) - float(L["y1"])
    dist_px = math.hypot(dx, dy)
    if dist_px <= 0: return None
    return dist_px / yards_len
EOF

# ---- draw_utils: add calibration overlay & mph in HUD ----
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

def put_hud(frame, velocity=None, direction=None, fps=None, mph=None, yds=None):
    parts = []
    if velocity is not None:
        parts.append(f"vel: {velocity:.1f} px/s")
    if yds is not None:
        parts.append(f"{yds:.2f} yd/s")
    if mph is not None:
        parts.append(f"{mph:.1f} mph")
    if direction is not None:
        parts.append(f"dir: {direction:.1f}°")
    if fps is not None:
        parts.append(f"fps: {fps:.1f}")
    text = " | ".join(parts) if parts else ""
    if text:
        cv2.rectangle(frame, (8, 6), (8 + 12*len(text), 36), (0, 0, 0), -1)
        cv2.putText(frame, text, (12, 28), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (255,255,255), 1, cv2.LINE_AA)

def draw_roi(frame, roi, color=(0, 200, 255), thickness=2):
    x1, y1, x2, y2 = roi
    cv2.rectangle(frame, (x1, y1), (x2, y2), color, thickness)

def banner(frame, text, color=(0,0,255)):
    h = 32
    w = 10 + len(text) * 12
    cv2.rectangle(frame, (8, 40), (8 + w, 40 + h), (0,0,0), -1)
    cv2.putText(frame, text, (16, 64), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (255,255,255), 2, cv2.LINE_AA)

def help_box(frame, lines):
    width = max([len(s) for s in lines]) if lines else 0
    w = 20 + width * 8
    h = 24 + len(lines) * 18
    cv2.rectangle(frame, (8, 80), (8 + w, 80 + h), (0,0,0), -1)
    y = 100
    for s in lines:
        cv2.putText(frame, s, (16, y), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (255,255,255), 1, cv2.LINE_AA)
        y += 18

def draw_calibration_line(frame, line, color=(0,255,255)):
    x1,y1,x2,y2 = map(int, (line["x1"], line["y1"], line["x2"], line["y2"]))
    cv2.line(frame, (x1,y1), (x2,y2), color, 2)
    cv2.circle(frame, (x1,y1), 4, (0,0,0), -1)
    cv2.circle(frame, (x2,y2), 4, (0,0,0), -1)
    cv2.circle(frame, (x1,y1), 3, color, -1)
    cv2.circle(frame, (x2,y2), 3, color, -1)
EOF

# ---- main.py: integrate calibration mode & mph conversion ----
cat > src/main.py << 'EOF'
import cv2
import math
from tracking.ball_detector import BallDetector
from tracking.motion_tracker import MotionTracker
from camera.capture import Camera
from utils.draw_utils import draw_ball, draw_vector, put_hud, draw_roi, banner, help_box, draw_calibration_line
from utils.logger import log
import settings as appsettings
from ui.slider_editor import SliderEditor
from ui.calibration_editor import CalibrationEditor, compute_px_per_yard

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
    mph = yds_per_s * (3600.0/1760.0)  # 1760 yards in a mile
    return yds_per_s, mph

def main():
    s = appsettings.load()
    show_mask = bool(s.get("show_mask", False))
    target_w = int(s.get("target_width", 960))

    camera = Camera(source=0)
    detector = BallDetector()
    tracker = MotionTracker()

    # Prime first frame
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

    log("Controls: q=quit | m=mask | a=settings sliders | c=calibrate (yardstick)")
    last_pos = None
    last_inside = False
    last_valid_velocity = None
    last_valid_direction = None

    def yield_with_first(first, gen):
        yield first
        for f in gen:
            yield f

    for frame in yield_with_first(first_frame, frame_iter):
        s = appsettings.load()
        show_mask = bool(s.get("show_mask", show_mask))
        target_w = int(s.get("target_width", target_w))
        roi = (int(s["roi"]["startx"]), int(s["roi"]["starty"]), int(s["roi"]["endx"]), int(s["roi"]["endy"]))
        paused = editor.active or cal.active

        # Always draw calibration line overlay (helps placement)
        L = s["calibration"]["line"]
        draw_calibration_line(frame, L)

        if paused:
            # Pause detection during any UI mode
            tracker.reset()
            last_pos = None
            last_inside = False
            draw_roi(frame, roi)
            if editor.active:
                banner(frame, "SLIDER EDIT MODE (processing paused)")
                help_box(frame, [
                    "Adjust ROI & settings in 'PuttTracker Settings'",
                    "a: close sliders | c: calibration | q: quit"
                ])
            if cal.active:
                # live compute px/yard and show it
                ppy = compute_px_per_yard()
                txt = f"CALIBRATION: px/yd={ppy:.2f}" if ppy else "CALIBRATION: adjust line to yardstick"
                banner(frame, txt)
                help_box(frame, [
                    "Align the YELLOW line with your yardstick",
                    "Use 'yards_len x10' if your stick != 1.0 yd",
                    "Press 'c' to close and resume"
                ])
        else:
            center, radius = detector.detect(frame)
            in_area = inside_roi(center, roi)
            velocity, direction = tracker.update(center if in_area else None)
            if velocity is not None:
                last_valid_velocity = velocity
                last_valid_direction = direction

            # Convert to real units if calibrated
            px_per_yard = s["calibration"]["px_per_yard"]
            if px_per_yard is None:
                # try compute on the fly; if valid, persist it
                ppy = compute_px_per_yard()
                if ppy:
                    appsettings.set_value("calibration.px_per_yard", float(ppy))
                    px_per_yard = float(ppy)

            yds_per_s, mph = to_real_units(velocity, px_per_yard)

            # Exit event: was inside, now outside
            if last_inside and not in_area:
                if last_valid_velocity is not None:
                    yps_exit, mph_exit = to_real_units(last_valid_velocity, px_per_yard)
                    if mph_exit is not None:
                        log(f"SHOT: {mph_exit:.1f} mph ({yps_exit:.2f} yd/s) dir={last_valid_direction:.2f}° (exited ROI)")
                    else:
                        log(f"SHOT: vel={last_valid_velocity:.2f} px/s, dir={last_valid_direction:.2f}° (exited ROI)")
            last_inside = in_area

            # Overlays
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
            # When closing calibration, store px/yard if valid
            if cal.active:
                ppy = compute_px_per_yard()
                if ppy:
                    appsettings.set_value("calibration.px_per_yard", float(ppy))
                    log(f"Calibration saved: {float(ppy):.2f} px/yard")
                cal.toggle(w0, h0)
            else:
                cal.toggle(w0, h0)

    editor.close(); cal.close()
    cv2.destroyAllWindows()

if __name__ == "__main__":
    main()
EOF

echo "✅ Yardstick calibration added. Activate your venv and run:  python3 src/main.py"
