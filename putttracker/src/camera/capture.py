import cv2

class Camera:
    def __init__(self, source=0):
        self.cap = cv2.VideoCapture(source)
        if not self.cap.isOpened():
            raise RuntimeError("Failed to open camera source.")

    def stream(self):
        while True:
            ret, frame = self.cap.read()
            if not ret:
                break
            yield frame
        self.cap.release()
