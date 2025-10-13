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
