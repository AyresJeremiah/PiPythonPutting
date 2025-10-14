import cv2
from utils.runtime_cfg import get_cfg
import numpy as np
import settings as appsettings

def _clamp(v, lo, hi): return max(lo, min(int(v), hi))

class ColorPicker:
    """
    Slider-based picker:
      - open(w,h): shows a window with X/Y sliders bounded to frame size
      - render_overlay(frame): draws dot and instructions
      - commit(frame): samples HSV around (x,y) and saves ball_hsv.lower/upper
    """
    def __init__(self, main_window_name="PuttTracker", picker_window="PuttTracker Color Picker"):
        self.main_window = main_window_name
        self.name = picker_window
        self.active = False
        self._w = None
        self._h = None
        self._lock = False
        self._x = 0
        self._y = 0
        # HSV tolerances (can be expanded if needed)
        self.dH = 12
        self.dS = 60
        self.dV = 70
        self.last_hsv = None  # preview swatch while open

    def _sync_from_settings(self):
        # Try to initialize at ROI center if present
        s = get_cfg()
        roi = s.get("roi", {})
        try:
            x1,y1,x2,y2 = int(roi["startx"]),int(roi["starty"]),int(roi["endx"]),int(roi["endy"])
            cx = max(0, min((x1+x2)//2, self._w-1))
            cy = max(0, min((y1+y2)//2, self._h-1))
            self._x, self._y = cx, cy
        except Exception:
            self._x, self._y = self._w//2, self._h//2

    def _on_x(self, v):
        if self._lock: return
        self._x = _clamp(v, 0, self._w-1)

    def _on_y(self, v):
        if self._lock: return
        self._y = _clamp(v, 0, self._h-1)

    def open(self, frame_width, frame_height):
        self._w, self._h = int(frame_width), int(frame_height)
        self._sync_from_settings()
        cv2.namedWindow(self.name, cv2.WINDOW_NORMAL)
        cv2.resizeWindow(self.name, 360, 120)
        cv2.createTrackbar("x", self.name, int(self._x), self._w-1, lambda v: self._on_x(v))
        cv2.createTrackbar("y", self.name, int(self._y), self._h-1, lambda v: self._on_y(v))
        self.active = True

    def close(self):
        if self.active:
            try: cv2.destroyWindow(self.name)
            except Exception: pass
        self.active = False
        self.last_hsv = None

    def toggle(self, frame_width, frame_height):
        if self.active: self.close()
        else: self.open(frame_width, frame_height)

    def render_overlay(self, frame):
        # Dot + crosshair
        x, y = int(self._x), int(self._y)
        cv2.drawMarker(frame, (x,y), (0,255,255), markerType=cv2.MARKER_CROSS, markerSize=14, thickness=2)
        cv2.circle(frame, (x,y), 5, (0,255,255), 2)
        # Instruction + (optional) swatch preview if last_hsv exists
        text = "COLOR PICK: move sliders (x,y) over the BALL. Press 'b' to save."
        cv2.rectangle(frame, (8, 40), (8 + 12*len(text), 72), (0,0,0), -1)
        cv2.putText(frame, text, (16, 64), cv2.FONT_HERSHEY_SIMPLEX, 0.56, (255,255,255), 1, cv2.LINE_AA)
        if self.last_hsv is not None:
            H,S,V = self.last_hsv
            sw = 60; x0=16; y0=88
            hsv_img = np.uint8([[[H,S,V]]])
            bgr = cv2.cvtColor(hsv_img, cv2.COLOR_HSV2BGR)[0,0].tolist()
            cv2.rectangle(frame, (x0, y0), (x0+sw, y0+sw), (0,0,0), -1)
            cv2.rectangle(frame, (x0+2, y0+2), (x0+sw-2, y0+sw-2), bgr, -1)
            cv2.putText(frame, f"HSV: {H},{S},{V}", (x0+sw+10, y0+30), cv2.FONT_HERSHEY_SIMPLEX, 0.56, (255,255,255), 1, cv2.LINE_AA)
            cv2.putText(frame, "Saved (pending close)", (x0+sw+10, y0+52), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (180,255,180), 1, cv2.LINE_AA)

    def _sample_hsv(self, frame_bgr):
        x, y = int(self._x), int(self._y)
        h, w = frame_bgr.shape[:2]
        # sample 11x11 around the point (clamped)
        x1 = max(0, x-5); x2 = min(w-1, x+5)
        y1 = max(0, y-5); y2 = min(h-1, y+5)
        patch = frame_bgr[y1:y2+1, x1:x2+1]
        hsv = cv2.cvtColor(patch, cv2.COLOR_BGR2HSV)
        H,S,V = hsv.reshape(-1,3).mean(axis=0)
        return int(H), int(S), int(V)

    def commit(self, frame_bgr):
        """Sample at current (x,y) and save tolerant HSV to settings."""
        if frame_bgr is None: return
        H,S,V = self._sample_hsv(frame_bgr)
        self.last_hsv = (H,S,V)
        lower = [ _clamp(H - self.dH, 0, 180), _clamp(S - self.dS, 0, 255), _clamp(V - self.dV, 0, 255) ]
        upper = [ _clamp(H + self.dH, 0, 180), _clamp(S + self.dS, 0, 255), _clamp(V + self.dV, 0, 255) ]
        appsettings.set_value("ball_hsv.lower", lower)
        appsettings.set_value("ball_hsv.upper", upper)
        # Detector reads custom HSV automatically on next frame
