import cv2
import math
import settings as appsettings

class CalibrationEditor:
    def __init__(self, window_name="PuttTracker Calibration"):
        self.name = window_name
        self.active = False
        self._w = None
        self._h = None
        self._lock = False

    def _safe_set(self, keypath, value):
        if self._lock: return
        self._lock = True
        appsettings.set_value(keypath, value)
        self._lock = False

    def _sync(self):
        appsettings.clamp_calibration(self._w, self._h)
        s = appsettings.load()
        L = s["calibration"]["line"]
        cv2.setTrackbarPos("x1", self.name, int(L["x1"]))
        cv2.setTrackbarPos("y1", self.name, int(L["y1"]))
        cv2.setTrackbarPos("x2", self.name, int(L["x2"]))
        cv2.setTrackbarPos("y2", self.name, int(L["y2"]))
        cv2.setTrackbarPos("yards_len x10", self.name, int(round(float(s["calibration"]["yards_length"])*10)))

    def _on_x1(self, v): self._safe_set("calibration.line.x1", v); appsettings.clamp_calibration(self._w, self._h)
    def _on_y1(self, v): self._safe_set("calibration.line.y1", v); appsettings.clamp_calibration(self._w, self._h)
    def _on_x2(self, v): self._safe_set("calibration.line.x2", v); appsettings.clamp_calibration(self._w, self._h)
    def _on_y2(self, v): self._safe_set("calibration.line.y2", v); appsettings.clamp_calibration(self._w, self._h)
    def _on_len(self, v): self._safe_set("calibration.yards_length", max(0.1, v/10.0))

    def open(self, frame_width, frame_height):
        self._w, self._h = int(frame_width), int(frame_height)
        appsettings.clamp_calibration(self._w, self._h)
        cv2.namedWindow(self.name, cv2.WINDOW_NORMAL)
        cv2.resizeWindow(self.name, 420, 260)
        s = appsettings.load()
        L = s["calibration"]["line"]
        cv2.createTrackbar("x1", self.name, int(L["x1"]), self._w-1, lambda v: self._on_x1(v))
        cv2.createTrackbar("y1", self.name, int(L["y1"]), self._h-1, lambda v: self._on_y1(v))
        cv2.createTrackbar("x2", self.name, int(L["x2"]), self._w-1, lambda v: self._on_x2(v))
        cv2.createTrackbar("y2", self.name, int(L["y2"]), self._h-1, lambda v: self._on_y2(v))
        cv2.createTrackbar("yards_len x10", self.name, int(round(float(s["calibration"]["yards_length"])*10)), 50, lambda v: self._on_len(v))
        self._sync()
        self.active = True

    def close(self):
        if self.active:
            try: cv2.destroyWindow(self.name)
            except Exception: pass
        self.active = False

    def toggle(self, frame_width, frame_height):
        if self.active: self.close()
        else: self.open(frame_width, frame_height)

def compute_px_per_yard():
    s = appsettings.load()
    L = s["calibration"]["line"]
    yards_len = float(s["calibration"].get("yards_length", 1.0))
    if yards_len <= 0: return None
    dx = float(L["x2"]) - float(L["x1"])
    dy = float(L["y2"]) - float(L["y1"])
    dist_px = math.hypot(dx, dy)
    if dist_px <= 0: return None
    return dist_px / yards_len
