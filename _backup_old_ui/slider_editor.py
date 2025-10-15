import cv2
from utils.runtime_cfg import get_cfg
import settings as appsettings

class SliderEditor:
    """
    Settings window with live sliders. Processing is paused while this is open.

    Fixes:
      - Uses CURRENT settings as initial values (no defaults) on open
      - Guards callbacks during construction/sync so no accidental resets
    """
    def __init__(self, window_name: str = "PuttTracker Settings"):
        self.win = window_name
        self.active = False
        self._w = None
        self._h = None
        self._suspend = False  # guard: block writes while building/syncing

    # ---------- helpers ----------
    def _set(self, path, value):
        if not self._suspend:
            appsettings.set_value(path, value)

    def _clamp_xy(self, x, y, w, h):
        x = max(0, min(int(x), w - 1))
        y = max(0, min(int(y), h - 1))
        return x, y

    # ---------- callbacks (write only when not suspended) ----------
    # Stage ROI
    def _cb_st_x1(self, v): self._set("zones.stage_roi.x1", int(v))
    def _cb_st_y1(self, v): self._set("zones.stage_roi.y1", int(v))
    def _cb_st_x2(self, v): self._set("zones.stage_roi.x2", int(v))
    def _cb_st_y2(self, v): self._set("zones.stage_roi.y2", int(v))
    # Track ROI
    def _cb_tr_x1(self, v): self._set("zones.track_roi.x1", int(v))
    def _cb_tr_y1(self, v): self._set("zones.track_roi.y1", int(v))
    def _cb_tr_x2(self, v): self._set("zones.track_roi.x2", int(v))
    def _cb_tr_y2(self, v): self._set("zones.track_roi.y2", int(v))
    # Other
    def _cb_min_rad(self, v): self._set("min_ball_radius_px", int(v))
    def _cb_show_mask(self, v): self._set("show_mask", bool(v))
    def _cb_min_mph(self, v): self._set("min_report_mph", float(v) / 100.0)
    def _cb_target_w(self, v):
        v = 320 if int(v) < 320 else int(v)
        self._set("target_width", v)

    # ---------- build ----------
    def open(self, frame_width: int, frame_height: int):
        """Open window with sliders positioned to CURRENT settings."""
        self._w, self._h = int(frame_width), int(frame_height)
        s = get_cfg()

        # Clamp current settings to frame so initial positions are valid
        st = s["zones"]["stage_roi"].copy()
        tr = s["zones"]["track_roi"].copy()
        st["x1"], st["y1"] = self._clamp_xy(st["x1"], st["y1"], self._w, self._h)
        st["x2"], st["y2"] = self._clamp_xy(st["x2"], st["y2"], self._w, self._h)
        tr["x1"], tr["y1"] = self._clamp_xy(tr["x1"], tr["y1"], self._w, self._h)
        tr["x2"], tr["y2"] = self._clamp_xy(tr["x2"], tr["y2"], self._w, self._h)

        min_rad  = int(s.get("min_ball_radius_px", 3))
        min_mphX = int(round(float(s.get("min_report_mph", 1.0)) * 100.0))
        targ_w   = max(320, int(s.get("target_width", 960)))
        show_m   = 1 if s.get("show_mask", False) else 0

        # Build UI with guard up: prevents callbacks from writing defaults
        self._suspend = True
        try:
            cv2.namedWindow(self.win, cv2.WINDOW_NORMAL)
            cv2.resizeWindow(self.win, 480, 640)

            # Stage ROI sliders (init to CURRENT values)
            cv2.createTrackbar("stage_x1", self.win, int(st["x1"]), max(1, self._w - 1), lambda v: self._cb_st_x1(v))
            cv2.createTrackbar("stage_y1", self.win, int(st["y1"]), max(1, self._h - 1), lambda v: self._cb_st_y1(v))
            cv2.createTrackbar("stage_x2", self.win, int(st["x2"]), max(1, self._w),     lambda v: self._cb_st_x2(v))
            cv2.createTrackbar("stage_y2", self.win, int(st["y2"]), max(1, self._h),     lambda v: self._cb_st_y2(v))

            # Track ROI sliders
            cv2.createTrackbar("track_x1", self.win, int(tr["x1"]), max(1, self._w - 1), lambda v: self._cb_tr_x1(v))
            cv2.createTrackbar("track_y1", self.win, int(tr["y1"]), max(1, self._h - 1), lambda v: self._cb_tr_y1(v))
            cv2.createTrackbar("track_x2", self.win, int(tr["x2"]), max(1, self._w),     lambda v: self._cb_tr_x2(v))
            cv2.createTrackbar("track_y2", self.win, int(tr["y2"]), max(1, self._h),     lambda v: self._cb_tr_y2(v))

            # Other sliders
            cv2.createTrackbar("min_ball_radius_px",  self.win, min_rad, 200, lambda v: self._cb_min_rad(v))
            cv2.createTrackbar("min_report_mph_x100", self.win, min_mphX, 3000, lambda v: self._cb_min_mph(v))
            cv2.createTrackbar("target_width_px",     self.win, targ_w, 3840, lambda v: self._cb_target_w(v))
            cv2.createTrackbar("show_mask",           self.win, show_m, 1,    lambda v: self._cb_show_mask(v))

            # (No need to set positions again; we already initialized them to CURRENT values)
        finally:
            # Drop the guard so user changes start writing
            self._suspend = False

        self.active = True

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
