import cv2
import settings as appsettings

class SliderEditor:
    def __init__(self, window_name="PuttTracker Settings"):
        self.name = window_name
        self.active = False
        self._w = None
        self._h = None
        self._lock = False  # avoid callback recursion

    def _safe_set(self, keypath, value):
        if self._lock:
            return
        self._lock = True
        appsettings.set_value(keypath, value)
        appsettings.save()
        self._lock = False

    def _sync_bounds(self):
        # Keep ROI valid: start < end, within frame
        appsettings.clamp_roi(self._w, self._h)

        s = appsettings.load()
        r = s["roi"]
        cv2.setTrackbarPos("startx", self.name, r["startx"])
        cv2.setTrackbarPos("endx",   self.name, r["endx"])
        cv2.setTrackbarPos("starty", self.name, r["starty"])
        cv2.setTrackbarPos("endy",   self.name, r["endy"])
        cv2.setTrackbarPos("min_radius", self.name, int(s.get("min_ball_radius_px", 3)))
        cv2.setTrackbarPos("mask",       self.name, 1 if s.get("show_mask", False) else 0)
        cv2.setTrackbarPos("preview_w",  self.name, int(s.get("target_width", 960)))

    def _on_startx(self, v):
        self._safe_set("roi.startx", v); appsettings.clamp_roi(self._w, self._h)
    def _on_endx(self, v):
        self._safe_set("roi.endx", v); appsettings.clamp_roi(self._w, self._h)
    def _on_starty(self, v):
        self._safe_set("roi.starty", v); appsettings.clamp_roi(self._w, self._h)
    def _on_endy(self, v):
        self._safe_set("roi.endy", v); appsettings.clamp_roi(self._w, self._h)
    def _on_minr(self, v):
        self._safe_set("min_ball_radius_px", max(0, v))
    def _on_mask(self, v):
        self._safe_set("show_mask", bool(v))
    def _on_previeww(self, v):
        self._safe_set("target_width", max(320, v))

    def open(self, frame_width, frame_height):
        self._w, self._h = int(frame_width), int(frame_height)
        appsettings.ensure_roi_initialized(self._w, self._h)
        appsettings.clamp_roi(self._w, self._h)

        cv2.namedWindow(self.name, cv2.WINDOW_NORMAL)
        cv2.resizeWindow(self.name, 420, 260)

        # Trackbars
        cv2.createTrackbar("startx",   self.name, 0, self._w-1, lambda v: self._on_startx(v))
        cv2.createTrackbar("endx",     self.name, 1, self._w,   lambda v: self._on_endx(v))
        cv2.createTrackbar("starty",   self.name, 0, self._h-1, lambda v: self._on_starty(v))
        cv2.createTrackbar("endy",     self.name, 1, self._h,   lambda v: self._on_endy(v))
        cv2.createTrackbar("min_radius", self.name, 3, 50,      lambda v: self._on_minr(v))
        cv2.createTrackbar("mask",       self.name, 0, 1,       lambda v: self._on_mask(v))
        cv2.createTrackbar("preview_w",  self.name, 960, 1920,  lambda v: self._on_previeww(v))

        self._sync_bounds()
        self.active = True

    def close(self):
        if self.active:
            try:
                cv2.destroyWindow(self.name)
            except Exception:
                pass
        self.active = False

    def toggle(self, frame_width, frame_height):
        if self.active:
            self.close()
        else:
            self.open(frame_width, frame_height)
