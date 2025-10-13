#!/bin/bash

# === Create base directories ===
mkdir -p putttracker/src/{camera,tracking,utils}
mkdir -p putttracker/tests
cd putttracker || exit

# === Create __init__.py files ===
touch src/__init__.py src/camera/__init__.py src/tracking/__init__.py src/utils/__init__.py

# === Create config.py ===
cat << 'EOF' > src/config.py
BALL_COLOR = "white"
COLOR_RANGES = {
    "white": {"lower": (0, 0, 200), "upper": (180, 50, 255)},
    "yellow": {"lower": (20, 100, 100), "upper": (40, 255, 255)},
}
EOF

# === Create logger.py ===
cat << 'EOF' > src/utils/logger.py
def log(message: str):
    print(f"[PUTTTRACKER] {message}")
EOF

# === Create main.py ===
cat << 'EOF' > src/main.py
from tracking.ball_detector import BallDetector
from tracking.motion_tracker import MotionTracker
from camera.capture import Camera
from utils.logger import log

def main():
    camera = Camera(source=0)
    detector = BallDetector()
    tracker = MotionTracker()

    log("Starting ball tracking...")
    for frame in camera.stream():
        ball_position = detector.detect(frame)
        velocity, direction = tracker.update(ball_position)
        if velocity is not None:
            log(f"Velocity: {velocity:.2f} px/s, Direction: {direction:.2f}°")

if __name__ == "__main__":
    main()
EOF

# === Create camera/capture.py ===
cat << 'EOF' > src/camera/capture.py
import cv2

class Camera:
    def __init__(self, source=0):
        self.cap = cv2.VideoCapture(source)
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

# === Create tracking/ball_detector.py ===
cat << 'EOF' > src/tracking/ball_detector.py
import cv2
import numpy as np
from config import BALL_COLOR, COLOR_RANGES

class BallDetector:
    def __init__(self):
        color_range = COLOR_RANGES[BALL_COLOR]
        self.lower = np.array(color_range["lower"])
        self.upper = np.array(color_range["upper"])

    def detect(self, frame):
        hsv = cv2.cvtColor(frame, cv2.COLOR_BGR2HSV)
        mask = cv2.inRange(hsv, self.lower, self.upper)
        contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)

        if not contours:
            return None

        largest = max(contours, key=cv2.contourArea)
        (x, y), radius = cv2.minEnclosingCircle(largest)
        if radius < 3:
            return None

        return (int(x), int(y))
EOF

# === Create tracking/motion_tracker.py ===
cat << 'EOF' > src/tracking/motion_tracker.py
import math
import time

class MotionTracker:
    def __init__(self):
        self.last_position = None
        self.last_time = None

    def update(self, position):
        if position is None:
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

        if dt == 0:
            return None, None

        velocity = math.sqrt(dx**2 + dy**2) / dt
        direction = math.degrees(math.atan2(dy, dx))

        self.last_position = position
        self.last_time = current_time

        return velocity, direction
EOF

# === Create requirements.txt ===
cat << 'EOF' > requirements.txt
opencv-python
numpy
imutils
EOF

# === Create README ===
cat << 'EOF' > README.md
# PuttTracker

A lightweight Raspberry Pi project for detecting and tracking the motion of a golf ball during putting.

## Setup

\`\`\`bash
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
\`\`\`

Run it with:

\`\`\`bash
python3 src/main.py
\`\`\`

## Features
- Ball detection using OpenCV (white ball by default)
- Computes velocity and direction
- Lightweight and Pi 4 compatible
EOF

# === Create .gitignore ===
cat << 'EOF' > .gitignore
venv/
__pycache__/
*.pyc
*.pyo
*.swp
.DS_Store
EOF

echo "✅ PuttTracker skeleton created successfully."
