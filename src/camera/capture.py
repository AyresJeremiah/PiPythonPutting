import cv2

class Camera:
    """
    Unified capture for webcam or video file.
      - source=int -> camera index (0,1,…)
      - source=str -> path to video file
      - loop=True  -> restart file when it ends
    """
    def __init__(self, source=0, width=None, height=None, loop=False):
        self.source = source
        self.loop = loop
        if isinstance(source, str):
            self.cap = cv2.VideoCapture(source)
        else:
            self.cap = cv2.VideoCapture(int(source))
            if width is not None:
                self.cap.set(cv2.CAP_PROP_FRAME_WIDTH, width)
            if height is not None:
                self.cap.set(cv2.CAP_PROP_FRAME_HEIGHT, height)

        if not self.cap.isOpened():
            raise RuntimeError(f"Failed to open source: {source}")

    def _rewind_if_needed(self):
        if isinstance(self.source, str) and self.loop:
            self.cap.set(cv2.CAP_PROP_POS_FRAMES, 0)

    def stream(self):
        while True:
            ret, frame = self.cap.read()
            if not ret:
                if isinstance(self.source, str) and self.loop:
                    self._rewind_if_needed()
                    ret, frame = self.cap.read()
                    if not ret:
                        break
                else:
                    break
            yield frame
        self.cap.release()
