import cv2
import numpy as np
import settings as appsettings

def _clamp(v, lo, hi): return max(lo, min(int(v), hi))

class ColorPicker:
    def __init__(self, main_window_name="PuttTracker"):
        self.window = main_window_name
        self.active = False
        self.last_hsv = None
        self._w = None
        self._h = None
        self._picked = False
        # Tolerances around sampled HSV (tune if needed)
        self.dH = 12
        self.dS = 60
        self.dV = 70

    def _on_mouse(self, event, x, y, flags, param):
        if not self.active: return
        if event == cv2.EVENT_LBUTTONDOWN:
            # read small region around click
            frame_bgr = param  # current frame passed in setMouseCallback
            if frame_bgr is None: return
            h, w = frame_bgr.shape[:2]
            x1 = max(0, x-5); x2 = min(w-1, x+5)
            y1 = max(0, y-5); y2 = min(h-1, y+5)
            patch = frame_bgr[y1:y2+1, x1:x2+1]
            hsv = cv2.cvtColor(patch, cv2.COLOR_BGR2HSV)
            mean = hsv.reshape(-1,3).mean(axis=0)
            H,S,V = map(int, mean)
            self.last_hsv = (H,S,V)
            # Build tolerant lower/upper
            lower = [ _clamp(H - self.dH, 0, 180), _clamp(S - self.dS, 0, 255), _clamp(V - self.dV, 0, 255) ]
            upper = [ _clamp(H + self.dH, 0, 180), _clamp(S + self.dS, 0, 255), _clamp(V + self.dV, 0, 255) ]
            # Save to settings and flag picked
            appsettings.set_value("ball_hsv.lower", lower)
            appsettings.set_value("ball_hsv.upper", upper)
            # keep 'ball_color' as-is, but custom HSV overrides in detector
            self._picked = True

    def open(self, frame_width, frame_height, current_frame):
        self._w, self._h = frame_width, frame_height
        self.active = True
        # Pass current frame into mouse callback so we can sample from it
        cv2.setMouseCallback(self.window, lambda e,x,y,f, p=current_frame: self._on_mouse(e,x,y,f,p))

    def close(self):
        self.active = False
        self._picked = False
        self.last_hsv = None
        cv2.setMouseCallback(self.window, lambda *args: None)

    def toggle(self, frame_width, frame_height, current_frame):
        if self.active:
            self.close()
        else:
            self.open(frame_width, frame_height, current_frame)

    def picked(self):
        return self._picked

    def render_overlay(self, frame):
        # Show instructions and a color swatch of last_hsv if available
        h, w = frame.shape[:2]
        # Instruction banner
        text = "COLOR PICK MODE: click the BALL to sample color"
        cv2.rectangle(frame, (8, 40), (8 + 10 + len(text)*9, 72), (0,0,0), -1)
        cv2.putText(frame, text, (16, 64), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (255,255,255), 1, cv2.LINE_AA)
        if self.last_hsv is not None:
            H,S,V = self.last_hsv
            # swatch box
            sw = 60
            x0 = 16; y0 = 88
            hsv_img = np.uint8([[[H,S,V]]])
            bgr = cv2.cvtColor(hsv_img, cv2.COLOR_HSV2BGR)[0,0].tolist()
            cv2.rectangle(frame, (x0, y0), (x0+sw, y0+sw), (0,0,0), -1)
            cv2.rectangle(frame, (x0+2, y0+2), (x0+sw-2, y0+sw-2), bgr, -1)
            cv2.putText(frame, f"HSV: {H},{S},{V}", (x0+sw+10, y0+30), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (255,255,255), 1, cv2.LINE_AA)
            cv2.putText(frame, "Saved to settings", (x0+sw+10, y0+52), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (180,255,180), 1, cv2.LINE_AA)
