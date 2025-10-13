# PuttTracker

A lightweight Raspberry Pi project for detecting and tracking the motion of a golf ball during putting.

## Setup

\`\`\`bash
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
\`\`\`

Run it with:

\`\`\`bash
python3 src/main.py
\`\`\`

## Features
- Ball detection using OpenCV (white ball by default)
- Computes velocity and direction
- Lightweight and Pi 4 compatible
