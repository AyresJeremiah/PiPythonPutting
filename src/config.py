BALL_COLOR = "white"
COLOR_RANGES = {
    "white": {"lower": (0, 0, 160), "upper": (180, 60, 255)},
    #"white": {"lower": (0, 0, 200), "upper": (180, 50, 255)},   # HSV range for white
    "yellow": {"lower": (20, 100, 100), "upper": (40, 255, 255)}
}

MIN_BALL_RADIUS_PX = 1      # ignore tiny specks
SHOW_MASK = False           # press 'm' in the app to toggle
TARGET_WIDTH = 960          # preview width; height keeps aspect
