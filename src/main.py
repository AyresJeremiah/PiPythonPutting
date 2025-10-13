import cv2
from tracking.ball_detector import BallDetector
from tracking.motion_tracker import MotionTracker
from camera.capture import Camera
from utils.draw_utils import draw_ball, draw_vector, put_hud
from utils.logger import log
from config import SHOW_MASK, TARGET_WIDTH

def resize_keep_aspect(frame, target_w):
    h, w = frame.shape[:2]
    if w == 0 or h == 0:
        return frame
    scale = target_w / float(w)
    return cv2.resize(frame, (int(w*scale), int(h*scale)))

def main():
    camera = Camera(source=0)  # on Mac, 0 = default webcam
    detector = BallDetector()
    tracker = MotionTracker()

    show_mask = SHOW_MASK
    cv2.namedWindow("PuttTracker", cv2.WINDOW_NORMAL)

    log("Starting ball tracking... (press 'q' to quit, 'm' to toggle mask)")
    last_pos = None

    for frame in camera.stream():
        center, radius = detector.detect(frame)
        velocity, direction = tracker.update(center)

        # Draw overlays
        draw_ball(frame, center, radius if radius else 0.0)
        draw_vector(frame, last_pos, center)
        put_hud(frame, velocity, direction, tracker.fps)

        # Optional mask view (top-left picture-in-picture)
        if show_mask and detector.last_mask is not None:
            mask = cv2.cvtColor(detector.last_mask, cv2.COLOR_GRAY2BGR)
            mh, mw = mask.shape[:2]
            roi = frame[0:mh, 0:mw]
            alpha = 0.5
            cv2.addWeighted(mask, alpha, roi, 1 - alpha, 0, roi)

        preview = resize_keep_aspect(frame, TARGET_WIDTH)
        cv2.imshow("PuttTracker", preview)

        key = cv2.waitKey(1) & 0xFF
        if key == ord('q'):
            break
        elif key == ord('m'):
            show_mask = not show_mask

        last_pos = center

    cv2.destroyAllWindows()

if __name__ == "__main__":
    main()
