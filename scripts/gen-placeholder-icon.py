"""Generate Leapgate's PLACEHOLDER icon (a doorway) into a leapgate-client checkout.

Leapgate has no visual design yet. This draws a plain arched doorway on a rounded square
and writes every icon file the Windows build uses. Replace it once a real design exists.

Usage: python scripts/gen-placeholder-icon.py <leapgate-client dir>
Needs Pillow (pip install pillow).

Writes, relative to the client dir:
  flutter/assets/icon.svg                      icon shown inside the Flutter UI
  flutter/windows/runner/resources/app_icon.ico exe icon (Runner.rc), also used for shortcuts
  res/icon.ico                                 portable installer exe icon (libs/portable/build.rs)
  res/tray-icon.ico                            tray icon (src/tray.rs)
"""

import sys
from pathlib import Path

from PIL import Image, ImageDraw

BG = "#0F766E"
FG = "#FFFFFF"

# All geometry in a 256 x 256 box, shared by the SVG and the raster drawing.
CORNER = 56
DOOR_LEFT, DOOR_RIGHT, DOOR_BOTTOM = 76, 180, 212
ARCH_CENTER_Y = 112
ARCH_R = (DOOR_RIGHT - DOOR_LEFT) // 2
KNOB_X, KNOB_Y, KNOB_R = 156, 166, 9

SVG = f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256">
<!-- Leapgate placeholder icon: replace once a real design exists. -->
<rect width="256" height="256" rx="{CORNER}" fill="{BG}"/>
<path d="M{DOOR_LEFT} {DOOR_BOTTOM}V{ARCH_CENTER_Y}a{ARCH_R} {ARCH_R} 0 0 1 {2 * ARCH_R} 0V{DOOR_BOTTOM}z" fill="{FG}"/>
<circle cx="{KNOB_X}" cy="{KNOB_Y}" r="{KNOB_R}" fill="{BG}"/>
</svg>
"""

ICO_SIZES = [16, 20, 24, 32, 40, 48, 64, 128, 256]
SUPERSAMPLE = 1024


def render(px):
    s = px / 256
    img = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([0, 0, px - 1, px - 1], radius=CORNER * s, fill=BG)
    cx = (DOOR_LEFT + DOOR_RIGHT) / 2
    d.ellipse(
        [(cx - ARCH_R) * s, (ARCH_CENTER_Y - ARCH_R) * s,
         (cx + ARCH_R) * s, (ARCH_CENTER_Y + ARCH_R) * s],
        fill=FG,
    )
    d.rectangle([DOOR_LEFT * s, ARCH_CENTER_Y * s, DOOR_RIGHT * s, DOOR_BOTTOM * s], fill=FG)
    d.ellipse(
        [(KNOB_X - KNOB_R) * s, (KNOB_Y - KNOB_R) * s,
         (KNOB_X + KNOB_R) * s, (KNOB_Y + KNOB_R) * s],
        fill=BG,
    )
    return img


def write_ico(big, path):
    frames = [big.resize((n, n), Image.LANCZOS) for n in ICO_SIZES]
    path.parent.mkdir(parents=True, exist_ok=True)
    frames[-1].save(path, format="ICO", sizes=[(n, n) for n in ICO_SIZES],
                    append_images=frames[:-1])


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    client = Path(sys.argv[1])
    if not (client / "flutter" / "windows").is_dir():
        sys.exit(f"{client} does not look like a leapgate-client checkout")
    big = render(SUPERSAMPLE)
    (client / "flutter/assets/icon.svg").write_text(SVG, encoding="utf-8", newline="\n")
    for rel in ("flutter/windows/runner/resources/app_icon.ico", "res/icon.ico", "res/tray-icon.ico"):
        write_ico(big, client / rel)
        print(f"wrote {rel}")
    print("wrote flutter/assets/icon.svg")


if __name__ == "__main__":
    main()
