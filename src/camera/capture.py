# src/camera/capture.py
import cv2
import threading
import time
from typing import Union, Optional


class Camera:
    """
    Unified capture for webcam or video file with a threaded frame reader.

    Usage:
        cam = Camera(source=0)                             # live camera
        cam = Camera(source="testdata/clip.mp4", loop=True)  # video file (loops)

        for frame in cam.stream():
            ...

    Notes:
      - For integer sources (webcams), we request MJPG @ 1280x720 @ 60 FPS.
        Many cams only deliver 60 FPS if MJPG is requested.
      - For file sources (strings), 'loop=True' restarts at EOF.
      - 'stream()' yields the latest frame copy from a background reader thread.
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

        # Internal state for threaded reading
        self._frame = None
        self._lock = threading.Lock()
        self._stop = False
        self._reader = threading.Thread(target=self._reader_loop, daemon=True)
        self._reader.start()

    # ---------------- internal reader ----------------
    def _reader_loop(self):
        """Continuously read frames into a single-slot buffer."""
        while not self._stop:
            ret, frame = self._cap.read()
            if not ret:
                # Handle EOF for file sources
                if isinstance(self.source, str) and self.loop:
                    # rewind and try again
                    self._cap.set(cv2.CAP_PROP_POS_FRAMES, 0)
                    continue
                # Give the producer a tiny break, then try again; if still failing, stop
                time.sleep(0.002)
                # One more attempt
                ret, frame = self._cap.read()
                if not ret:
                    break

            with self._lock:
                self._frame = frame

        # We’re exiting the reader loop; release on the way out
        try:
            self._cap.release()
        except Exception:
            pass

    # ---------------- public API ----------------
    def stream(self):
        """
        Generator yielding the latest available frame (as a copy).
        Will block briefly until the first frame arrives.
        """
        # Wait for first frame
        while not self._stop and self._frame is None:
            time.sleep(0.001)

        while not self._stop:
            with self._lock:
                frame = None if self._frame is None else self._frame.copy()
            if frame is not None:
                yield frame
            else:
                # No frame available right now – tiny sleep to avoid busy-wait
                time.sleep(0.001)

    def read_once(self):
        """Return the latest frame (copy) or None if not ready yet."""
        with self._lock:
            return None if self._frame is None else self._frame.copy()

    def close(self):
        """Stop the reader thread and release resources."""
        self._stop = True
        # Nudge the reader loop to exit quickly
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
