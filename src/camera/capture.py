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

    def negotiated(self):
        w = self._cap.get(cv2.CAP_PROP_FRAME_WIDTH)
        h = self._cap.get(cv2.CAP_PROP_FRAME_HEIGHT)
        f = self._cap.get(cv2.CAP_PROP_FPS)
        return int(w), int(h), float(f if f else 0.0)
