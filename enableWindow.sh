#!/bin/bash
set -e

# Ensure we're inside the project root
if [ ! -d "src" ]; then
  echo "Run this from the putttracker project root (where ./src exists)."
  exit 1
fi

# --- config.py (add SHOW_MASK & min radius) ---
cat > src/config.py << 'EOF'
BALL_COLOR = "white"
COLOR_RANGES = {
    "white": {"lower": (0, 0, 200), "upper": (180, 50, 255)},   # HSV range for white
    "yellow": {"lower": (20, 100, 100), "upper": (40, 255, 255)}
}

MIN_BALL_RADIUS_PX = 3      # ignore tiny specks
SHOW_MASK = False           # press 'm' in the app to toggle
TARGET_WIDTH = 960          # preview width; height keeps aspect
EOF

# --- utils/logger.py ---
mkdir -p src/utils
cat > src/utils/logger.py << 'EOF'
def log(message: str):
    print(f"[PUTTTRACKER] {message}")
EOF

# --- utils/draw_utils.py ---
cat > src/utils/draw_utils.py << 'EOF'
import cv2

def draw_ball(frame, center, radius):
    if center is None:
        return
    (x, y) = center
    cv2.circle(frame, (int(x), int(y)), int(radius), (0, 255, 0), 2)
    cv2.circle(frame, (int(x), int(y)), 3, (0, 0, 255), -1)

def draw_vector(frame, p1, p2):
    if p1 is None or p2 is None:
        return
    (x1, y1) = map(int, p1)
    (x2, y2) = map(int, p2)
    cv2.arrowedLine(frame, (x1, y1), (x2, y2), (255, 0, 0), 2, tipLength=0.25)

def put_hud(frame, velocity, direction, fps):
    h = 22
    y = 28
    text = []
    if velocity is not None:
        text.append(f"vel: {velocity:.1f} px/s")
    if direction is not None:
        text.append(f"dir: {direction:.1f}°")
    if fps is not None:
        text.append(f"fps: {fps:.1f}")
    if not text:
        return
    cv2.rectangle(frame, (8, 6), (8 + 250, 6 + h + 10), (0, 0, 0), -1)
    cv2.putText(frame, " | ".join(text), (12, 24), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (255,255,255), 1, cv2.LINE_AA)
EOF

# --- camera/capture.py ---
mkdir -p src/camera
cat > src/camera/capture.py << 'EOF'
import cv2

class Camera:
    def __init__(self, source=0, width=None, height=None):
        self.cap = cv2.VideoCapture(source)
        if width is not None:
            self.cap.set(cv2.CAP_PROP_FRAME_WIDTH, width)
        if height is not None:
            self.cap.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
        if not self.cap.isOpened():
            raise RuntimeError("Failed to open camera source.")

    def stream(self):
        while True:
            ret, frame = self.cap.read()
            if not ret:
                break
            yield frame
        self.cap.release()
EOF

# --- tracking/ball_detector.py ---
mkdir -p src/tracking
cat > src/tracking/ball_detector.py << 'EOF'
import cv2
import numpy as np
from config import BALL_COLOR, COLOR_RANGES, MIN_BALL_RADIUS_PX

class BallDetector:
    def __init__(self):
        color_range = COLOR_RANGES[BALL_COLOR]
        self.lower = np.array(color_range["lower"], dtype=np.uint8)
        self.upper = np.array(color_range["upper"], dtype=np.uint8)
        self.last_mask = None

    def detect(self, frame):
        # Preprocess for robustness
        blurred = cv2.GaussianBlur(frame, (5, 5), 0)
        hsv = cv2.cvtColor(blurred, cv2.COLOR_BGR2HSV)

        mask = cv2.inRange(hsv, self.lower, self.upper)
        mask = cv2.erode(mask, None, iterations=1)
        mask = cv2.dilate(mask, None, iterations=2)
        self.last_mask = mask

        contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        if not contours:
            return None, None

        largest = max(contours, key=cv2.contourArea)
        (x, y), radius = cv2.minEnclosingCircle(largest)
        if radius < MIN_BALL_RADIUS_PX:
            return None, None

        return (float(x), float(y)), float(radius)
EOF

# --- tracking/motion_tracker.py ---
cat > src/tracking/motion_tracker.py << 'EOF'
import math
import time

class MotionTracker:
    def __init__(self):
        self.last_position = None
        self.last_time = None
        self._fps_time = time.time()
        self._frames = 0
        self._fps = None

    @property
    def fps(self):
        return self._fps

    def _tick_fps(self):
        self._frames += 1
        now = time.time()
        if now - self._fps_time >= 1.0:
            self._fps = self._frames / (now - self._fps_time)
            self._frames = 0
            self._fps_time = now

    def update(self, position):
        self._tick_fps()

        if position is None:
            self.last_position = None   # reset continuity when ball lost
            self.last_time = None
            return None, None

        current_time = time.time()

        if self.last_position is None:
            self.last_position = position
            self.last_time = current_time
            return None, None

        (x1, y1) = self.last_position
        (x2, y2) = position
        dx = x2 - x1
        dy = y2 - y1
        dt = current_time - self.last_time
        if dt <= 0:
            return None, None

        velocity = math.sqrt(dx*dx + dy*dy) / dt     # px/s
        direction = math.degrees(math.atan2(dy, dx)) # -180..180, 0 = right

        self.last_position = position
        self.last_time = current_time
        return velocity, direction
EOF

# --- main.py (windowed preview + overlay + mask toggle) ---
cat > src/main.py << 'EOF'
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
EOF

# --- requirements.txt (ensure deps) ---
cat > requirements.txt << 'EOF'
opencv-python
numpy
imutils
EOF

echo "✅ Preview-enabled files written. Activate your venv and run:  python3 src/main.py"
