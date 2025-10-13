import cv2

class Camera:
    def __init__(self, source=0, width=None, height=None):
        self.cap = cv2.VideoCapture(source)
        if width is not None:
            self.cap.set(cv2.CAP_PROP_FRAME_WIDTH, width)
        if height is not None:
            self.cap.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
        if not self.cap.isOpened():
            raise RuntimeError("Failed to open camera source.")

    def stream(self):
        while True:
            ret, frame = self.cap.read()
            if not ret:
                break
            yield frame
        self.cap.release()
