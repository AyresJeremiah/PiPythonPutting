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

    def reset(self):
        """Clear state so velocity/dir don’t spike after unpausing."""
        self.last_position = None
        self.last_time = None

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
