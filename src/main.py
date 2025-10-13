import cv2
from tracking.ball_detector import BallDetector
from tracking.motion_tracker import MotionTracker
from camera.capture import Camera
from utils.draw_utils import draw_ball, draw_vector, put_hud, draw_roi, banner, help_box
from utils.logger import log
import settings as appsettings
from ui.slider_editor import SliderEditor

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

def main():
    s = appsettings.load()
    show_mask = bool(s.get("show_mask", False))
    target_w = int(s.get("target_width", 960))

    camera = Camera(source=0)
    detector = BallDetector()
    tracker = MotionTracker()

    # Prime first frame to know bounds
    first_frame = next(camera.stream())
    h0, w0 = first_frame.shape[:2]
    appsettings.ensure_roi_initialized(w0, h0)
    appsettings.clamp_roi(w0, h0)
    s = appsettings.load()
    roi = (int(s["roi"]["startx"]), int(s["roi"]["starty"]), int(s["roi"]["endx"]), int(s["roi"]["endy"]))

    cv2.namedWindow("PuttTracker", cv2.WINDOW_NORMAL)
    editor = SliderEditor()

    log("Controls: q=quit | m=mask | a=settings sliders")
    last_pos = None
    last_inside = False
    last_valid_velocity = None
    last_valid_direction = None

    # Iterate with first frame included
    frame_iter = camera.stream()
    def yield_with_first(first, gen):
        yield first
        for f in gen:
            yield f

    for frame in yield_with_first(first_frame, frame_iter):
        s = appsettings.load()
        show_mask = bool(s.get("show_mask", show_mask))
        target_w = int(s.get("target_width", target_w))
        roi = (int(s["roi"]["startx"]), int(s["roi"]["starty"]), int(s["roi"]["endx"]), int(s["roi"]["endy"]))

        paused = editor.active  # <- when sliders are open, pause processing

        if paused:
            # Ensure clean resume (no velocity spikes or stale “inside” state)
            tracker.reset()
            last_pos = None
            last_inside = False

            # Just draw UI hints + ROI box; skip detection/tracking/logging
            draw_roi(frame, roi)
            banner(frame, "SLIDER EDIT MODE (processing paused)")
            help_box(frame, [
                "Adjust ROI & settings in the sliders window",
                "Press 'a' to close sliders and resume",
                "m: toggle mask | q: quit"
            ])
        else:
            # Normal processing
            center, radius = detector.detect(frame)
            in_area = inside_roi(center, roi)

            velocity, direction = tracker.update(center if in_area else None)
            if velocity is not None:
                last_valid_velocity = velocity
                last_valid_direction = direction

            # Exit event: was inside, now outside
            if last_inside and not in_area:
                if last_valid_velocity is not None:
                    log(f"SHOT: vel={last_valid_velocity:.2f} px/s, dir={last_valid_direction:.2f}° (exited ROI)")
            last_inside = in_area

            # Overlays
            draw_ball(frame, center if in_area else None, radius if in_area and radius else 0.0)
            draw_roi(frame, roi)
            if in_area:
                draw_vector(frame, last_pos, center)
            put_hud(frame, velocity if in_area else None, direction if in_area else None, tracker.fps)

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
            # Toggle sliders; processing will pause/resume automatically
            editor.toggle(w0, h0)

        last_pos = center if in_area else last_pos

    editor.close()
    cv2.destroyAllWindows()

if __name__ == "__main__":
    main()
