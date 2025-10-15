import cv2
from src.utils.runtime_cfg import get_cfg
import numpy as np
from src.config import COLOR_RANGES

class BallDetector:
    def __init__(self):
        self.last_mask = None
        self.lower = None
        self.upper = None
        self.min_radius = None
        self.refresh_from_settings()

    def refresh_from_settings(self):
        s = get_cfg()
        self.min_radius = int(s.get("min_ball_radius_px", 3))
        custom = s.get("ball_hsv", {"lower": None, "upper": None})
        if custom and custom.get("lower") and custom.get("upper"):
            self.lower = np.array(custom["lower"], dtype=np.uint8)
            self.upper = np.array(custom["upper"], dtype=np.uint8)
        else:
            color_name = s.get("ball_color", "white")
            cr = COLOR_RANGES.get(color_name, COLOR_RANGES["white"])
            self.lower = np.array(cr["lower"], dtype=np.uint8)
            self.upper = np.array(cr["upper"], dtype=np.uint8)

    def detect(self, frame):
        # Refresh in case settings changed (cheap)
        self.refresh_from_settings()

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
