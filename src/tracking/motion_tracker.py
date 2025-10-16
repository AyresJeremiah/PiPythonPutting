import math
import time

class PosAndTime:
    def __init__(self, position, timestamp):
        self.position = position
        self.timestamp = timestamp

class MotionTracker:
    def __init__(self):
        self.position_and_times = []
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
        self.position_and_times = []

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
            return

        self.position_and_times.append((position, time.time()))

    def get_final_speed_and_direction(self):
        # TODO Could check if the points are roughly collinear and ignore outliers in case we track something we dont want.

        length = len(self.position_and_times)
        if length < 2:
            return None, None

        (first_pos, time1) = self.position_and_times[0] #self.last_position
        (last_pos, time2) = self.position_and_times[length-1]

        (x1, y1) = first_pos
        (x2, y2) = last_pos

        dx = x2 - x1
        dy = y2 - y1
        dt = time2 - time1
        if dt <= 0:
            return None, None

        velocity = math.sqrt(dx * dx + dy * dy) / dt  # px/s

        return velocity, self.compute_hla(first_pos, last_pos)

    def compute_hla(self, start_pos, end_pos):
        if start_pos is None or end_pos is None:
            return None
        (x1, y1), (x2, y2) = start_pos, end_pos
        dx, dy = (x2 - y2), (y1 - y2) #TODO NEED A WAY TO CONFIG THIS IN SETTINGS
        heading = math.degrees(math.atan2(-dy, dx))
        # Left negative, right positive, clamp [-60, 60]
        return heading