#!/usr/bin/env python3
from pathlib import Path
import struct

from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[1]
ICONSET = ROOT / "build" / "AppIcon.iconset"
OUTPUT = ROOT / "Resources" / "AppIcon.icns"


def make_master() -> Image.Image:
    size = 1024
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle((18, 18, 1006, 1006), radius=210,
                           fill=(7, 9, 15, 255), outline=(70, 78, 102, 255), width=12)

    margin = 138
    gap = 12
    cell = (size - margin * 2 - gap * 7) // 8
    blue = (46, 92, 255, 255)
    magenta = (255, 82, 244, 255)
    for row in range(8):
        for column in range(8):
            x = margin + column * (cell + gap)
            y = margin + row * (cell + gap)
            color = blue if (row + column) % 2 == 0 else magenta
            draw.rounded_rectangle((x, y, x + cell, y + cell), radius=13, fill=color)
    return image


def main() -> None:
    ICONSET.mkdir(parents=True, exist_ok=True)
    master = make_master()
    specifications = [
        (16, "icon_16x16.png"),
        (32, "icon_16x16@2x.png"),
        (32, "icon_32x32.png"),
        (64, "icon_32x32@2x.png"),
        (128, "icon_128x128.png"),
        (256, "icon_128x128@2x.png"),
        (256, "icon_256x256.png"),
        (512, "icon_256x256@2x.png"),
        (512, "icon_512x512.png"),
        (1024, "icon_512x512@2x.png"),
    ]
    for pixels, name in specifications:
        master.resize((pixels, pixels), Image.Resampling.LANCZOS).save(ICONSET / name)

    # Modern ICNS elements contain PNG payloads. Building the small container
    # directly avoids relying on iconutil versions that reject legacy iconsets.
    elements = [
        (b"icp4", "icon_16x16.png"),
        (b"icp5", "icon_32x32.png"),
        (b"icp6", "icon_32x32@2x.png"),
        (b"ic07", "icon_128x128.png"),
        (b"ic08", "icon_256x256.png"),
        (b"ic09", "icon_512x512.png"),
        (b"ic10", "icon_512x512@2x.png"),
    ]
    chunks = []
    for kind, name in elements:
        data = (ICONSET / name).read_bytes()
        chunks.append(kind + struct.pack(">I", len(data) + 8) + data)
    body = b"".join(chunks)
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)
    print(OUTPUT)


if __name__ == "__main__":
    main()
