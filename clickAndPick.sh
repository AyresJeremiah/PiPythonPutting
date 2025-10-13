#!/bin/bash
set -e

if [ ! -d "src" ]; then
  echo "Run this from the project root (where ./src exists)."
  exit 1
fi

# Ensure settings contains the ball_hsv schema
python3 - << 'PY'
import json, os
p="settings.json"
s=json.load(open(p)) if os.path.exists(p) else {}
s.setdefault("ball_hsv", {"lower": None, "upper": None})
json.dump(s, open(p,"w"), indent=2)
PY

# Replace color picker with slider-based picker
cat > src/ui/color_picker.py << 'EOF'
import cv2
import numpy as np
import settings as appsettings

def _clamp(v, lo, hi): return max(lo, min(int(v), hi))

class ColorPicker:
    """
    Slider-based picker:
      - open(w,h): shows a window with X/Y sliders bounded to frame size
      - render_overlay(frame): draws dot and instructions
      - commit(frame): samples HSV around (x,y) and saves ball_hsv.lower/upper
    """
    def __init__(self, main_window_name="PuttTracker", picker_window="PuttTracker Color Picker"):
        self.main_window = main_window_name
        self.name = picker_window
        self.active = False
        self._w = None
        self._h = None
        self._lock = False
        self._x = 0
        self._y = 0
        # HSV tolerances (can be expanded if needed)
        self.dH = 12
        self.dS = 60
        self.dV = 70
        self.last_hsv = None  # preview swatch while open

    def _sync_from_settings(self):
        # Try to initialize at ROI center if present
        s = appsettings.load()
        roi = s.get("roi", {})
        try:
            x1,y1,x2,y2 = int(roi["startx"]),int(roi["starty"]),int(roi["endx"]),int(roi["endy"])
            cx = max(0, min((x1+x2)//2, self._w-1))
            cy = max(0, min((y1+y2)//2, self._h-1))
            self._x, self._y = cx, cy
        except Exception:
            self._x, self._y = self._w//2, self._h//2

    def _on_x(self, v):
        if self._lock: return
        self._x = _clamp(v, 0, self._w-1)

    def _on_y(self, v):
        if self._lock: return
        self._y = _clamp(v, 0, self._h-1)

    def open(self, frame_width, frame_height):
        self._w, self._h = int(frame_width), int(frame_height)
        self._sync_from_settings()
        cv2.namedWindow(self.name, cv2.WINDOW_NORMAL)
        cv2.resizeWindow(self.name, 360, 120)
        cv2.createTrackbar("x", self.name, int(self._x), self._w-1, lambda v: self._on_x(v))
        cv2.createTrackbar("y", self.name, int(self._y), self._h-1, lambda v: self._on_y(v))
        self.active = True

    def close(self):
        if self.active:
            try: cv2.destroyWindow(self.name)
            except Exception: pass
        self.active = False
        self.last_hsv = None

    def toggle(self, frame_width, frame_height):
        if self.active: self.close()
        else: self.open(frame_width, frame_height)

    def render_overlay(self, frame):
        # Dot + crosshair
        x, y = int(self._x), int(self._y)
        cv2.drawMarker(frame, (x,y), (0,255,255), markerType=cv2.MARKER_CROSS, markerSize=14, thickness=2)
        cv2.circle(frame, (x,y), 5, (0,255,255), 2)
        # Instruction + (optional) swatch preview if last_hsv exists
        text = "COLOR PICK: move sliders (x,y) over the BALL. Press 'b' to save."
        cv2.rectangle(frame, (8, 40), (8 + 12*len(text), 72), (0,0,0), -1)
        cv2.putText(frame, text, (16, 64), cv2.FONT_HERSHEY_SIMPLEX, 0.56, (255,255,255), 1, cv2.LINE_AA)
        if self.last_hsv is not None:
            H,S,V = self.last_hsv
            sw = 60; x0=16; y0=88
            hsv_img = np.uint8([[[H,S,V]]])
            bgr = cv2.cvtColor(hsv_img, cv2.COLOR_HSV2BGR)[0,0].tolist()
            cv2.rectangle(frame, (x0, y0), (x0+sw, y0+sw), (0,0,0), -1)
            cv2.rectangle(frame, (x0+2, y0+2), (x0+sw-2, y0+sw-2), bgr, -1)
            cv2.putText(frame, f"HSV: {H},{S},{V}", (x0+sw+10, y0+30), cv2.FONT_HERSHEY_SIMPLEX, 0.56, (255,255,255), 1, cv2.LINE_AA)
            cv2.putText(frame, "Saved (pending close)", (x0+sw+10, y0+52), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (180,255,180), 1, cv2.LINE_AA)

    def _sample_hsv(self, frame_bgr):
        x, y = int(self._x), int(self._y)
        h, w = frame_bgr.shape[:2]
        # sample 11x11 around the point (clamped)
        x1 = max(0, x-5); x2 = min(w-1, x+5)
        y1 = max(0, y-5); y2 = min(h-1, y+5)
        patch = frame_bgr[y1:y2+1, x1:x2+1]
        hsv = cv2.cvtColor(patch, cv2.COLOR_BGR2HSV)
        H,S,V = hsv.reshape(-1,3).mean(axis=0)
        return int(H), int(S), int(V)

    def commit(self, frame_bgr):
        """Sample at current (x,y) and save tolerant HSV to settings."""
        if frame_bgr is None: return
        H,S,V = self._sample_hsv(frame_bgr)
        self.last_hsv = (H,S,V)
        lower = [ _clamp(H - self.dH, 0, 180), _clamp(S - self.dS, 0, 255), _clamp(V - self.dV, 0, 255) ]
        upper = [ _clamp(H + self.dH, 0, 180), _clamp(S + self.dS, 0, 255), _clamp(V + self.dV, 0, 255) ]
        appsettings.set_value("ball_hsv.lower", lower)
        appsettings.set_value("ball_hsv.upper", upper)
        # Detector reads custom HSV automatically on next frame
EOF

# Patch main.py to use the new slider-based picker (open/close & commit on close)
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

    log("Controls: q=quit | m=mask | a=settings | c=calibrate | b=pick ball color (sliders)")
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
                from ui.calibration_editor import compute_px_per_yard
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
                from ui.calibration_editor import compute_px_per_yard
                ppy = compute_px_per_yard()
                if ppy:
                    appsettings.set_value("calibration.px_per_yard", float(ppy))
                    log(f"Calibration saved: {float(ppy):.2f} px/yard")
                cal.toggle(w0, h0)
            else:
                cal.toggle(w0, h0)
        elif key == ord('b'):
            # Toggle slider picker; on close, sample & save from current frame
            if picker.active:
                picker.commit(frame)
                picker.toggle(w0, h0)  # close
                log("Ball color saved from slider picker.")
            else:
                picker.toggle(w0, h0)  # open

    editor.close(); cal.close(); picker.close()
    cv2.destroyAllWindows()

if __name__ == "__main__":
    main()
EOF

echo "✅ Slider-based color picker added. Press 'b' to open/close; dot follows sliders; color saved on close."
