import cv2
import threading
import time
import sys

class PreviewUI:
    """
    Cross-platform preview:
      - macOS: runs UI on the MAIN thread (must call poll() each loop).
      - others: runs a background thread that owns the window.

    API:
      ui = PreviewUI(title="PuttTracker", target_width=960, wait_ms=1)
      ui.start()         # no-op on macOS
      ui.show(frame)     # set latest frame (thread-safe)
      key = ui.poll()    # MUST be called regularly on macOS; safe on others too
      ui.stop()
    """
    def __init__(self, title="PuttTracker", target_width=960, wait_ms=1):
        self.title = title
        self.target_width = int(target_width)
        self.wait_ms = int(wait_ms)
        self._latest = None
        self._lock = threading.Lock()
        self._stop = False
        self._last_key = -1
        self._window_ready = False

        # macOS must render on main thread
        self._main_thread_mode = (sys.platform == "darwin")
        if not self._main_thread_mode:
            self._thread = threading.Thread(target=self._loop, daemon=True)
        else:
            self._thread = None

    def start(self):
        if self._thread and not self._thread.is_alive():
            self._thread.start()

    def stop(self):
        self._stop = True
        time.sleep(0.01)
        if not self._main_thread_mode:
            try:
                cv2.destroyWindow(self.title)
            except Exception:
                pass

    def set_target_width(self, w: int):
        self.target_width = int(w)

    def set_wait_ms(self, ms: int):
        self.wait_ms = int(ms)

    def show(self, frame):
        if frame is None:
            return
        with self._lock:
            self._latest = frame

    def get_key(self):
        """(threaded mode only) return last pressed key and clear it; -1 if none."""
        key = self._last_key
        self._last_key = -1
        return key

    def poll(self):
        """
        Cross-platform UI pump:
          - macOS: create window, imshow, waitKey here (on main thread) and return key
          - others: just fetch and clear last_key (thread does imshow/waitKey)
        """
        if self._main_thread_mode:
            # lazy create
            if not self._window_ready:
                cv2.namedWindow(self.title, cv2.WINDOW_NORMAL)
                self._window_ready = True

            with self._lock:
                frame = None if self._latest is None else self._latest.copy()

            if frame is not None:
                preview = self._resize_keep_aspect(frame, self.target_width)
                cv2.imshow(self.title, preview)

            key = cv2.waitKey(self.wait_ms) & 0xFF
            return key if key != 255 else -1
        else:
            # threaded mode: UI thread already ran waitKey
            return self.get_key()

    # --------------- internal (threaded mode) ---------------
    def _loop(self):
        # Own window in background thread (not for macOS)
        cv2.namedWindow(self.title, cv2.WINDOW_NORMAL)
        self._window_ready = True
        while not self._stop:
            with self._lock:
                frame = None if self._latest is None else self._latest.copy()
            if frame is not None:
                preview = self._resize_keep_aspect(frame, self.target_width)
                cv2.imshow(self.title, preview)
            key = cv2.waitKey(self.wait_ms) & 0xFF
            if key != 255:
                self._last_key = key

        try:
            cv2.destroyWindow(self.title)
        except Exception:
            pass

    def _resize_keep_aspect(self, frame, target_w):
        h, w = frame.shape[:2]
        if w <= 0 or h <= 0:
            return frame
        scale = target_w / float(w)
        return cv2.resize(frame, (int(w * scale), int(h * scale)))
