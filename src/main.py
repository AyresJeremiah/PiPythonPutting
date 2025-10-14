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
        try: wait_ms = max(1, int(round(1000.0 / (float(vid_fps) * float(inp.get("playback_speed", 1.0))))))
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
