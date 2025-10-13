import cv2

def draw_ball(frame, center, radius):
    if center is None:
        return
    (x, y) = center
    cv2.circle(frame, (int(x), int(y)), int(radius), (0, 255, 0), 2)
    cv2.circle(frame, (int(x), int(y)), 3, (0, 0, 255), -1)

def draw_vector(frame, p1, p2):
    if p1 is None or p2 is None:
        return
    (x1, y1) = map(int, p1)
    (x2, y2) = map(int, p2)
    cv2.arrowedLine(frame, (x1, y1), (x2, y2), (255, 0, 0), 2, tipLength=0.25)

def put_hud(frame, velocity, direction, fps):
    h = 22
    y = 28
    text = []
    if velocity is not None:
        text.append(f"vel: {velocity:.1f} px/s")
    if direction is not None:
        text.append(f"dir: {direction:.1f}°")
    if fps is not None:
        text.append(f"fps: {fps:.1f}")
    if not text:
        return
    cv2.rectangle(frame, (8, 6), (8 + 250, 6 + h + 10), (0, 0, 0), -1)
    cv2.putText(frame, " | ".join(text), (12, 24), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (255,255,255), 1, cv2.LINE_AA)
