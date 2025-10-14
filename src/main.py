import time, math, cv2, requests, numpy as np

from src.services.gspro import post_shot
from tracking.ball_detector import BallDetector
from tracking.motion_tracker import MotionTracker
from camera.capture import Camera
from utils.draw_utils import draw_ball, draw_vector, put_hud, banner, help_box, draw_status_dot, draw_zone
from utils.logger import log
import settings as appsettings
from ui.slider_editor import SliderEditor
from ui.calibration_editor import CalibrationEditor, compute_px_per_yard
from ui.color_picker import ColorPicker
from ui.preview import PreviewUI
from utils.runtime_cfg import set_cfg

COOLDOWN_SEC = 1.0
LOST_FRAMES_LIMIT = 6


def rect_contains(pt, rect):
    if pt is None or rect is None:
        return False
    x, y = pt
    return rect["x1"] <= x <= rect["x2"] and rect["y1"] <= y <= rect["y2"]


def rect_union(a, b):
    return {
        "x1": min(int(a["x1"]), int(b["x1"])),
        "y1": min(int(a["y1"]), int(b["y1"])),
        "x2": max(int(a["x2"]), int(b["x2"])),
        "y2": max(int(a["y2"]), int(b["y2"]))
    }


def clamp_rect(rc, w, h):
    rc["x1"] = max(0, min(int(rc["x1"]), w - 1))
    rc["x2"] = max(1, min(int(rc["x2"]), w))
    rc["y1"] = max(0, min(int(rc["y1"]), h - 1))
    rc["y2"] = max(1, min(int(rc["y2"]), h))
    if rc["x1"] >= rc["x2"]:
        rc["x2"] = min(w, rc["x1"] + 1)
    if rc["y1"] >= rc["y2"]:
        rc["y2"] = min(h, rc["y1"] + 1)


def to_real_units(px_velocity, px_per_yard):
    if px_velocity is None or not px_per_yard or px_per_yard <= 0:
        return None, None
    yps = px_velocity / px_per_yard
    mph = yps * (3600.0 / 1760.0)
    return yps, mph


def compute_hla(last_pos, cur_pos):
    if last_pos is None or cur_pos is None:
        return None
    (x1, y1), (x2, y2) = last_pos, cur_pos
    dx, dy = (x2 - x1), (y2 - y1)
    heading = math.degrees(math.atan2(-dy, dx))
    hla = max(-60.0, min(60.0, -heading))  # left -, right +
    return hla


def main():
    cv2.setNumThreads(1)

    # === LOAD SETTINGS ONCE ===
    cfg = appsettings.load()
    set_cfg(cfg)  # make cfg available app-wide (no more disk loads)
    target_w = int(cfg.get("target_width", 960))
    min_mph = float(cfg.get("min_report_mph", 1.0))
    inp = cfg.get("input", {})
    px_per_yd = cfg["calibration"]["px_per_yard"]
    detect_cfg = cfg.get("detect", {})
    detect_scale = float(detect_cfg.get("scale", 0.75))
    if detect_scale <= 0 or detect_scale > 1.0:
        detect_scale = 1.0

    # Input source
    if inp.get("source", "camera") == "video":
        camera = Camera(source=inp.get("video_path", "testdata/my_putt.mp4"),
                        loop=bool(inp.get("loop", True)))
    else:
        camera = Camera(source=0)

    detector = BallDetector()
    tracker = MotionTracker()

    # Video timing (UI throttle) + physics dt
    is_video = (inp.get("source") == "video")
    wait_ms = 1
    if is_video:
        cap_tmp = cv2.VideoCapture(inp.get("video_path", "testdata/my_putt.mp4"))
        vid_fps = cap_tmp.get(cv2.CAP_PROP_FPS) or 30.0
        cap_tmp.release()
        try:
            tracker.set_dt_override(1.0 / float(vid_fps))
        except Exception:
            pass
        speed = float(inp.get("playback_speed", 1.0))
        try:
            wait_ms = max(1, int(round(1000.0 / (float(vid_fps) * max(0.01, speed)))))
        except Exception:
            wait_ms = 33
    else:
        try:
            tracker.set_dt_override(None)
        except Exception:
            pass

    # ✅ Initialize UI AFTER is_video/wait_ms are computed
    ui = PreviewUI(title="PuttTracker", target_width=target_w, wait_ms=(wait_ms if is_video else 1))
    ui.start()

    # First frame + zones (initialize defaults from current frame size)
    frame_iter = camera.stream()
    first_frame = next(frame_iter)
    h0, w0 = first_frame.shape[:2]
    appsettings.ensure_roi_initialized(w0, h0)
    appsettings.clamp_roi(w0, h0)
    appsettings.ensure_zones_initialized(w0, h0)
    appsettings.clamp_zones(w0, h0)

    # Use the same cfg dict for stage/track (no reloads)
    stage = cfg["zones"]["stage_roi"]
    track = cfg["zones"]["track_roi"]

    # --- Static zone overlay: draw once and reuse ---
    zone_overlay = np.zeros_like(first_frame)

    def rebuild_zone_overlay():
        nonlocal zone_overlay
        canvas = np.zeros_like(first_frame)
        draw_zone(canvas, cfg["zones"]["stage_roi"], "STAGE", (0, 200, 255))
        draw_zone(canvas, cfg["zones"]["track_roi"], "TRACK", (0, 180, 0))
        zone_overlay = canvas

    rebuild_zone_overlay()

    editor = SliderEditor()
    cal = CalibrationEditor()
    picker = ColorPicker("PuttTracker")

    log("Controls: q quit | m mask | a settings | c calibrate | b color pick")

    state = "IDLE"
    lost_frames = 0
    last_pos = None
    last_valid_velocity = None
    last_shot_time = 0.0

    # Freeze support
    frozen_frame = first_frame.copy()
    was_paused = False

    while True:
        paused = editor.active or cal.active or picker.active

        # ----- Freeze view & stop advancing when paused -----
        if paused:
            frame = frozen_frame.copy()

            disp = frame.copy()
            # compose static zone overlay (drawn once)
            disp = cv2.add(disp, zone_overlay)

            banner(disp, "PAUSED")
            draw_status_dot(disp, 'yellow')
            if editor.active:
                help_box(disp, [
                    "Sliders write to settings.json immediately,",
                    "but this run uses startup config only.",
                    "Press 'a' to close, restart app to apply."
                ])
            if cal.active:
                from utils.draw_utils import draw_calibration_line
                draw_calibration_line(disp, cfg["calibration"]["line"])
                ppy = compute_px_per_yard()
                cv2.putText(disp, f"px/yd preview: {ppy:.2f}" if ppy else "Calibrate line to yardstick",
                            (12, 90), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (255, 255, 255), 1, cv2.LINE_AA)
            if picker.active:
                picker.render_overlay(disp)

            if not was_paused:
                try:
                    camera.pause()
                except Exception:
                    pass
                was_paused = True

            ui.show(disp)
            # poll keys without blocking
            key = ui.poll()
            if key == ord('q'):
                break
            elif key == ord('m'):
                appsettings.set_value("show_mask", not bool(cfg.get("show_mask", False)))
            elif key == ord('a'):
                editor.toggle(w0, h0)
            elif key == ord('c'):
                if cal.active:
                    ppy = compute_px_per_yard()
                    if ppy:
                        appsettings.set_value("calibration.px_per_yard", float(ppy))
                        log(f"Calibration saved (will apply next run): {ppy:.2f} px/yd")
                    cal.toggle(w0, h0)
                else:
                    cal.toggle(w0, h0)
            elif key == ord('b'):
                if picker.active:
                    picker.commit(frame)
                    picker.toggle(w0, h0)
                    log("Ball color saved (applies next run).")
                else:
                    picker.toggle(w0, h0)
            # light sleep for UI
            time.sleep(0.03)
            continue
        else:
            if was_paused:
                try:
                    camera.resume()
                except Exception:
                    pass
                was_paused = False
            try:
                frame = next(frame_iter)
                frozen_frame = frame.copy()
            except StopIteration:
                break

        disp = frame.copy()
        # compose static zone overlay (drawn once)
        disp = cv2.add(disp, zone_overlay)

        now = time.time()
        if state == "COOLDOWN":
            if (now - last_shot_time) >= COOLDOWN_SEC:
                state = "IDLE"
            banner(disp, "COOLDOWN…")
            draw_status_dot(disp, 'yellow')

        else:
            # Detect only inside union(Stage, Track), downscaled if requested
            union = rect_union(stage, track)
            clamp_rect(union, w0, h0)
            x1, y1, x2, y2 = union["x1"], union["y1"], union["x2"], union["y2"]
            crop = frame[y1:y2, x1:x2]
            if crop.size == 0:
                center, radius = None, None
            else:
                if detect_scale < 1.0:
                    small = cv2.resize(crop, None, fx=detect_scale, fy=detect_scale, interpolation=cv2.INTER_AREA)
                    center_s, radius_s = detector.detect(small)
                    if center_s is not None:
                        cx = center_s[0] / detect_scale
                        cy = center_s[1] / detect_scale
                        center = (cx + x1, cy + y1)
                        radius = (radius_s or 0.0) / detect_scale
                    else:
                        center, radius = None, None
                else:
                    center_c, radius_c = detector.detect(crop)
                    if center_c is not None:
                        center = (center_c[0] + x1, center_c[1] + y1)
                        radius = radius_c
                    else:
                        center, radius = None, None

            if center is None:
                lost_frames = min(999, lost_frames + 1)
            else:
                lost_frames = 0

            if state == "IDLE":
                banner(disp, "IDLE")
                draw_status_dot(disp, 'yellow')
                if rect_contains(center, stage):
                    tracker.reset()
                    last_pos = center
                    state = "STAGED"
                    log("Ball staged (armed).")

            elif state == "STAGED":
                banner(disp, "STAGED → enter TRACK to start")
                draw_status_dot(disp, 'green' if rect_contains(center, stage) else 'yellow')
                if rect_contains(center, track):
                    tracker.reset()
                    last_pos = center
                    state = "TRACKING"
                    log("Tracking started.")

            elif state == "TRACKING":
                banner(disp, "TRACKING")
                if rect_contains(center, track) and center is not None:
                    velocity, _ = tracker.update(center)
                    if velocity is not None:
                        last_valid_velocity = velocity
                    yps, mph = to_real_units(velocity, px_per_yd)
                    draw_ball(disp, center, radius or 0)
                    if last_pos is not None:
                        draw_vector(disp, last_pos, center)
                    put_hud(disp, velocity, None, tracker.fps, mph, yps)
                    draw_status_dot(disp, 'green')
                    last_pos = center
                else:
                    finalize = True
                    if center is None and lost_frames < LOST_FRAMES_LIMIT:
                        finalize = False
                    if finalize:
                        yps_exit, mph_exit = to_real_units(last_valid_velocity, px_per_yd)
                        hla = compute_hla(last_pos, center if center is not None else last_pos)
                        if mph_exit is None or mph_exit >= min_mph:
                            log(f"SHOT: {0.0 if mph_exit is None else mph_exit:.1f} mph | hla={0.0 if hla is None else hla:.2f}°")
                            draw_status_dot(disp, 'red')
                            ui.show(disp)
                            if is_video:
                                time.sleep(wait_ms / 1000.0)
                            post_shot(mph_exit or 0.0, yps_exit or 0.0, hla or 0.0, cfg)
                        else:
                            log(f"IGNORED (under {min_mph:.1f} mph): {0.0 if mph_exit is None else mph_exit:.1f} mph")
                        state = "COOLDOWN"
                        last_shot_time = time.time()
                        tracker.reset()
                        lost_frames = 0

        # Optional mask overlay (debug) — uses cfg-only flag
        if cfg.get("show_mask", False) and getattr(detector, "last_mask", None) is not None:
            mask = cv2.cvtColor(detector.last_mask, cv2.COLOR_GRAY2BGR)
            mh, mw = mask.shape[:2]
            roi_small = disp[0:mh, 0:mw]
            cv2.addWeighted(mask, 0.5, roi_small, 0.5, 0, roi_small)

        # Push the frame to UI
        ui.show(disp)

        # Non-blocking key polling
        key = ui.poll()
        if key == ord('q'):
            break
        elif key == ord('m'):
            appsettings.set_value("show_mask", not bool(cfg.get("show_mask", False)))
        elif key == ord('a'):
            editor.toggle(w0, h0)
        elif key == ord('c'):
            if cal.active:
                ppy = compute_px_per_yard()
                if ppy:
                    appsettings.set_value("calibration.px_per_yard", float(ppy))
                    log(f"Calibration saved (will apply next run): {ppy:.2f} px/yd")
                cal.toggle(w0, h0)
            else:
                cal.toggle(w0, h0)
        elif key == ord('b'):
            if picker.active:
                picker.commit(frame)
                picker.toggle(w0, h0)
                log("Ball color saved (applies next run).")
            else:
                picker.toggle(w0, h0)

        # Throttle sequential video playback so it doesn't race
        if is_video:
            time.sleep(wait_ms / 1000.0)

    editor.close()
    cal.close()
    picker.close()
    try:
        ui.stop()
    except Exception:
        pass
    cv2.destroyAllWindows()


if __name__ == "__main__":
    main()
