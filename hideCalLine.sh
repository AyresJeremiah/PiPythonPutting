#!/bin/bash
set -e

if [ ! -f "src/main.py" ]; then
  echo "Run this from your project root (where src/main.py exists)."
  exit 1
fi

cat > src/main.py << 'EOF'
import cv2
from tracking.ball_detector import BallDetector
from tracking.motion_tracker import MotionTracker
from camera.capture import Camera
from utils.draw_utils import (
    draw_ball, draw_vector, put_hud, draw_roi, banner, help_box, draw_calibration_line
)
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
    """Return (yd/s, mph) from px/s using calibrated px_per_yard (None-safe)."""
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

    # Prime first frame to initialize ROI & UI bounds
    frame_iter = camera.stream()
    first_frame = next(frame_iter)
    h0, w0 = first_frame.shape[:2]
    appsettings.ensure_roi_initialized(w0, h0)
    appsettings.clamp_roi(w0, h0)

    s = appsettings.load()
    roi = (int(s["roi"]["startx"]), int(s["roi"]["starty"]),
           int(s["roi"]["endx"]),   int(s["roi"]["endy"]))

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
        # Live-load toggles/sizing and ROI from settings
        s = appsettings.load()
        show_mask = bool(s.get("show_mask", show_mask))
        target_w = int(s.get("target_width", target_w))
        roi = (int(s["roi"]["startx"]), int(s["roi"]["starty"]),
               int(s["roi"]["endx"]),   int(s["roi"]["endy"]))

        paused = editor.active or cal.active  # pause processing when any UI is open

        if paused:
            # Pause detection/tracking/logging and show appropriate UI
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
                # Show calibration line ONLY while calibrating
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

        else:
            # Normal processing (no calibration line drawn here)
            center, radius = detector.detect(frame)
            in_area = inside_roi(center, roi)

            velocity, direction = tracker.update(center if in_area else None)
            if velocity is not None:
                last_valid_velocity = velocity
                last_valid_direction = direction

            # Use saved calibration only (no auto compute)
            px_per_yard = s["calibration"]["px_per_yard"]
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

            # Overlays while running
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

            last_pos = center if in_area else last_pos

        # Present
        preview = resize_keep_aspect(frame, target_w)
        cv2.imshow("PuttTracker", preview)

        # Input
        key = cv2.waitKey(1) & 0xFF
        if key == ord('q'):
            break
        elif key == ord('m'):
            appsettings.set_value("show_mask", not bool(s.get("show_mask", False)))
        elif key == ord('a'):
            editor.toggle(w0, h0)
        elif key == ord('c'):
            # When closing calibration, compute & persist px/yard if valid; line will no longer show
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

echo "✅ Updated main.py: calibration line now only shows during calibration, no auto-recompute during normal run."
