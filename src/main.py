import time, math, cv2, numpy as np
from src.services.gspro import post_shot
from src.tracking.ball_detector import BallDetector
from src.tracking.motion_tracker import MotionTracker
from src.camera.capture import Camera as CvCamera, PiCam2Camera
from src.utils.logger import log
import src.settings as appsettings
from src.ui.webui import WebUI
from src.utils.runtime_cfg import set_cfg

COOLDOWN_SEC = 1.0
LOST_FRAMES_LIMIT = 6

# --- Optional: make PyCharm attach very early in debug runs ---
import os
if os.environ.get("PYCHARM_EARLY_DEBUG", "0") == "1":
    try:
        import pydevd_pycharm
        # If you're debugging on the same machine, host='localhost'
        pydevd_pycharm.settrace('localhost', port=5678, stdoutToServer=True, stderrToServer=True, suspend=False)
    except Exception:
        pass


# ----------------- helpers -----------------
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


def compute_hla(last_pos, cur_pos): #TODO REMOVE THIS
    if last_pos is None or cur_pos is None:
        return None
    (x1, y1), (x2, y2) = last_pos, cur_pos
    dx, dy = (x1 - x2), (y1 - y2)
    heading = math.degrees(math.atan2(-dy, dx))
    # Left negative, right positive, clamp [-60, 60]
    return -heading


def main():
    cv2.setNumThreads(1)

    # === LOAD SETTINGS ONCE (kept in-memory) ===
    cfg = appsettings.load()
    set_cfg(cfg)  # share globally in-memory

    target_w   = int(cfg.get("target_width", 960))
    min_mph    = float(cfg.get("min_report_mph", 1.0))
    inp        = cfg.get("input", {})
    px_per_yd  = cfg.get("calibration", {}).get("px_per_yard", 1.0)
    detect_cfg = cfg.get("detect", {})
    detect_scale = float(detect_cfg.get("scale", 0.75))
    if detect_scale <= 0 or detect_scale > 1.0:
        detect_scale = 1.0

    # Input source
    inp = cfg.get("input", {})
    cam_cfg = cfg.get("camera", {})
    cam_type = cam_cfg.get("type", inp.get("backend", "v4l2")).lower()  # accept legacy input.backend

    if inp.get("source","camera") == "video":
        camera = CvCamera(source=inp.get("video_path","testdata/my_putt.mp4"), loop=bool(inp.get("loop", True)))
        is_video = True
    else:
        is_video = False
        if cam_type == "picam2":
            camera = PiCam2Camera(
                width=cam_cfg.get("width", 1332),
                height=cam_cfg.get("height", 990),
                fps=cam_cfg.get("fps", 120),
                shutter_us=cam_cfg.get("shutter_us", 5000),
                gain=cam_cfg.get("gain", 1.5),
                denoise=cam_cfg.get("denoise", "off"),
            )
        else:
            camera = CvCamera(
                source=inp.get("camera_index", 0),
                width=cam_cfg.get("width", 1280),
                height=cam_cfg.get("height", 720),
            )



    detector = BallDetector()
    tracker  = MotionTracker()

    # Timing & physics dt
    is_video = (inp.get("source") == "video")
    wait_ms = 1
    if is_video:
        cap_tmp = cv2.VideoCapture(inp.get("video_path", "testdata/my_putt.mp4"))
        vid_fps = cap_tmp.get(cv2.CAP_PROP_FPS) or 30.0
        cap_tmp.release()
        speed = float(inp.get("playback_speed", 1.0))
        try:
            wait_ms = max(1, int(round(1000.0 / (float(vid_fps) * max(0.01, speed)))))
        except Exception:
            wait_ms = 33

    # First frame & zones
    frame_iter  = camera.stream()
    first_frame = next(frame_iter)
    h0, w0 = first_frame.shape[:2]
    appsettings.ensure_zones_initialized(w0, h0)
    appsettings.clamp_zones(w0, h0)

    # Zones from cfg (kept in-memory; front-end draws overlays)
    stage = cfg["zones"]["stage_roi"]
    track = cfg["zones"]["track_roi"]

    # ---------- settings management ----------
    def _atomic_write_settings(cfg_dict):
        import tempfile, json, os
        settings_path = os.path.join(os.path.dirname(os.path.dirname(__file__)), "settings.json")
        d = os.path.dirname(settings_path)
        os.makedirs(d, exist_ok=True)
        fd, tmp = tempfile.mkstemp(prefix="settings.", suffix=".json", dir=d)
        try:
            with os.fdopen(fd, "w") as f:
                json.dump(cfg_dict, f, indent=2)
            os.replace(tmp, settings_path)
        finally:
            try: os.remove(tmp)
            except Exception: pass

    def _deep_merge(dst, src):
        for k, v in src.items():
            if isinstance(v, dict) and isinstance(dst.get(k), dict):
                _deep_merge(dst[k], v)
            else:
                dst[k] = v

    def _rebuild_from_cfg():
        nonlocal target_w, min_mph, inp, px_per_yd, detect_scale, stage, track, is_video, wait_ms
        target_w   = int(cfg.get("target_width", target_w))
        min_mph    = float(cfg.get("min_report_mph", min_mph))
        inp        = cfg.get("input", inp)
        px_per_yd  = cfg.get("calibration",{}).get("px_per_yard", px_per_yd)
        detect_scale = float(cfg.get("detect",{}).get("scale", detect_scale))
        if detect_scale <= 0 or detect_scale > 1.0:
            detect_scale = 1.0
        # refresh rects
        stage = cfg["zones"]["stage_roi"]
        track = cfg["zones"]["track_roi"]
        # camera controls (live preview)
        try:
            camera.apply_controls(cfg.get('camera', {}))
        except Exception:
            pass

        # refresh pacing
        is_video = (inp.get("source") == "video")
        if is_video:
            _cap = cv2.VideoCapture(inp.get("video_path", "testdata/my_putt.mp4"))
            _fps = _cap.get(cv2.CAP_PROP_FPS) or 30.0
            _cap.release()
            try:
                wait_ms = max(1, int(round(1000.0 / (float(_fps) * max(0.01, float(inp.get("playback_speed",1.0)))))))
            except Exception:
                wait_ms = 33

    # ---------- Web UI ----------
    web = WebUI(port=8080, jpeg_quality=80)
    web.set_cfg_provider(lambda: {
        **cfg,
        "dims": {"w": int(w0), "h": int(h0)}
    })

    def _apply_preview(new_cfg: dict):
        _deep_merge(cfg, new_cfg)
        _rebuild_from_cfg()

    def _apply_save(new_cfg: dict):
        _apply_preview(new_cfg)
        _atomic_write_settings(cfg)
        # live-apply camera format if provided
        try:
            camc = cfg.get('camera', {})
            fmt  = camc.get('fourcc')
            w    = camc.get('width')
            h    = camc.get('height')
            fpsv = camc.get('fps')
            if (fmt is not None) or (w is not None) or (h is not None) or (fpsv is not None):
                camera.apply_format(fmt, w, h, fpsv)
        except Exception:
            pass
        # live-apply camera controls (both backends)
        try:
            camera.apply_controls(cfg.get('camera', {}))
        except Exception:
            pass

        # If V4L2 and user changed format/size/fps, try to apply without restart
        try:
            cam_type_now = cfg.get('camera',{}).get('type','v4l2').lower()
            if cam_type_now != 'picam2':
                cc = cfg.get('camera',{})
                camera.apply_format(cc.get('fourcc'), cc.get('width'), cc.get('height'), cc.get('fps'))
        except Exception:
            pass



    web.on_settings_preview(_apply_preview)
    web.on_settings_save(_apply_save)

    # color pick: sample HSV at click, set detector bounds live
    def _on_ball_pick(payload: dict):
        try:
            x = int(payload.get("x", 0)); y = int(payload.get("y", 0))
        except Exception:
            return {"ok": False, "error": "invalid xy"}

        frame = web.get_latest_frame()
        if frame is None:
            return {"ok": False, "error": "no frame available"}

        h, w = frame.shape[:2]
        x1 = max(0, min(w-1, x-2)); x2 = max(1, min(w, x+3))
        y1 = max(0, min(h-1, y-2)); y2 = max(1, min(h, y+3))
        patch = frame[y1:y2, x1:x2].copy()
        if patch.size == 0:
            return {"ok": False, "error": "empty patch"}

        hsv = cv2.cvtColor(patch, cv2.COLOR_BGR2HSV)
        H = int(np.median(hsv[:,:,0])); S = int(np.median(hsv[:,:,1])); V = int(np.median(hsv[:,:,2]))

        # tolerance bands
        dh, ds, dv = 10, 70, 70
        lower = [max(0, H-dh), max(0, S-ds), max(0, V-dv)]
        upper = [min(179, H+dh), min(255, S+ds), min(255, V+dv)]

        cfg["ball_hsv"] = {"lower": lower, "upper": upper}
        if hasattr(detector, "set_hsv"):
            try:
                detector.set_hsv(tuple(lower), tuple(upper))
            except Exception:
                pass

        # persist preview immediately? (we keep it preview-only; Save will persist)
        return {"ok": True, "hsv": [H,S,V], "bounds": {"lower": lower, "upper": upper}}

    # calibration line: compute px/yard; optionally save
    def _on_cal_line(payload: dict):
        try:
            x1 = int(payload.get("x1")); y1 = int(payload.get("y1"))
            x2 = int(payload.get("x2")); y2 = int(payload.get("y2"))
        except Exception:
            return {"ok": False, "error": "invalid line endpoints"}
        try:
            yards = float(payload.get("yards", 1.0))
        except Exception:
            yards = 1.0
        if yards <= 0:
            yards = 1.0

        dx = float(x2 - x1); dy = float(y2 - y1)
        px = (dx*dx + dy*dy) ** 0.5
        px_per_yard = px / max(1e-6, yards)

        cfg.setdefault("calibration", {})
        cfg["calibration"]["px_per_yard"] = float(px_per_yard)
        cfg["calibration"]["line"] = {"x1": x1, "y1": y1, "x2": x2, "y2": y2}

        if bool(payload.get("save", False)):
            _atomic_write_settings(cfg)

        return {"ok": True, "px_per_yard": round(float(px_per_yard), 4)}

    web.on_ball_pick(_on_ball_pick)
    web.on_calibration_line(_on_cal_line)
    web.start()

    log("Web UI: http://localhost:8080  (front-end draws Stage/Track/Cal; backend sends raw frames)")

    # ---------- state machine ----------
    state = "IDLE"
    lost_frames = 0
    last_pos = None
    last_shot_time = 0.0
    tracking_delay_post_time = 2.0
    tracking_stop_time = None

    while True:
        try:
            frame = next(frame_iter)
        except StopIteration:
            break

        now  = time.time()

        center, radius = None, None
        mph, yps = None, None

        if state == "COOLDOWN":
            if (now - last_shot_time) >= COOLDOWN_SEC:
                state = "IDLE"

        else:
            # Detect inside Stage ∪ Track (downscaled if requested)
            union = rect_union(stage, track)
            clamp_rect(union, w0, h0)
            x1, y1, x2, y2 = union["x1"], union["y1"], union["x2"], union["y2"]
            crop = frame[y1:y2, x1:x2]

            if crop.size:
                if detect_scale < 1.0:
                    small = cv2.resize(crop, None, fx=detect_scale, fy=detect_scale, interpolation=cv2.INTER_AREA)
                    c_s, r_s = detector.detect(small)
                    if c_s is not None:
                        cx = c_s[0] / detect_scale
                        cy = c_s[1] / detect_scale
                        center = (cx + x1, cy + y1)
                        radius = (r_s or 0.0) / detect_scale
                else:
                    c_c, r_c = detector.detect(crop)
                    if c_c is not None:
                        center = (c_c[0] + x1, c_c[1] + y1)
                        radius = r_c

            if center is None:
                lost_frames = min(999, lost_frames + 1)
            else:
                lost_frames = 0

            if state == "IDLE":
                if rect_contains(center, stage):
                    tracker.reset(); last_pos = center; state = "STAGED"; log("Ball staged (armed).")

            elif state == "STAGED":
                if rect_contains(center, track):
                    tracker.reset()
                    last_pos = center
                    state = "TRACKING"
                    tracking_stop_time =  time.time() + tracking_delay_post_time
                    # start_pos = center
                    log("Tracking started.")

            elif state == "TRACKING":
                #start Timer to stop tracking after delay
                if rect_contains(center, track):
                    tracker.update(center)
                    last_pos = center
                if time.time() > tracking_stop_time:
                    log("Tracking Complete.")
                    state = "FINALIZE"

            elif state == "FINALIZE":
                (velocity, hla) = tracker.get_final_speed_and_direction()
                if velocity is not None and hla is not None:
                    yps_exit, mph_exit = to_real_units(velocity, px_per_yd)
                    if (mph_exit is None or mph_exit >= min_mph) and -60.0 < hla < 60.0:
                        log(f"SHOT: {0.0 if mph_exit is None else mph_exit:.1f} mph | hla={0.0 if hla is None else hla:.2f}°")
                        try:
                            post_shot(mph_exit or 0.0, hla or 0.0, cfg)
                            state = "COOLDOWN"
                            last_shot_time = time.time()
                            tracker.reset()
                            lost_frames = 0
                        except Exception as e:
                            log(f"POST error: {e}")
                    else:
                        log(f"IGNORED (Min {min_mph:.1f} mph): Actual:{"NULL" if mph_exit is None else mph_exit:.1f} mph")
                        log(f"Launch angle. Required range is [-60°, 60°] Actual: {"NULL" if hla is None else hla:.2f}° ")
                        state = "COOLDOWN"
                        last_shot_time = time.time()
                        tracker.reset()
                        lost_frames = 0
                else:
                    #Failed shot discard
                    state = "COOLDOWN"
                    last_shot_time = time.time()
                    tracker.reset()
                    lost_frames = 0

        # Optional mask overlay (debug) — front-end overlays are all client-side now
        disp = frame.copy()
        if cfg.get("show_mask", False) and getattr(detector, "last_mask", None) is not None:
            mask = cv2.cvtColor(detector.last_mask, cv2.COLOR_GRAY2BGR)
            mh, mw = mask.shape[:2]
            roi_small = disp[0:mh, 0:mw]
            cv2.addWeighted(mask, 0.5, roi_small, 0.5, 0, roi_small)

        # Telemetry to web UI
        fps_val = getattr(tracker, "fps", None)
        try: fps_val = 0.0 if fps_val is None else float(fps_val)
        except (TypeError, ValueError): fps_val = 0.0

        tele = {
            'stage': {'x1': int(stage['x1']), 'y1': int(stage['y1']), 'x2': int(stage['x2']), 'y2': int(stage['y2'])},
            'track': {'x1': int(track['x1']), 'y1': int(track['y1']), 'x2': int(track['x2']), 'y2': int(track['y2'])},
            'ball': ({'x': float(center[0]), 'y': float(center[1]), 'r': float(radius)}) if center is not None else None,
            'state': state,
            'mph': float(mph) if mph is not None else 0.0,
            'yps': float(yps) if yps is not None else 0.0,
            'hla': float(compute_hla(last_pos, center)) if (center is not None and last_pos is not None) else 0.0,
            'fps': fps_val,
            'dims': {'w': int(w0), 'h': int(h0)}
        }
        try:
            web.push_telemetry(tele)
            web.push_frame(disp)
        except Exception:
            pass

        # pace video playback
        if is_video:
            time.sleep(wait_ms / 1000.0)

    # Cleanup
    try: camera.close()
    except Exception: pass
    log("Exiting.")


if __name__ == "__main__":
    main()
