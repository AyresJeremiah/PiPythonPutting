import time
import math
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
    mph = yds_per_s * (3600.0 / 1760.0)
    return yds_per_s, mph

def post_shot(mph, yds_per_s, direction):
    """
    Send shot data to the server defined in settings.json -> post.{host,port,path,timeout_sec}.
    Returns: (ok: bool, response_json: dict|None)
    """
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

    # --- Camera from settings.input (camera or video with loop) ---
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
    # Use video FPS for timing when source=video, for correct speeds
    is_video = (inp.get("source") == "video")
    vid_fps = 30.0
    wait_ms = 1
    if is_video:
        cap_tmp = cv2.VideoCapture(inp.get("video_path", "testdata/my_putt.mp4"))
        vid_fps = cap_tmp.get(cv2.CAP_PROP_FPS) or 30.0
        cap_tmp.release()
        try:
            tracker.set_dt_override(1.0 / float(vid_fps))
        except Exception:
            pass
        # throttle UI loop to video FPS
        try:
            wait_ms = max(1, int(round(1000.0 / float(vid_fps))))
        except Exception:
            wait_ms = 33
    else:
        try:
            tracker.set_dt_override(None)
        except Exception:
            pass
        wait_ms = 1

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
            in_cooldown = (now - last_shot_time) < COOLDOWN_SEC

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
                        cv2.waitKey(wait_ms)
                        _ = post_shot(
                            mph_exit if mph_exit is not None else 0.0,
                            yps_exit if yps_exit is not None else 0.0,
                            last_valid_direction if last_valid_direction is not None else 0.0
                        )
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

                if center is None:
                    draw_status_dot(frame, 'yellow')
                else:
                    draw_status_dot(frame, 'green')

                last_pos = center if in_area else last_pos

        preview = resize_keep_aspect(frame, target_w)
        cv2.imshow("PuttTracker", preview)

        key = cv2.waitKey(wait_ms) & 0xFF
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
