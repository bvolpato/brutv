#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "pillow>=10.0.0",
# ]
# ///
"""
Generate concept mockups by compositing iPad captures into drawn Mac chrome.
These images are not native Catalyst captures or App Store screenshot evidence.
"""

import os
from PIL import Image, ImageDraw, ImageFilter, ImageFont

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
SCREENSHOTS_DIR = os.path.join(SCRIPT_DIR, "screenshots")
IPAD_DIR = os.path.join(SCREENSHOTS_DIR, "ipad-13-inch")
MOCKUP_DIR = os.path.join(SCRIPT_DIR, "build", "mockups", "mac-2880x1800")

CANVAS_WIDTH = 2880
CANVAS_HEIGHT = 1800

WINDOW_WIDTH = 2580
WINDOW_HEIGHT = 1620
CORNER_RADIUS = 28
TITLEBAR_HEIGHT = 68

def create_mac_mockup(source_path: str, output_path: str, title: str = "BruTV"):
    # 1. Create 2880x1800 backdrop with subtle dark studio gradient
    backdrop = Image.new("RGBA", (CANVAS_WIDTH, CANVAS_HEIGHT), (10, 13, 20, 255))
    draw = ImageDraw.Draw(backdrop)

    # Subtle radial glow behind the center window
    glow = Image.new("RGBA", (CANVAS_WIDTH, CANVAS_HEIGHT), (0, 0, 0, 0))
    glow_draw = ImageDraw.Draw(glow)
    center_x, center_y = CANVAS_WIDTH // 2, CANVAS_HEIGHT // 2
    for r in range(800, 0, -20):
        alpha = int(28 * (1.0 - r / 800.0))
        glow_draw.ellipse(
            (center_x - r * 1.5, center_y - r, center_x + r * 1.5, center_y + r),
            fill=(0, 160, 220, alpha)
        )
    backdrop = Image.alpha_composite(backdrop, glow)

    # 2. Window Position
    win_x = (CANVAS_WIDTH - WINDOW_WIDTH) // 2
    win_y = (CANVAS_HEIGHT - WINDOW_HEIGHT) // 2

    # 3. Drop Shadow
    shadow_offset_y = 24
    shadow_padding = 80
    shadow_box = (
        win_x - shadow_padding,
        win_y - shadow_padding + shadow_offset_y,
        win_x + WINDOW_WIDTH + shadow_padding,
        win_y + WINDOW_HEIGHT + shadow_padding + shadow_offset_y
    )
    shadow_img = Image.new("RGBA", (CANVAS_WIDTH, CANVAS_HEIGHT), (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow_img)
    shadow_draw.rounded_rectangle(
        (win_x, win_y + shadow_offset_y, win_x + WINDOW_WIDTH, win_y + WINDOW_HEIGHT + shadow_offset_y),
        radius=CORNER_RADIUS + 4,
        fill=(0, 0, 0, 140)
    )
    shadow_img = shadow_img.filter(ImageFilter.GaussianBlur(radius=36))
    backdrop = Image.alpha_composite(backdrop, shadow_img)

    # 4. Construct Window Frame
    win_img = Image.new("RGBA", (WINDOW_WIDTH, WINDOW_HEIGHT), (0, 0, 0, 0))
    win_draw = ImageDraw.Draw(win_img)

    # Window background & border
    win_draw.rounded_rectangle(
        (0, 0, WINDOW_WIDTH, WINDOW_HEIGHT),
        radius=CORNER_RADIUS,
        fill=(18, 22, 30, 255),
        outline=(50, 58, 72, 255),
        width=2
    )

    # Title Bar
    titlebar_mask = Image.new("L", (WINDOW_WIDTH, TITLEBAR_HEIGHT), 0)
    titlebar_mask_draw = ImageDraw.Draw(titlebar_mask)
    titlebar_mask_draw.rounded_rectangle(
        (0, 0, WINDOW_WIDTH, TITLEBAR_HEIGHT * 2),
        radius=CORNER_RADIUS,
        fill=255
    )
    titlebar = Image.new("RGBA", (WINDOW_WIDTH, TITLEBAR_HEIGHT), (26, 31, 42, 255))
    win_img.paste(titlebar, (0, 0), titlebar_mask)

    # Titlebar divider line
    win_draw.line(
        [(0, TITLEBAR_HEIGHT), (WINDOW_WIDTH, TITLEBAR_HEIGHT)],
        fill=(42, 48, 62, 255),
        width=1
    )

    # Traffic light buttons
    btn_y = TITLEBAR_HEIGHT // 2
    btn_r = 10
    buttons = [
        (36, btn_y, (255, 95, 87)),   # Close (Red)
        (66, btn_y, (254, 188, 46)),  # Minimize (Yellow)
        (96, btn_y, (40, 200, 64))    # Zoom (Green)
    ]
    for bx, by, color in buttons:
        win_draw.ellipse(
            (bx - btn_r, by - btn_r, bx + btn_r, by + btn_r),
            fill=color,
            outline=(color[0] // 2, color[1] // 2, color[2] // 2, 180),
            width=1
        )

    # Window Title
    try:
        font = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 22)
    except Exception:
        font = ImageFont.load_default()
    bbox = win_draw.textbbox((0, 0), title, font=font)
    tw = bbox[2] - bbox[0]
    th = bbox[3] - bbox[1]
    win_draw.text(
        ((WINDOW_WIDTH - tw) // 2, (TITLEBAR_HEIGHT - th) // 2 - 2),
        title,
        fill=(220, 226, 235, 230),
        font=font
    )

    # 5. Content Area
    content_width = WINDOW_WIDTH - 4
    content_height = WINDOW_HEIGHT - TITLEBAR_HEIGHT - 2

    if os.path.exists(source_path):
        src = Image.open(source_path).convert("RGBA")
        src_w, src_h = src.size

        fname = os.path.basename(source_path)
        content = Image.new("RGBA", (content_width, content_height), (11, 14, 20, 255))
        target_crop_h = int(src_w * content_height / content_width) # 1241 for 2064

        if fname == "01_login.png":
            # Center around login box
            y_start = 220
            cropped = src.crop((0, y_start, src_w, y_start + target_crop_h))
            content = cropped.resize((content_width, content_height), Image.Resampling.LANCZOS)

        elif fname == "02_channels.png":
            # Skip iPad status bar, show categories sidebar and channel grid
            y_start = 60
            cropped = src.crop((0, y_start, src_w, y_start + target_crop_h))
            content = cropped.resize((content_width, content_height), Image.Resampling.LANCZOS)

        elif fname == "03_player.png":
            # Full 16:9 widescreen video with top bar and bottom playback controls
            content = Image.new("RGBA", (content_width, content_height), (0, 0, 0, 255))
            video = src.crop((0, 770, src_w, 1931))
            v_h = int(content_width * 1161 / src_w)
            v_scaled = video.resize((content_width, v_h), Image.Resampling.LANCZOS)
            content.paste(v_scaled, (0, (content_height - v_h) // 2))

            top_bar = src.crop((0, 60, src_w, 160))
            top_h = int(100 * content_width / src_w)
            top_scaled = top_bar.resize((content_width, top_h), Image.Resampling.LANCZOS)
            content.paste(top_scaled, (0, 10))

            bottom_bar = src.crop((0, 2300, src_w, 2700))
            bot_h = int(400 * content_width / src_w)
            bottom_scaled = bottom_bar.resize((content_width, bot_h), Image.Resampling.LANCZOS)
            content.paste(bottom_scaled, (0, content_height - bot_h - 15))

        elif fname == "04_guide.png":
            # Live stream on left, Channel Guide drawer on right
            drawer_x = 1380
            content = Image.new("RGBA", (content_width, content_height), (0, 0, 0, 255))

            drawer_target_w = int(content_width * 0.38)
            drawer = src.crop((drawer_x, 60, src_w, 60 + target_crop_h))
            drawer_scaled = drawer.resize((drawer_target_w, content_height), Image.Resampling.LANCZOS)
            content.paste(drawer_scaled, (content_width - drawer_target_w, 0))

            video_pane_w = content_width - drawer_target_w
            video = src.crop((0, 770, drawer_x, 1931))
            v_h = int(video_pane_w * video.size[1] / video.size[0])
            v_scaled = video.resize((video_pane_w, v_h), Image.Resampling.LANCZOS)
            content.paste(v_scaled, (0, (content_height - v_h) // 2))

            top_bar = src.crop((0, 60, drawer_x, 160))
            top_bar_scaled = top_bar.resize((video_pane_w, int(100 * video_pane_w / drawer_x)), Image.Resampling.LANCZOS)
            content.paste(top_bar_scaled, (0, 0))

        elif fname == "05_settings.png":
            # Skip iPad status bar, show full Settings & Engine view
            y_start = 60
            cropped = src.crop((0, y_start, src_w, y_start + target_crop_h))
            content = cropped.resize((content_width, content_height), Image.Resampling.LANCZOS)

        else:
            y_start = 60
            cropped = src.crop((0, y_start, src_w, min(src_h, y_start + target_crop_h)))
            content = cropped.resize((content_width, content_height), Image.Resampling.LANCZOS)

        # Mask bottom corners to match window corner radius
        content_mask = Image.new("L", (content_width, content_height), 255)
        cmask_draw = ImageDraw.Draw(content_mask)
        cmask_draw.rectangle((0, 0, content_width, content_height - CORNER_RADIUS), fill=255)
        cmask_draw.rounded_rectangle((0, 0, content_width, content_height), radius=CORNER_RADIUS - 2, fill=255)

        win_img.paste(content, (2, TITLEBAR_HEIGHT + 1), content_mask)

    # Paste window onto backdrop
    final_canvas = Image.alpha_composite(backdrop, Image.new("RGBA", (CANVAS_WIDTH, CANVAS_HEIGHT), (0, 0, 0, 0)))
    final_canvas.paste(win_img, (win_x, win_y), win_img)

    # Convert to RGB and save
    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    final_canvas.convert("RGB").save(output_path, "PNG", optimize=True)
    print(f"Generated concept mockup: {output_path} ({CANVAS_WIDTH}x{CANVAS_HEIGHT})")

def main():
    print("Concept mockups only. Capture the native Mac app for store screenshots.")
    screens = [
        ("01_login.png", "BruTV - Sign In"),
        ("02_channels.png", "BruTV - Live Channels"),
        ("03_player.png", "BruTV - Player"),
        ("04_guide.png", "BruTV - Channel Guide"),
        ("05_settings.png", "BruTV - Settings & Engine"),
    ]

    for fname, title in screens:
        src = os.path.join(IPAD_DIR, fname)
        dst = os.path.join(MOCKUP_DIR, fname.replace(".png", ".mockup.png"))
        create_mac_mockup(src, dst, title)

if __name__ == "__main__":
    main()
