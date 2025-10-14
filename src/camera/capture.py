import cv2
import threading
import time
from typing import Union, Optional


class Camera:
    """
    Unified capture for webcam or video file.

    - Live camera (int source): threaded reader for low-latency capture.
    - Video file (str source): sequential reads in stream() to avoid frame skipping.
    """

    def __init__(
        self,
        source: Union[int, str] = 0,
        width: Optional[int] = None,
        height: Optional[int] = None,
        loop: bool = False,
        request_mjpg60: bool = True
    ):
        self.source = source
        self.loop = bool(loop)

        self._cap = cv2.VideoCapture(source if isinstance(source, str) else int(source))
        if not self._cap.isOpened():
            raise RuntimeError(f"Failed to open source: {source}")

        # Configure live camera stream
        if not isinstance(source, str):
            # Hint the driver for lower latency
            try:
                self._cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)
            except Exception:
                pass

            if request_mjpg60:
                try:
                    self._cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"MJPG"))
                except Exception:
                    pass

            # Apply requested resolution if provided, otherwise try 1280x720
            if width is not None:
                self._cap.set(cv2.CAP_PROP_FRAME_WIDTH, int(width))
            else:
                self._cap.set(cv2.CAP_PROP_FRAME_WIDTH, 1280)
            if height is not None:
                self._cap.set(cv2.CAP_PROP_FRAME_HEIGHT, int(height))
            else:
                self._cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 720)

            # Ask for 60 FPS (camera/driver may negotiate differently)
            try:
                self._cap.set(cv2.CAP_PROP_FPS, 60)
            except Exception:
                pass

        # Thread only for live cams
        self._use_thread = not isinstance(source, str)
        self._frame = None
        self._lock = threading.Lock()
        self._stop = False

        if self._use_thread:
            self._reader = threading.Thread(target=self._reader_loop, daemon=True)
            self._reader.start()

    # ---------------- internal reader (live camera only) ----------------
    def _reader_loop(self):
        """Continuously read frames into a single-slot buffer."""
        while not self._stop:
            ret, frame = self._cap.read()
            if not ret:
                time.sleep(0.002)
                ret, frame = self._cap.read()
                if not ret:
                    break
            with self._lock:
                self._frame = frame

        try:
            self._cap.release()
        except Exception:
            pass

    # ---------------- public API ----------------
    def stream(self):
        """
        Generator yielding frames.

        - Video file: sequential reads (no skipping). Loops if self.loop.
        - Live camera: yields the latest frame from the thread buffer.
        """
        if not self._use_thread:
            # Sequential read path for video files
            while not self._stop:
                ret, frame = self._cap.read()
                if not ret:
                    if isinstance(self.source, str) and self.loop:
                        self._cap.set(cv2.CAP_PROP_POS_FRAMES, 0)
                        continue
                    break
                yield frame
            # release on exit
            try:
                self._cap.release()
            except Exception:
                pass
            return

        # Live camera path (threaded)
        while not self._stop and self._frame is None:
            time.sleep(0.001)

        while not self._stop:
            with self._lock:
                frame = None if self._frame is None else self._frame.copy()
            if frame is not None:
                yield frame
            else:
                time.sleep(0.001)

    def read_once(self):
        """Return the latest frame (copy) or None if not ready yet."""
        if not self._use_thread:
            ret, frame = self._cap.read()
            return frame if ret else None
        with self._lock:
            return None if self._frame is None else self._frame.copy()

    def close(self):
        """Stop and release."""
        self._stop = True
        time.sleep(0.01)
        try:
            self._cap.release()
        except Exception:
            pass

    def __del__(self):
        try:
            self.close()
        except Exception:
            pass

    # --------------- debugging helpers ---------------
    def negotiated(self):
        """Return (width, height, fps) reported by the backend."""
        w = self._cap.get(cv2.CAP_PROP_FRAME_WIDTH)
        h = self._cap.get(cv2.CAP_PROP_FRAME_HEIGHT)
        f = self._cap.get(cv2.CAP_PROP_FPS)
        return int(w), int(h), float(f if f else 0.0)
