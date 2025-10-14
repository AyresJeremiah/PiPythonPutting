#!/bin/bash
set -e

[ -d "src" ] || { echo "❌ Run from project root (where ./src exists)"; exit 1; }

###############################################################################
# settings.py — add zones {stage_roi, track_roi}
###############################################################################
cat > src/settings.py << 'EOF'
import json, os
from typing import Any, Dict

SETTINGS_PATH = os.path.join(os.path.dirname(os.path.dirname(__file__)), "settings.json")

_DEFAULTS: Dict[str, Any] = {
    "ball_color": "white",
    "ball_hsv": {"lower": None, "upper": None},
    "min_ball_radius_px": 3,
    "show_mask": False,
    "target_width": 960,
    "min_report_mph": 1.0,
    "roi": {"startx": None, "endx": None, "starty": None, "endy": None},  # legacy (kept)
    "zones": {
        # NEW: two-zone trigger
        "stage_roi": {"x1": None, "y1": None, "x2": None, "y2": None},
        "track_roi": {"x1": None, "y1": None, "x2": None, "y2": None}
    },
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
    },
    "input": {
        "source": "camera",
        "video_path": "testdata/my_putt.mp4",
        "loop": True
    },
    "gate": {  # kept for compatibility but unused now
        "enabled": False,
        "line": {"x1": 0, "y1": 0, "x2": 0, "y2": 0}
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
    """path like 'zones.stage_roi.x1', 'show_mask', 'min_report_mph'."""
    s = load()
    parts = path.split(".")
    ref = s
    for p in parts[:-1]:
        ref = ref[p]
    ref[parts[-1]] = value
    save()

def ensure_roi_initialized(width: int, height: int):
    s = load()
    r = s["roi"]
    if None in (r["startx"], r["endx"], r["starty"], r["endy"]):
        r["startx"], r["starty"], r["endx"], r["endy"] = 0, 0, width, height
        save()

def clamp_roi(width: int, height: int):
    s = load()
    r = s["roi"]
    r["startx"] = max(0, min(int(r["startx"]), width-1))
    r["endx"]   = max(1, min(int(r["endx"]),   width))
    r["starty"] = max(0, min(int(r["starty"]), height-1))
    r["endy"]   = max(1, min(int(r["endy"]),   height))
    if r["startx"] >= r["endx"]:  r["endx"]  = min(width,  r["startx"] + 1)
    if r["starty"] >= r["endy"]:  r["endy"]  = min(height, r["starty"] + 1)
    save()

# NEW: init/clamp for zones
def ensure_zones_initialized(width:int, height:int):
    s = load()
    z = s["zones"]
    st = z["stage_roi"]; tr = z["track_roi"]
    if None in (st["x1"], st["y1"], st["x2"], st["y2"]):
        # default small box near bottom-left
        st["x1"], st["y1"] = int(width*0.10), int(height*0.70)
        st["x2"], st["y2"] = int(width*0.30), int(height*0.95)
    if None in (tr["x1"], tr["y1"], tr["x2"], tr["y2"]):
        # default tracking lane across the mat
        tr["x1"], tr["y1"] = int(width*0.15), int(height*0.25)
        tr["x2"], tr["y2"] = int(width*0.85), int(height*0.75)
    save()

def clamp_zone_rect(rect, width:int, height:int):
    rect["x1"] = max(0, min(int(rect["x1"]), width-1))
    rect["x2"] = max(1, min(int(rect["x2"]), width))
    rect["y1"] = max(0, min(int(rect["y1"]), height-1))
    rect["y2"] = max(1, min(int(rect["y2"]), height))
    if rect["x1"] >= rect["x2"]: rect["x2"] = min(width, rect["x1"]+1)
    if rect["y1"] >= rect["y2"]: rect["y2"] = min(height, rect["y1"]+1)

def clamp_zones(width:int, height:int):
    s = load()
    clamp_zone_rect(s["zones"]["stage_roi"], width, height)
    clamp_zone_rect(s["zones"]["track_roi"], width, height)
    save()
EOF

###############################################################################
# draw_utils.py — add zone drawers with labels
###############################################################################
cat > src/utils/draw_utils.py << 'EOF'
import cv2

def draw_ball(frame, center, radius):
    if center is None:
        return
    x, y = map(int, center)
    cv2.circle(frame, (x, y), int(max(2, radius)), (0, 255, 0), 2)
    cv2.circle(frame, (x, y), 3, (0, 0, 255), -1)

def draw_vector(frame, p1, p2):
    if p1 is None or p2 is None:
        return
    (x1, y1) = map(int, p1); (x2, y2) = map(int, p2)
    cv2.arrowedLine(frame, (x1, y1), (x2, y2), (255, 0, 0), 2, tipLength=0.25)

def put_hud(frame, velocity=None, direction=None, fps=None, mph=None, yds=None):
    parts = []
    if velocity is not None: parts.append(f"vel: {velocity:.1f} px/s")
    if yds is not None:      parts.append(f"{yds:.2f} yd/s")
    if mph is not None:      parts.append(f"{mph:.1f} mph")
    if direction is not None:parts.append(f"dir: {direction:.1f}°")
    if fps is not None:      parts.append(f"fps: {fps:.1f}")
    if parts:
        text = " | ".join(parts)
        cv2.rectangle(frame, (8, 6), (8 + 12*len(text), 36), (0,0,0), -1)
        cv2.putText(frame, text, (12, 28), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (255,255,255), 1, cv2.LINE_AA)

def draw_roi(frame, roi, color=(0, 200, 255), thickness=2):
    x1, y1, x2, y2 = roi
    cv2.rectangle(frame, (x1, y1), (x2, y2), color, thickness)

def banner(frame, text, color=(0,0,255)):
    h = 32; w = 10 + len(text) * 12
    cv2.rectangle(frame, (8, 40), (8 + w, 40 + h), (0,0,0), -1)
    cv2.putText(frame, text, (16, 64), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (255,255,255), 2, cv2.LINE_AA)

def help_box(frame, lines):
    width = max([len(s) for s in lines]) if lines else 0
    w = 20 + width * 8; h = 24 + len(lines) * 18
    cv2.rectangle(frame, (8, 80), (8 + w, 80 + h), (0,0,0), -1)
    y = 100
    for s in lines:
        cv2.putText(frame, s, (16, y), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (255,255,255), 1, cv2.LINE_AA)
        y += 18

def draw_calibration_line(frame, line, color=(0,255,255)):
    x1,y1,x2,y2 = map(int, (line["x1"], line["y1"], line["x2"], line["y2"]))
    cv2.line(frame, (x1,y1), (x2,y2), color, 2)
    for (x,y) in ((x1,y1),(x2,y2)):
        cv2.circle(frame, (x,y), 4, (0,0,0), -1)
        cv2.circle(frame, (x,y), 3, color, -1)

def draw_status_dot(frame, status: str):
    h, w = frame.shape[:2]
    center = (w - 20, 20)
    color = {'red': (0,0,255), 'yellow': (0,255,255), 'green': (0,200,0)}.get(status, (200,200,200))
    cv2.circle(frame, center, 8, (0,0,0), -1)
    cv2.circle(frame, center, 7, color, -1)

# NEW: zone drawers
def draw_zone(frame, rect, label, color, thickness=2):
    x1,y1,x2,y2 = map(int, (rect["x1"], rect["y1"], rect["x2"], rect["y2"]))
    cv2.rectangle(frame, (x1,y1), (x2,y2), color, thickness)
    cv2.putText(frame, label, (x1+6, y1+22), cv2.FONT_HERSHEY_SIMPLEX, 0.6, color, 2, cv2.LINE_AA)
EOF

###############################################################################
# slider_editor.py — add Stage/Track ROI sliders (load current values)
###############################################################################
cat > src/ui/slider_editor.py << 'EOF'
import cv2
import settings as appsettings

class SliderEditor:
    """Processing pauses while this window is open."""
    def __init__(self, window_name: str = "PuttTracker Settings"):
        self.win = window_name
        self.active = False
        self._w = None
        self._h = None

    def _set(self, path, value): appsettings.set_value(path, value)
    def _clamp(self, v, lo, hi): return max(lo, min(int(v), hi))

    # Stage ROI callbacks
    def _cb_st_x1(self, v): self._set("zones.stage_roi.x1", self._clamp(v,0,self._w-1))
    def _cb_st_y1(self, v): self._set("zones.stage_roi.y1", self._clamp(v,0,self._h-1))
    def _cb_st_x2(self, v): self._set("zones.stage_roi.x2", self._clamp(v,1,self._w))
    def _cb_st_y2(self, v): self._set("zones.stage_roi.y2", self._clamp(v,1,self._h))

    # Track ROI callbacks
    def _cb_tr_x1(self, v): self._set("zones.track_roi.x1", self._clamp(v,0,self._w-1))
    def _cb_tr_y1(self, v): self._set("zones.track_roi.y1", self._clamp(v,0,self._h-1))
    def _cb_tr_x2(self, v): self._set("zones.track_roi.x2", self._clamp(v,1,self._w))
    def _cb_tr_y2(self, v): self._set("zones.track_roi.y2", self._clamp(v,1,self._h))

    def _cb_min_rad(self, v): self._set("min_ball_radius_px", self._clamp(v,1,200))
    def _cb_show_mask(self, v): self._set("show_mask", bool(v))
    def _cb_min_mph(self, v): self._set("min_report_mph", float(v)/100.0)
    def _cb_target_w(self, v):
        v = int(v);  v = 320 if v < 320 else v
        self._set("target_width", v)

    def open(self, frame_width: int, frame_height: int):
        self._w, self._h = int(frame_width), int(frame_height)
        s = appsettings.load()

        cv2.namedWindow(self.win, cv2.WINDOW_NORMAL)
        cv2.resizeWindow(self.win, 460, 600)

        # Stage ROI
        cv2.createTrackbar("stage_x1", self.win, 0, max(1,self._w-1), lambda v: self._cb_st_x1(v))
        cv2.createTrackbar("stage_y1", self.win, 0, max(1,self._h-1), lambda v: self._cb_st_y1(v))
        cv2.createTrackbar("stage_x2", self.win, 1, max(1,self._w),   lambda v: self._cb_st_x2(v))
        cv2.createTrackbar("stage_y2", self.win, 1, max(1,self._h),   lambda v: self._cb_st_y2(v))

        # Track ROI
        cv2.createTrackbar("track_x1", self.win, 0, max(1,self._w-1), lambda v: self._cb_tr_x1(v))
        cv2.createTrackbar("track_y1", self.win, 0, max(1,self._h-1), lambda v: self._cb_tr_y1(v))
        cv2.createTrackbar("track_x2", self.win, 1, max(1,self._w),   lambda v: self._cb_tr_x2(v))
        cv2.createTrackbar("track_y2", self.win, 1, max(1,self._h),   lambda v: self._cb_tr_y2(v))

        # Other
        cv2.createTrackbar("min_ball_radius_px",   self.win, 1, 200,  lambda v: self._cb_min_rad(v))
        cv2.createTrackbar("min_report_mph_x100",  self.win, 0, 3000, lambda v: self._cb_min_mph(v))
        cv2.createTrackbar("target_width_px",      self.win, 320, 3840,lambda v: self._cb_target_w(v))
        cv2.createTrackbar("show_mask",            self.win, 0, 1,     lambda v: self._cb_show_mask(v))

        self._sync_from_settings(s)
        self.active = True

    def _sync_from_settings(self, s):
        st = s["zones"]["stage_roi"]; tr = s["zones"]["track_roi"]
        try:
            cv2.setTrackbarPos("stage_x1", self.win, int(st["x1"]))
            cv2.setTrackbarPos("stage_y1", self.win, int(st["y1"]))
            cv2.setTrackbarPos("stage_x2", self.win, int(st["x2"]))
            cv2.setTrackbarPos("stage_y2", self.win, int(st["y2"]))
            cv2.setTrackbarPos("track_x1", self.win, int(tr["x1"]))
            cv2.setTrackbarPos("track_y1", self.win, int(tr["y1"]))
            cv2.setTrackbarPos("track_x2", self.win, int(tr["x2"]))
            cv2.setTrackbarPos("track_y2", self.win, int(tr["y2"]))
            cv2.setTrackbarPos("min_ball_radius_px", self.win, int(s.get("min_ball_radius_px",3)))
            cv2.setTrackbarPos("min_report_mph_x100", self.win, int(round(float(s.get("min_report_mph",1.0))*100)))
            tw = max(320, int(s.get("target_width",960)))
            cv2.setTrackbarPos("target_width_px", self.win, tw)
            cv2.setTrackbarPos("show_mask", self.win, 1 if s.get("show_mask", False) else 0)
        except Exception:
            pass

    def close(self):
        self.active = False
        try: cv2.destroyWindow(self.win)
        except Exception: pass

    def toggle(self, frame_width: int, frame_height: int):
        if self.active: self.close()
        else: self.open(frame_width, frame_height)
EOF

###############################################################################
# main.py — state machine: IDLE → STAGED → TRACKING → REPORT/COOLDOWN
###############################################################################
cat > src/main.py << 'EOF'
import time
import math
import cv2
import requests

from tracking.ball_detector import BallDetector
from tracking.motion_tracker import MotionTracker
from camera.capture import Camera
from utils.draw_utils import (
    draw_ball, draw_vector, put_hud, banner, help_box, draw_status_dot, draw_zone
)
from utils.logger import log
import settings as appsettings
from ui.slider_editor import SliderEditor
from ui.calibration_editor import CalibrationEditor, compute_px_per_yard
from ui.color_picker import ColorPicker

COOLDOWN_SEC = 1.0  # pause after report
LOST_FRAMES_LIMIT = 6  # end tracking if ball lost N frames

def resize_keep_aspect(frame, target_w):
    h, w = frame.shape[:2]
    if w == 0 or h == 0: return frame
    scale = target_w / float(w)
    return cv2.resize(frame, (int(w*scale), int(h*scale)))

def rect_contains(pt, rect):
    if pt is None or rect is None: return False
    x,y = pt
    return rect["x1"] <= x <= rect["x2"] and rect["y1"] <= y <= rect["y2"]

def to_real_units(px_velocity, px_per_yard):
    if px_velocity is None or px_per_yard is None or px_per_yard <= 0: return None, None
    yps = px_velocity / px_per_yard
    mph = yps * (3600.0/1760.0)
    return yps, mph

def compute_hla(last_pos, cur_pos):
    if last_pos is None or cur_pos is None: return None
    (x1,y1) = last_pos; (x2,y2) = cur_pos
    dx, dy = (x2-x1), (y2-y1)
    heading = math.degrees(math.atan2(-dy, dx))  # y-up
    hla = -heading  # left -, right +
    return max(-60.0, min(60.0, hla))

def post_shot(mph, yds_per_s, direction):
    s = appsettings.load()
    post = s.get("post", {})
    if not post.get("enabled", True): return False, None
    url = f"http://{post.get('host','10.10.10.23')}:{int(post.get('port',8888))}{post.get('path','/putting')}"
    payload = {"ballData":{
        "BallSpeed": f"{(mph or 0.0):.2f}",
        "TotalSpin": 0,
        "LaunchDirection": f"{(direction or 0.0):.2f}"
    }}
    try:
        r = requests.post(url, json=payload, timeout=float(post.get("timeout_sec",2.5)))
        r.raise_for_status()
        try: data = r.json()
        except ValueError: data=None
        log(f"POST OK -> {url} | {payload}")
        return True, data
    except requests.exceptions.RequestException as e:
        log(f"POST error -> {e}")
        return False, None

def main():
    s = appsettings.load()
    show_mask   = bool(s.get("show_mask", False))
    target_w    = int(s.get("target_width", 960))
    min_mph     = float(s.get("min_report_mph", 1.0))

    # input source
    inp = s.get("input", {})
    if inp.get("source","camera") == "video":
        camera = Camera(source=inp.get("video_path","testdata/my_putt.mp4"), loop=bool(inp.get("loop",True)))
    else:
        camera = Camera(source=0)

    detector = BallDetector()
    tracker  = MotionTracker()

    # dt override + UI throttle for video
    is_video = (inp.get("source") == "video")
    wait_ms = 1
    if is_video:
        cap_tmp = cv2.VideoCapture(inp.get("video_path","testdata/my_putt.mp4"))
        vid_fps = cap_tmp.get(cv2.CAP_PROP_FPS) or 30.0
        cap_tmp.release()
        try: tracker.set_dt_override(1.0/float(vid_fps))
        except Exception: pass
        try: wait_ms = max(1, int(round(1000.0/float(vid_fps))))
        except Exception: wait_ms = 33
    else:
        try: tracker.set_dt_override(None)
        except Exception: pass

    # first frame + init zones
    frame_iter  = camera.stream()
    first_frame = next(frame_iter)
    h0, w0 = first_frame.shape[:2]
    appsettings.ensure_roi_initialized(w0, h0)            # legacy ROI kept
    appsettings.clamp_roi(w0, h0)
    appsettings.ensure_zones_initialized(w0, h0)          # NEW
    appsettings.clamp_zones(w0, h0)

    s = appsettings.load()
    stage = s["zones"]["stage_roi"].copy()
    track = s["zones"]["track_roi"].copy()

    cv2.namedWindow("PuttTracker", cv2.WINDOW_NORMAL)
    editor = SliderEditor()
    cal    = CalibrationEditor()
    picker = ColorPicker("PuttTracker")

    log("Controls: q quit | m mask | a settings | c calibrate | b color pick")

    # state machine
    state = "IDLE"       # IDLE -> STAGED -> TRACKING -> (REPORT->COOLDOWN->IDLE)
    lost_frames = 0
    last_pos = None
    last_valid_velocity = None
    last_valid_direction = None
    last_shot_time = 0.0

    def yield_first(f, g):
        yield f
        for fr in g: yield fr

    for frame in yield_first(first_frame, frame_iter):
        disp = frame.copy()

        # reload live settings each loop
        s = appsettings.load()
        show_mask = bool(s.get("show_mask", show_mask))
        target_w  = int(s.get("target_width", target_w))
        min_mph   = float(s.get("min_report_mph", min_mph))
        stage     = s["zones"]["stage_roi"]
        track     = s["zones"]["track_roi"]
        px_per_yd = s["calibration"]["px_per_yard"]

        paused = editor.active or cal.active or picker.active
        now = time.time()

        # draw zones
        draw_zone(disp, stage, "STAGE", (0,200,255))
        draw_zone(disp, track, "TRACK", (0,180,0))

        # paused states
        if paused:
            state = "IDLE" if state != "COOLDOWN" else state
            tracker.reset(); last_pos=None; lost_frames=0
            banner(disp, "PAUSED")
            draw_status_dot(disp, 'yellow')
            if editor.active:
                help_box(disp, ["Adjust STAGE & TRACK rectangles", "Close with 'a' to resume"])
            if cal.active:
                L = s["calibration"]["line"]
                from utils.draw_utils import draw_calibration_line
                draw_calibration_line(disp, L)
                ppy = compute_px_per_yard()
                banner(disp, f"CALIBRATION: {ppy:.2f} px/yd" if ppy else "CALIBRATE LINE TO YARDSTICK")
            if picker.active:
                picker.render_overlay(disp)

        else:
            # cooldown
            if state == "COOLDOWN":
                if (now - last_shot_time) >= COOLDOWN_SEC:
                    state = "IDLE"
                banner(disp, "COOLDOWN…")
                draw_status_dot(disp, 'yellow')
            else:
                # detect on raw frame
                center, radius = detector.detect(frame)

                if center is None:
                    lost_frames = min(999, lost_frames+1)
                else:
                    lost_frames = 0

                # state transitions
                if state == "IDLE":
                    banner(disp, "IDLE")
                    if rect_contains(center, stage):
                        tracker.reset()
                        last_pos = center
                        state = "STAGED"
                        log("Ball staged (armed).")
                    draw_status_dot(disp, 'yellow')

                elif state == "STAGED":
                    banner(disp, "STAGED (waiting to enter TRACK)")
                    draw_status_dot(disp, 'green' if rect_contains(center, stage) else 'yellow')
                    # enter tracking when ball goes into track ROI
                    if rect_contains(center, track):
                        tracker.reset()
                        last_pos = center
                        state = "TRACKING"
                        log("Tracking started (entered TRACK).")

                elif state == "TRACKING":
                    banner(disp, "TRACKING")
                    if rect_contains(center, track) and center is not None:
                        # update tracker only inside track ROI
                        velocity, direction = tracker.update(center)
                        if velocity is not None:
                            last_valid_velocity = velocity
                            last_valid_direction = direction
                        yps, mph = to_real_units(velocity, px_per_yd)
                        # overlays
                        draw_ball(disp, center, radius or 0)
                        if last_pos is not None:
                            draw_vector(disp, last_pos, center)
                        put_hud(disp, velocity, None, tracker.fps, mph, yps)
                        draw_status_dot(disp, 'green')
                        last_pos = center
                    else:
                        # left track ROI OR lost for a while → finalize
                        should_finalize = True
                        if rect_contains(center, track) is False and center is not None:
                            should_finalize = True
                        if lost_frames < LOST_FRAMES_LIMIT and center is None:
                            should_finalize = False  # brief occlusion tolerance
                        if should_finalize:
                            yps_exit, mph_exit = to_real_units(last_valid_velocity, px_per_yd)
                            hla = compute_hla(last_pos, center if center is not None else last_pos)
                            if mph_exit is None or mph_exit >= min_mph:
                                log(f"SHOT: {0.0 if mph_exit is None else mph_exit:.1f} mph | hla={0.0 if hla is None else hla:.2f}°")
                                draw_status_dot(disp, 'red')
                                cv2.imshow("PuttTracker", resize_keep_aspect(disp, target_w))
                                cv2.waitKey(wait_ms)
                                post_shot(mph_exit or 0.0, yps_exit or 0.0, hla or 0.0)
                            else:
                                log(f"IGNORED (under {min_mph:.1f} mph): {0.0 if mph_exit is None else mph_exit:.1f} mph")
                            state = "COOLDOWN"
                            last_shot_time = time.time()
                            tracker.reset()
                            lost_frames = 0
                    # end TRACKING

        # mask overlay (debug)
        if show_mask and hasattr(detector, "last_mask") and detector.last_mask is not None:
            mask = cv2.cvtColor(detector.last_mask, cv2.COLOR_GRAY2BGR)
            mh, mw = mask.shape[:2]
            roi_small = disp[0:mh, 0:mw]
            cv2.addWeighted(mask, 0.5, roi_small, 0.5, 0, roi_small)

        # present
        preview = resize_keep_aspect(disp, target_w)
        cv2.imshow("PuttTracker", preview)

        # keys
        key = cv2.waitKey(wait_ms) & 0xFF
        if key == ord('q'): break
        elif key == ord('m'): appsettings.set_value("show_mask", not bool(s.get("show_mask", False)))
        elif key == ord('a'): editor.toggle(w0, h0)
        elif key == ord('c'):
            if cal.active:
                ppy = compute_px_per_yard()
                if ppy: appsettings.set_value("calibration.px_per_yard", float(ppy)); log(f"Calibration saved: {ppy:.2f} px/yd")
                cal.toggle(w0, h0)
            else: cal.toggle(w0, h0)
        elif key == ord('b'):
            if picker.active: picker.commit(frame); picker.toggle(w0, h0); log("Ball color saved.")
            else: picker.toggle(w0, h0)

    editor.close(); cal.close(); picker.close()
    cv2.destroyAllWindows()

if __name__ == "__main__":
    main()
EOF

echo "✅ Switched to two-zone trigger: STAGE -> TRACK -> report"
echo "Open settings with 'a' to move Stage/Track rectangles live."
