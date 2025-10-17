import cv2
import threading
import time
from typing import Union, Optional

class Camera:
    """
    Live camera (int): threaded reader; supports pause()/resume().
    Video file (str): sequential reads in stream() to avoid skipping; pausing = stop consuming frames.
    """

    def __init__(self, source: Union[int,str]=0, width:Optional[int]=None, height:Optional[int]=None, loop:bool=False, request_mjpg60:bool=True):
        self.source = source
        self.loop = bool(loop)
        self._cap = cv2.VideoCapture(source if isinstance(source, str) else int(source))
        if not self._cap.isOpened():
            raise RuntimeError(f"Failed to open source: {source}")

        # Configure live cameras
        if not isinstance(source, str):
            try: self._cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)
            except Exception: pass
            if request_mjpg60:
                try: self._cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"MJPG"))
                except Exception: pass
            self._cap.set(cv2.CAP_PROP_FRAME_WIDTH,  int(width) if width else 1280)
            self._cap.set(cv2.CAP_PROP_FRAME_HEIGHT, int(height) if height else 720)
            try: self._cap.set(cv2.CAP_PROP_FPS, 60)
            except Exception: pass

        # Modes
        self._use_thread = not isinstance(source, str)  # thread only for live cams
        self._paused = False
        self._stop = False
        self._frame = None
        self._lock = threading.Lock()

        if self._use_thread:
            self._reader = threading.Thread(target=self._reader_loop, daemon=True)
            self._reader.start()

    def _reader_loop(self):
        """Live camera reader."""
        while not self._stop:
            if self._paused:
                time.sleep(0.01)
                continue
            ret, frame = self._cap.read()
            if not ret:
                time.sleep(0.002)
                continue
            with self._lock:
                self._frame = frame
        try: self._cap.release()
        except Exception: pass

    def stream(self):
        """
        Frames generator.
        - Video file: read sequentially (no skipping). If paused, we yield last frame (handled by main).
        - Live camera: yield latest from thread buffer; when paused, main doesn't consume & reader sleeps.
        """
        if not self._use_thread:
            # sequential video-file path
            while not self._stop:
                ret, frame = self._cap.read()
                if not ret:
                    if isinstance(self.source, str) and self.loop:
                        self._cap.set(cv2.CAP_PROP_POS_FRAMES, 0); continue
                    break
                yield frame
            try: self._cap.release()
            except Exception: pass
            return

        # live camera path
        while not self._stop and self._frame is None:
            time.sleep(0.001)
        while not self._stop:
            with self._lock:
                f = None if self._frame is None else self._frame.copy()
            if f is not None:
                yield f
            else:
                time.sleep(0.001)

    def read_once(self):
        if not self._use_thread:
            ret, frame = self._cap.read()
            return frame if ret else None
        with self._lock:
            return None if self._frame is None else self._frame.copy()

    def pause(self):  self._paused = True
    def resume(self): self._paused = False

    def close(self):
        self._stop = True
        time.sleep(0.01)
        try: self._cap.release()
        except Exception: pass

    def __del__(self):
        try: self.close()
        except Exception: pass


    # -------- camera controls (V4L2/OpenCV) --------
    def apply_controls(self, cam_cfg: dict):
        """
        Apply V4L2-style controls using OpenCV properties.

        cam_cfg example:
          {
            "brightness": 128,   # 0-255
            "contrast":   128,   # 0-255
            "saturation": 128,   # 0-255
            "sharpness":  128,   # 0-255 (may map to GAMMA)
            "gain":       0,     # 0-255 (driver-specific)
            "exposure_auto": 1,  # 1=auto, 0=manual (mapping varies)
            "exposure":    200,  # manual exposure (backend units)
            "wb_auto":     1,    # 1=auto WB, 0=manual
            "wb_temp":     4500  # 2000-8000 (often only when wb_auto=0)
          }
        """
        if not hasattr(self, "_cap") or self._cap is None:
            return

        cap = self._cap

        def _set(prop, val):
            try:
                cap.set(prop, float(val))
            except Exception:
                pass

        import cv2

        # Core controls
        if "brightness" in cam_cfg:
            _set(cv2.CAP_PROP_BRIGHTNESS, cam_cfg.get("brightness"))
        if "contrast" in cam_cfg:
            _set(cv2.CAP_PROP_CONTRAST,   cam_cfg.get("contrast"))
        if "saturation" in cam_cfg:
            _set(cv2.CAP_PROP_SATURATION, cam_cfg.get("saturation"))

        # Sharpness (or GAMMA as fallback)
        if "sharpness" in cam_cfg:
            if hasattr(cv2, "CAP_PROP_SHARPNESS"):
                _set(cv2.CAP_PROP_SHARPNESS, cam_cfg.get("sharpness"))
            elif hasattr(cv2, "CAP_PROP_GAMMA"):
                _set(cv2.CAP_PROP_GAMMA, cam_cfg.get("sharpness"))

        # Exposure auto/manual (OpenCV often maps 0.25 manual / 0.75 auto)
        if "exposure_auto" in cam_cfg and hasattr(cv2, "CAP_PROP_AUTO_EXPOSURE"):
            use_auto = 1 if cam_cfg.get("exposure_auto") else 0
            _set(cv2.CAP_PROP_AUTO_EXPOSURE, 0.75 if use_auto else 0.25)

        if "exposure" in cam_cfg and hasattr(cv2, "CAP_PROP_EXPOSURE"):
            _set(cv2.CAP_PROP_EXPOSURE, cam_cfg.get("exposure"))

        if "gain" in cam_cfg and hasattr(cv2, "CAP_PROP_GAIN"):
            _set(cv2.CAP_PROP_GAIN, cam_cfg.get("gain"))

        # White balance
        if "wb_auto" in cam_cfg and hasattr(cv2, "CAP_PROP_AUTO_WB"):
            _set(cv2.CAP_PROP_AUTO_WB, 1 if cam_cfg.get("wb_auto") else 0)

        if "wb_temp" in cam_cfg and hasattr(cv2, "CAP_PROP_WB_TEMPERATURE"):
            _set(cv2.CAP_PROP_WB_TEMPERATURE, cam_cfg.get("wb_temp"))
    def negotiated(self):
        w = self._cap.get(cv2.CAP_PROP_FRAME_WIDTH)
        h = self._cap.get(cv2.CAP_PROP_FRAME_HEIGHT)
        f = self._cap.get(cv2.CAP_PROP_FPS)
        return int(w), int(h), float(f if f else 0.0)


class PiCam2Camera:
    """Picamera2 capture feeding numpy frames to OpenCV pipeline."""
    def __init__(self, width=1332, height=990, fps=120, shutter_us=None, gain=None, denoise="off"):
        from picamera2 import Picamera2
        try:
            from libcamera import controls, Transform  # noqa: F401

        except Exception:
            pass
        import threading, time

        self.picam2 = Picamera2()
        cfg = self.picam2.create_video_configuration(
            main={"size": (int(width), int(height)), "format": "RGB888"},
            transform=Transform(hflip=True, vflip=True)  # TODO MAKE CONFIGURABLE
        )
        self.picam2.configure(cfg)

        # FrameDurationLimits = 1e6/fps (microseconds). If fps is falsy, skip.
        if fps:
            try:
                self.picam2.set_controls({"FrameDurationLimits": (int(1e6//fps), int(1e6//fps))})
            except Exception:
                pass

        if shutter_us:
            try: self.picam2.set_controls({"ExposureTime": int(shutter_us)})
            except Exception: pass

        if gain:
            try: self.picam2.set_controls({"AnalogueGain": float(gain)})
            except Exception: pass

        from libcamera import controls
        # Map friendly strings -> libcamera enums
        NR_MAP = {
            "off": controls.draft.NoiseReductionModeEnum.Off,
            "minimal": controls.draft.NoiseReductionModeEnum.Minimal,
            "fast": controls.draft.NoiseReductionModeEnum.Fast,
            "hq": controls.draft.NoiseReductionModeEnum.HighQuality,
            "high_quality": controls.draft.NoiseReductionModeEnum.HighQuality,
        }
        if denoise is not None:
            mode = NR_MAP.get(str(denoise).lower(), controls.draft.NoiseReductionModeEnum.Off)
            self.picam2.set_controls({"NoiseReductionMode": mode})

        self.picam2.start()

        # Get full sensor size
        full_w, full_h = self.picam2.sensor_resolution

        # Calculate a centered 2× zoom crop (half width & height)
        x = full_w // 4
        y = full_h // 4
        w = full_w // 2
        h = full_h // 2

        # Apply digital zoom
        #self.picam2.set_controls({"ScalerCrop": (x, y, w, h)})


        self._frame = None
        self._lock = threading.Lock()
        self._stop = False

        def _reader():
            while not self._stop:
                arr = self.picam2.capture_array()  # RGB888 numpy
                with self._lock:
                    self._frame = arr
            try:
                self.picam2.stop()
            except Exception:
                pass

        self._t = threading.Thread(target=_reader, daemon=True)
        self._t.start()

    def stream(self):
        import time
        while not self._stop and self._frame is None:
            time.sleep(0.001)
        while not self._stop:
            with self._lock:
                f = None if self._frame is None else self._frame.copy()
            if f is not None:
                yield f
            else:
                time.sleep(0.001)

    def read_once(self):
        with self._lock:
            return None if self._frame is None else self._frame.copy()

    def pause(self):
        self._stop = True

    def resume(self):
        if self._stop:
            self._stop = False

    def close(self):
        self._stop = True
        try:
            self.picam2.stop()
        except Exception:
            pass

    def negotiated(self):
        try:
            s = self.picam2.stream_configuration("main")["size"]
            return int(s[0]), int(s[1]), 0.0
        except Exception:
            return 0,0,0.0
