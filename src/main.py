import time
import math
import cv2
import requests

from tracking.ball_detector import BallDetector
from tracking.motion_tracker import MotionTracker
from camera.capture import Camera
from utils.draw_utils import (
    draw_ball, draw_vector, put_hud, draw_roi, banner, help_box,
    draw_calibration_line, draw_status_dot, draw_gate_line
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

# --- Direction (HLA) helpers: 0 straight, LEFT negative, RIGHT positive, clamp [-60,60]
def compute_hla(last_pos, cur_pos):
    if last_pos is None or cur_pos is None:
        return None
    (x1,y1) = last_pos
    (x2,y2) = cur_pos
    dx, dy = (x2-x1), (y2-y1)
    heading_deg = math.degrees(math.atan2(-dy, dx))   # convert image coords (y down) to math coords (y up)
    hla = -heading_deg  # left negative, right positive
    if hla < -60: hla = -60.0
    if hla > 60:  hla = 60.0
    return hla

def side_of_line(pt, line):
    if pt is None or line is None:
        return None
    x, y = pt
    x1,y1,x2,y2 = line["x1"], line["y1"], line["x2"], line["y2"]
    return (x2 - x1)*(y - y1) - (y2 - y1)*(x - x1)

def distance_to_line(pt, line):
    if pt is None or line is None:
        return None
    x, y = pt
    x1,y1,x2,y2 = map(float, (line["x1"], line["y1"], line["x2"], line["y2"]))
    num = abs((y2-y1)*x - (x2-x1)*y + x2*y1 - y2*x1)
    den = max(1e-6, math.hypot(x2-x1, y2-y1))
    return num/den

def post_shot(mph, yds_per_s, direction):
    s = appsettings.load()
    post_cfg = s.get("post", {})
    if not post_cfg.get("enabled", True):
        log("POST disabled in settings; skipping.")
        return False, None
    host = post_cfg.get("host", "10.10.10.23")
    port = int(post_cfg.get("port", 8888))
    path = post_cfg.get("path", "/putting")
    timeout = float(post_cfg.get("timeout_sec", 2.5))
    url = f"http://{host}:{port}{path}"
    payload = {
        "ballData": {
            "BallSpeed": f"{(mph or 0.0):.2f}",
            "TotalSpin": 0,
            "LaunchDirection": f"{(direction or 0.0):.2f}"
        }
    }
    try:
        res = requests.post(url, json=payload, timeout=timeout)
        res.raise_for_status()
        try:
            data = res.json()
        except ValueError:
            data = None
        log(f"POST OK -> {url} | sent {payload}")
        if data is not None:
            log(f"Response JSON: {data}")
        return True, data
    except requests.exceptions.HTTPError as e:
        log(f"HTTP error posting shot -> {url}: {e}")
    except requests.exceptions.RequestException as e:
        log(f"Request error posting shot -> {url}: {e}")
    return False, None

def main():
    s = appsettings.load()
    show_mask = bool(s.get("show_mask", False))
    target_w = int(s.get("target_width", 960))
    min_report_mph = float(s.get("min_report_mph", 1.0))

    # Input source (camera/video)
    inp = s.get("input", {})
    src_mode = inp.get("source", "camera")
    if src_mode == "video":
        video_path = inp.get("video_path", "testdata/my_putt.mp4")
        loop_flag = bool(inp.get("loop", True))
        camera = Camera(source=video_path, loop=loop_flag)
    else:
        camera = Camera(source=0)

    detector = BallDetector()
    tracker = MotionTracker()

    # Timing from video FPS (and UI throttle) if using video
    is_video = (inp.get("source") == "video")
    vid_fps = 30.0
    wait_ms = 1
    if is_video:
        cap_tmp = cv2.VideoCapture(inp.get("video_path", "testdata/my_putt.mp4"))
        vid_fps = cap_tmp.get(cv2.CAP_PROP_FPS) or 30.0
        cap_tmp.release()
        try:
            tracker.set_dt_override(1.0/float(vid_fps))
        except Exception:
            pass
        try:
            wait_ms = max(1, int(round(1000.0/float(vid_fps))))
        except Exception:
            wait_ms = 33
    else:
        try:
            tracker.set_dt_override(None)
        except Exception:
            pass
        wait_ms = 1

    # Prime first frame; init ROI and Gate
    frame_iter = camera.stream()
    first_frame = next(frame_iter)
    h0, w0 = first_frame.shape[:2]
    appsettings.ensure_roi_initialized(w0, h0)
    appsettings.clamp_roi(w0, h0)
    appsettings.ensure_gate_initialized(w0, h0)
    appsettings.clamp_gate(w0, h0)

    s = appsettings.load()
    roi = (int(s["roi"]["startx"]), int(s["roi"]["starty"]), int(s["roi"]["endx"]), int(s["roi"]["endy"]))

    cv2.namedWindow("PuttTracker", cv2.WINDOW_NORMAL)
    editor = SliderEditor()
    cal = CalibrationEditor()
    picker = ColorPicker("PuttTracker")

    log("Controls: q=quit | m=mask | a=settings | c=calibrate | b=pick color")
    last_pos = None
    last_inside = False
    last_valid_velocity = None
    last_valid_direction = None
    last_shot_time = 0.0
    sending_now = False

    # NEW: gate crossing state
    shot_armed = False
    last_side = None

    def yield_with_first(first, gen):
        yield first
        for f in gen:
            yield f

    for frame in yield_with_first(first_frame, frame_iter):
        # display copy for overlays
        disp = frame.copy()

        s = appsettings.load()
        show_mask = bool(s.get("show_mask", show_mask))
        target_w = int(s.get("target_width", target_w))
        roi = (int(s["roi"]["startx"]), int(s["roi"]["starty"]), int(s["roi"]["endx"]), int(s["roi"]["endy"]))
        min_report_mph = float(s.get("min_report_mph", min_report_mph))
        px_per_yard = s["calibration"]["px_per_yard"]
        gate_enabled = bool(s.get("gate", {}).get("enabled", True))
        gate_line = s.get("gate", {}).get("line", {"x1":0,"y1":h0//2,"x2":w0-1,"y2":h0//2})

        paused = editor.active or cal.active or picker.active
        now = time.time()

        # tag
        banner(disp, "PAUSED" if paused else "RUNNING")

        # Always draw contextual lines
        draw_gate_line(disp, gate_line, gate_enabled)
        draw_roi(disp, roi)

        if paused:
            tracker.reset()
            last_pos = None
            last_inside = False
            shot_armed = False
            last_side = None

            if editor.active:
                banner(disp, "SLIDER EDIT MODE (processing paused)")
                help_box(disp, [
                    "Adjust ROI & settings in 'PuttTracker Settings'",
                    "a: close sliders | c: calibration | b: color pick | q: quit"
                ])

            if cal.active:
                L = s["calibration"]["line"]
                draw_calibration_line(disp, L)
                ppy = compute_px_per_yard()
                txt = f"CALIBRATION: px/yd={ppy:.2f}" if ppy else "CALIBRATION: adjust line to yardstick"
                banner(disp, txt)
                help_box(disp, [
                    "Align the YELLOW line with your yardstick",
                    "Press 'c' to close and save"
                ])

            if picker.active:
                picker.render_overlay(disp)

            draw_status_dot(disp, 'yellow')

        else:
            in_cooldown = (now - last_shot_time) < COOLDOWN_SEC

            if in_cooldown:
                tracker.reset()
                banner(disp, "COOLDOWN…")
                draw_status_dot(disp, 'yellow')
                # disarm during cooldown
                shot_armed = False
                last_side = None
            else:
                center, radius = detector.detect(frame)  # detect on raw
                in_area = inside_roi(center, roi)

                velocity, direction = tracker.update(center if in_area else None)
                if velocity is not None:
                    last_valid_velocity = velocity
                    last_valid_direction = direction

                yds_per_s, mph = to_real_units(velocity, px_per_yard)

                # --- Gate crossing arming ---
                if gate_enabled and in_area and center is not None:
                    side = side_of_line(center, gate_line)
                    # Only consider as crossing if not skimming the line
                    dist = distance_to_line(center, gate_line)
                    if last_side is not None and side is not None and dist is not None:
                        if dist > 2.0 and last_side * side < 0:
                            shot_armed = True
                            log("Gate crossed: shot ARMED")
                    last_side = side

                # --- Exit ROI event (valid shot only if armed or gate disabled) ---
                if last_inside and not in_area and last_valid_velocity is not None:
                    if shot_armed or not gate_enabled:
                        yps_exit, mph_exit = to_real_units(last_valid_velocity, px_per_yard)
                        # Direction per your convention
                        hla = compute_hla(last_pos, center if center is not None else last_pos)
                        if mph_exit is None or mph_exit >= min_report_mph:
                            if mph_exit is not None:
                                log(f"SHOT: {mph_exit:.1f} mph ({yps_exit:.2f} yd/s) hla={0.0 if hla is None else hla:.2f}°")
                            else:
                                log(f"SHOT: vel={last_valid_velocity:.2f} px/s, hla={0.0 if hla is None else hla:.2f}°")
                            # POST
                            sending_now = True
                            draw_status_dot(disp, 'red')
                            cv2.imshow("PuttTracker", resize_keep_aspect(disp, target_w))
                            cv2.waitKey(1)
                            _ = post_shot(
                                mph_exit if mph_exit is not None else 0.0,
                                yps_exit if yps_exit is not None else 0.0,
                                0.0 if hla is None else hla
                            )
                            sending_now = False
                            last_shot_time = time.time()
                        else:
                            log(f"IGNORED (under {min_report_mph:.1f} mph): {0.0 if mph_exit is None else mph_exit:.1f} mph")
                            last_shot_time = time.time()
                    else:
                        log("Exit ROI without gate crossing: NOT ARMED (ignored)")
                    # reset arming after any exit
                    shot_armed = False
                    last_side = None

                last_inside = in_area

                # Overlays
                draw_ball(disp, center if in_area else None, radius if in_area and radius else 0.0)
                if in_area:
                    draw_vector(disp, last_pos, center)
                put_hud(
                    disp,
                    velocity if in_area else None,
                    last_valid_direction if in_area else None,
                    tracker.fps,
                    mph=mph if in_area else None,
                    yds=yds_per_s if in_area else None
                )

                if show_mask and detector.last_mask is not None:
                    mask = cv2.cvtColor(detector.last_mask, cv2.COLOR_GRAY2BGR)
                    mh, mw = mask.shape[:2]
                    roi_small = disp[0:mh, 0:mw]
                    cv2.addWeighted(mask, 0.5, roi_small, 0.5, 0, roi_small)

                # Status light: green when ball found inside ROI, yellow otherwise
                draw_status_dot(disp, 'green' if (center is not None and in_area) else 'yellow')

                last_pos = center if in_area else last_pos

        # Show
        preview = resize_keep_aspect(disp, target_w)
        cv2.imshow("PuttTracker", preview)

        # Keys
        key = cv2.waitKey(1 if not is_video else max(1, int(round(1000.0/(vid_fps or 30.0))))) & 0xFF
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
            if picker.active:
                picker.commit(frame)
                picker.toggle(w0, h0)
                log("Ball color saved from slider picker.")
            else:
                picker.toggle(w0, h0)

    editor.close(); cal.close(); picker.close()
    cv2.destroyAllWindows()

if __name__ == "__main__":
    main()
