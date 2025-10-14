import cv2
import settings as appsettings

class SliderEditor:
    """
    Settings window with live sliders. Processing is paused while this is open.
    Sliders:
      - ROI: startx/starty/endx/endy
      - Gate line: gate_x1/gate_y1/gate_x2/gate_y2, gate_enabled
      - min_ball_radius_px
      - min_report_mph (0.00 .. 30.00 mph, step 0.01)
      - target_width (preview width)
      - show_mask (toggle)
    """
    def __init__(self, window_name: str = "PuttTracker Settings"):
        self.win = window_name
        self.active = False
        self._w = None
        self._h = None

    # ------- helpers -------
    def _set(self, path, value):
        appsettings.set_value(path, value)

    def _clamp(self, v, lo, hi):
        return max(lo, min(int(v), hi))

    # ------- trackbar callbacks (lambda-friendly wrappers) -------
    def _cb_roi_x1(self, v): self._set("roi.startx", self._clamp(v, 0, self._w - 1))
    def _cb_roi_y1(self, v): self._set("roi.starty", self._clamp(v, 0, self._h - 1))
    def _cb_roi_x2(self, v): self._set("roi.endx",   self._clamp(v, 1, self._w))
    def _cb_roi_y2(self, v): self._set("roi.endy",   self._clamp(v, 1, self._h))

    def _cb_gate_x1(self, v): self._set("gate.line.x1", self._clamp(v, 0, self._w - 1))
    def _cb_gate_y1(self, v): self._set("gate.line.y1", self._clamp(v, 0, self._h - 1))
    def _cb_gate_x2(self, v): self._set("gate.line.x2", self._clamp(v, 0, self._w - 1))
    def _cb_gate_y2(self, v): self._set("gate.line.y2", self._clamp(v, 0, self._h - 1))
    def _cb_gate_enabled(self, v): self._set("gate.enabled", bool(v))

    def _cb_min_rad(self, v): self._set("min_ball_radius_px", self._clamp(v, 1, 200))
    def _cb_show_mask(self, v): self._set("show_mask", bool(v))

    # mph slider is int 0..3000 -> 0.00..30.00 mph
    def _cb_min_mph(self, v): self._set("min_report_mph", float(v) / 100.0)

    # target_width: clamp to >=320
    def _cb_target_w(self, v):
        v = int(v)
        if v < 320: v = 320
        self._set("target_width", v)

    # ------- public API -------
    def open(self, frame_width: int, frame_height: int):
        """Create window + sliders using CURRENT settings values."""
        self._w, self._h = int(frame_width), int(frame_height)
        s = appsettings.load()  # current values

        try:
            cv2.namedWindow(self.win, cv2.WINDOW_NORMAL)
            cv2.resizeWindow(self.win, 420, 520)
        except Exception:
            pass

        # ROI sliders
        cv2.createTrackbar("roi_startx", self.win, 0, max(1, self._w - 1), lambda v: self._cb_roi_x1(v))
        cv2.createTrackbar("roi_starty", self.win, 0, max(1, self._h - 1), lambda v: self._cb_roi_y1(v))
        cv2.createTrackbar("roi_endx",   self.win, 1, max(1, self._w),     lambda v: self._cb_roi_x2(v))
        cv2.createTrackbar("roi_endy",   self.win, 1, max(1, self._h),     lambda v: self._cb_roi_y2(v))

        # Gate line sliders + enable
        cv2.createTrackbar("gate_x1", self.win, 0, max(1, self._w - 1), lambda v: self._cb_gate_x1(v))
        cv2.createTrackbar("gate_y1", self.win, 0, max(1, self._h - 1), lambda v: self._cb_gate_y1(v))
        cv2.createTrackbar("gate_x2", self.win, 0, max(1, self._w - 1), lambda v: self._cb_gate_x2(v))
        cv2.createTrackbar("gate_y2", self.win, 0, max(1, self._h - 1), lambda v: self._cb_gate_y2(v))
        cv2.createTrackbar("gate_enabled", self.win, 0, 1, lambda v: self._cb_gate_enabled(v))

        # Ball/min radius, min mph, target width, show mask
        cv2.createTrackbar("min_ball_radius_px", self.win, 1, 200, lambda v: self._cb_min_rad(v))
        cv2.createTrackbar("min_report_mph_x100", self.win, 0, 3000, lambda v: self._cb_min_mph(v))
        cv2.createTrackbar("target_width_px", self.win, 320, 3840, lambda v: self._cb_target_w(v))
        cv2.createTrackbar("show_mask", self.win, 0, 1, lambda v: self._cb_show_mask(v))

        # Position sliders to EXISTING values (no defaults)
        self._sync_from_settings(s)

        self.active = True

    def _sync_from_settings(self, s):
        # ROI
        try:
            cv2.setTrackbarPos("roi_startx", self.win, int(s["roi"]["startx"]))
            cv2.setTrackbarPos("roi_starty", self.win, int(s["roi"]["starty"]))
            cv2.setTrackbarPos("roi_endx",   self.win, int(s["roi"]["endx"]))
            cv2.setTrackbarPos("roi_endy",   self.win, int(s["roi"]["endy"]))
        except Exception:
            pass

        # Gate
        try:
            g = s.get("gate", {})
            L = g.get("line", {})
            cv2.setTrackbarPos("gate_x1", self.win, int(L.get("x1", 0)))
            cv2.setTrackbarPos("gate_y1", self.win, int(L.get("y1", self._h // 2)))
            cv2.setTrackbarPos("gate_x2", self.win, int(L.get("x2", self._w - 1)))
            cv2.setTrackbarPos("gate_y2", self.win, int(L.get("y2", self._h // 2)))
            cv2.setTrackbarPos("gate_enabled", self.win, 1 if g.get("enabled", True) else 0)
        except Exception:
            pass

        # Other settings
        try:
            cv2.setTrackbarPos("min_ball_radius_px", self.win, int(s.get("min_ball_radius_px", 3)))
        except Exception:
            pass

        try:
            mph_val = int(round(float(s.get("min_report_mph", 1.0)) * 100.0))
            cv2.setTrackbarPos("min_report_mph_x100", self.win, mph_val)
        except Exception:
            pass

        try:
            tw = int(s.get("target_width", 960))
            if tw < 320: tw = 320
            cv2.setTrackbarPos("target_width_px", self.win, tw)
        except Exception:
            pass

        try:
            cv2.setTrackbarPos("show_mask", self.win, 1 if s.get("show_mask", False) else 0)
        except Exception:
            pass

    def close(self):
        self.active = False
        try:
            cv2.destroyWindow(self.win)
        except Exception:
            pass

    def toggle(self, frame_width: int, frame_height: int):
        if self.active:
            self.close()
        else:
            self.open(frame_width, frame_height)
