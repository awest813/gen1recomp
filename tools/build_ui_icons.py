"""Render the UI kit's icon atlases from upstream Lucide SVG artwork.

Writes assets/ui/lucide/icons.png and editor.png: white 96-pixel cells packed
left to right, in the order src/ui/kit/Icons.lua lists them (`names`, then
`editorNames`).  The kit tints them at draw time.  Also fetches Lucide's
license (ISC, with Feather's MIT notice) next to them.

    pip install cairosvg pillow
    python3 tools/build_ui_icons.py
"""
from io import BytesIO
from pathlib import Path
import re
import urllib.request

import cairosvg
from PIL import Image

COMMIT = "f06ac67e33d645c40b8ce19a0419c85c5d7dd751"
BASE = f"https://raw.githubusercontent.com/lucide-icons/lucide/{COMMIT}"
CELL = 96


def fetch(path):
    with urllib.request.urlopen(f"{BASE}/{path}", timeout=30) as response:
        return response.read()


def icon_lists(icons_lua):
    """The two name lists, read from Icons.lua so the order cannot drift."""
    text = icons_lua.read_text()
    lists = []
    for var in ("names", "editorNames"):
        body = re.search(r"local " + var + r" = \{(.*?)\n\}", text, re.S).group(1)
        lists.append(re.findall(r'"([a-z0-9-]+)"', body))
    return lists


def atlas(names, output):
    sheet = Image.new("RGBA", (CELL * len(names), CELL), (0, 0, 0, 0))
    for i, name in enumerate(names):
        svg = fetch(f"icons/{name}.svg").decode("utf-8").replace(
            'stroke="currentColor"', 'stroke="#ffffff"')
        png = cairosvg.svg2png(bytestring=svg.encode("utf-8"),
                               output_width=CELL, output_height=CELL)
        sheet.paste(Image.open(BytesIO(png)).convert("RGBA"), (i * CELL, 0))
    sheet.save(output, optimize=True)


def main():
    root = Path(__file__).resolve().parent.parent
    out = root / "assets/ui/lucide"
    out.mkdir(parents=True, exist_ok=True)
    names, editor = icon_lists(root / "src/ui/kit/Icons.lua")
    atlas(names, out / "icons.png")
    atlas(editor, out / "editor.png")
    (out / "LICENSE").write_bytes(fetch("LICENSE"))
    print(f"Rendered {len(names)} + {len(editor)} Lucide icons into {out.relative_to(root)}")


if __name__ == "__main__":
    main()
