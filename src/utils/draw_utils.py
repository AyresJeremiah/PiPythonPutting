import cv2

def draw_ball(frame, center, radius):
    if center is None:
        return
    (x, y) = center
    cv2.circle(frame, (int(x), int(y)), int(max(2, radius)), (0, 255, 0), 2)
    cv2.circle(frame, (int(x), int(y)), 3, (0, 0, 255), -1)

def draw_vector(frame, p1, p2):
    if p1 is None or p2 is None:
        return
    (x1, y1) = map(int, p1)
    (x2, y2) = map(int, p2)
    cv2.arrowedLine(frame, (x1, y1), (x2, y2), (255, 0, 0), 2, tipLength=0.25)

def put_hud(frame, velocity=None, direction=None, fps=None, mph=None, yds=None):
    parts = []
    if velocity is not None:
        parts.append(f"vel: {velocity:.1f} px/s")
    if yds is not None:
        parts.append(f"{yds:.2f} yd/s")
    if mph is not None:
        parts.append(f"{mph:.1f} mph")
    if direction is not None:
        parts.append(f"dir: {direction:.1f}°")
    if fps is not None:
        parts.append(f"fps: {fps:.1f}")
    text = " | ".join(parts) if parts else ""
    if text:
        cv2.rectangle(frame, (8, 6), (8 + 12*len(text), 36), (0, 0, 0), -1)
        cv2.putText(frame, text, (12, 28), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (255,255,255), 1, cv2.LINE_AA)

def draw_roi(frame, roi, color=(0, 200, 255), thickness=2):
    x1, y1, x2, y2 = roi
    cv2.rectangle(frame, (x1, y1), (x2, y2), color, thickness)

def banner(frame, text, color=(0,0,255)):
    h = 32
    w = 10 + len(text) * 12
    cv2.rectangle(frame, (8, 40), (8 + w, 40 + h), (0,0,0), -1)
    cv2.putText(frame, text, (16, 64), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (255,255,255), 2, cv2.LINE_AA)

def help_box(frame, lines):
    width = max([len(s) for s in lines]) if lines else 0
    w = 20 + width * 8
    h = 24 + len(lines) * 18
    cv2.rectangle(frame, (8, 80), (8 + w, 80 + h), (0,0,0), -1)
    y = 100
    for s in lines:
        cv2.putText(frame, s, (16, y), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (255,255,255), 1, cv2.LINE_AA)
        y += 18

def draw_calibration_line(frame, line, color=(0,255,255)):
    x1,y1,x2,y2 = map(int, (line["x1"], line["y1"], line["x2"], line["y2"]))
    cv2.line(frame, (x1,y1), (x2,y2), color, 2)
    cv2.circle(frame, (x1,y1), 4, (0,0,0), -1)
    cv2.circle(frame, (x2,y2), 4, (0,0,0), -1)
    cv2.circle(frame, (x1,y1), 3, color, -1)
    cv2.circle(frame, (x2,y2), 3, color, -1)

def draw_status_dot(frame, status: str):
    h, w = frame.shape[:2]
    center = (w - 20, 20)
    color = {'red': (0,0,255), 'yellow': (0,255,255), 'green': (0,200,0)}.get(status, (200,200,200))
    cv2.circle(frame, center, 8, (0,0,0), -1)
    cv2.circle(frame, center, 7, color, -1)

# NEW: gate line
def draw_gate_line(frame, line, enabled=True):
    color = (0, 200, 0) if enabled else (160, 160, 160)
    x1,y1,x2,y2 = map(int, (line["x1"], line["y1"], line["x2"], line["y2"]))
    cv2.line(frame, (x1,y1), (x2,y2), color, 2)
    cv2.circle(frame, (x1,y1), 4, (0,0,0), -1)
    cv2.circle(frame, (x2,y2), 4, (0,0,0), -1)
    cv2.circle(frame, (x1,y1), 3, color, -1)
    cv2.circle(frame, (x2,y2), 3, color, -1)
