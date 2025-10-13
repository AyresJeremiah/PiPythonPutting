import cv2
import numpy as np
from config import COLOR_RANGES
import settings as appsettings  # for ball_color & min radius

class BallDetector:
    def __init__(self):
        s = appsettings.load()
        color_name = s.get("ball_color", "white")
        color_range = COLOR_RANGES[color_name]
        self.lower = np.array(color_range["lower"], dtype=np.uint8)
        self.upper = np.array(color_range["upper"], dtype=np.uint8)
        self.min_radius = int(s.get("min_ball_radius_px", 3))
        self.last_mask = None

    def detect(self, frame):
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
        if radius < self.min_radius:
            return None, None

        return (float(x), float(y)), float(radius)
