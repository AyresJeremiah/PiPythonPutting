from tracking.ball_detector import BallDetector
from tracking.motion_tracker import MotionTracker
from camera.capture import Camera
from utils.logger import log

def main():
    camera = Camera(source=0)
    detector = BallDetector()
    tracker = MotionTracker()

    log("Starting ball tracking...")
    for frame in camera.stream():
        ball_position = detector.detect(frame)
        velocity, direction = tracker.update(ball_position)
        if velocity is not None:
            log(f"Velocity: {velocity:.2f} px/s, Direction: {direction:.2f}°")

if __name__ == "__main__":
    main()
