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
