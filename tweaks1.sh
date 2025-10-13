#!/bin/bash
set -e

if [ ! -d "src" ]; then
  echo "Run from project root (where ./src exists)."
  exit 1
fi

# --- Ensure requests is in requirements ---
if ! grep -q "^requests" requirements.txt 2>/dev/null; then
  echo "requests" >> requirements.txt
fi

# --- Update settings.py: add post config, min_report_mph ---
cat > src/settings.py << 'EOF'
import json, os
from typing import Any, Dict

SETTINGS_PATH = os.path.join(os.path.dirname(os.path.dirname(__file__)), "settings.json")

_DEFAULTS: Dict[str, Any] = {
    "ball_color": "white",
    "min_ball_radius_px": 3,
    "show_mask": False,
    "target_width": 960,
    "min_report_mph": 1.0,  # hits below this won't be reported
    "roi": {"startx": None, "endx": None, "starty": None, "endy": None},
    "calibration": {
        "px_per_yard": None,
        "yards_length": 1.0,
        "line": {"x1": 100, "y1": 100, "x2": 400, "y2": 100}
    },
    # HTTP post target (not changeable via UI)
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

# --- draw_utils: add status dot ---
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

def draw_status_dot(frame, status: str):
    # status: 'red' | 'yellow' | 'green'
    h, w = frame.shape[:2]
    center = (w - 20, 20)
    color = {'red': (0,0,255), 'yellow': (0,255,255), 'green': (0,200,0)}.get(status, (200,200,200))
    cv2.circle(frame, center, 8, (0,0,0), -1)
    cv2.circle(frame, center, 7, color, -1)
EOF

# --- main.py: add cooldown, threshold, status, HTTP POST, line only in calibration ---
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

    # Prime first frame; initialize ROI; do NOT pause at start
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
    last_shot_time = 0.0
    sending_now = False  # for status dot

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
        paused = editor.active or cal.active

        now = time.time()

        if paused:
            # paused UI + status
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
            # status: paused -> yellow
            draw_status_dot(frame, 'yellow')

        else:
            in_cooldown = (now - last_shot_time) < COOLDOWN_SEC

            if in_cooldown:
                # Cooldown: don't update tracker with new positions
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

                # Exit event: was inside, now outside (and not in cooldown)
                if last_inside and not in_area and last_valid_velocity is not None:
                    yps_exit, mph_exit = to_real_units(last_valid_velocity, px_per_yard)
                    # Threshold gate
                    if mph_exit is None or mph_exit >= min_report_mph:
                        # Log shot
                        if mph_exit is not None:
                            log(f"SHOT: {mph_exit:.1f} mph ({yps_exit:.2f} yd/s) dir={last_valid_direction:.2f}° (exited ROI)")
                        else:
                            log(f"SHOT: vel={last_valid_velocity:.2f} px/s, dir={last_valid_direction:.2f}° (exited ROI)")
                        # HTTP POST (blocking; mark status red while sending)
                        sending_now = True
                        draw_status_dot(frame, 'red')
                        cv2.imshow("PuttTracker", resize_keep_aspect(frame, target_w))
                        cv2.waitKey(1)
                        ok = post_shot(mph_exit if mph_exit is not None else 0.0,
                                       yps_exit if yps_exit is not None else 0.0,
                                       last_valid_direction if last_valid_direction is not None else 0.0)
                        sending_now = False
                        last_shot_time = time.time()  # start cooldown
                    else:
                        log(f"IGNORED (under {min_report_mph:.1f} mph): {mph_exit if mph_exit is not None else 0.0:.1f} mph")
                        last_shot_time = time.time()  # still start cooldown to avoid spam
                last_inside = in_area

                # Overlays and status
                draw_ball(frame, center if in_area else None, radius if in_area and radius else 0.0)
                draw_roi(frame, roi)
                if in_area:
                    draw_vector(frame, last_pos, center)
                put_hud(
                    frame,
                    velocity if in_area else None,
                    direction if in_area else None,
                    tracker.fps,
                    mph=mph if in_area else None,
                    yds=yds_per_s if in_area else None
                )

                if show_mask and detector.last_mask is not None:
                    mask = cv2.cvtColor(detector.last_mask, cv2.COLOR_GRAY2BGR)
                    mh, mw = mask.shape[:2]
                    roi_small = frame[0:mh, 0:mw]
                    cv2.addWeighted(mask, 0.5, roi_small, 0.5, 0, roi_small)

                # status: green if ball in view & inside ROI; yellow if not found
                if center is None:
                    draw_status_dot(frame, 'yellow')
                else:
                    draw_status_dot(frame, 'green')

                last_pos = center if in_area else last_pos

        # Present and input
        preview = resize_keep_aspect(frame, target_w)
        if sending_now:
            # already displayed a frame just before POST; still update
            cv2.imshow("PuttTracker", preview)
        else:
            cv2.imshow("PuttTracker", preview)

        key = cv2.waitKey(1) & 0xFF
        if key == ord('q'):
            break
        elif key == ord('m'):
            appsettings.set_value("show_mask", not bool(s.get("show_mask", False)))
        elif key == ord('a'):
            editor.toggle(w0, h0)   # opens with existing values (no reset)
        elif key == ord('c'):
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

echo "✅ Tweaks applied: cooldown, thresholded reporting, status dot, HTTP POST, no reset on 'a'."
