import sys
from PIL import Image, ImageDraw, ImageFont, ImageFilter
FONT = "/usr/share/fonts/opentype/inter/Inter-Black.otf"
SUB = "/usr/share/fonts/opentype/inter/Inter-Bold.otf"
YELLOW = (255, 203, 5, 255)
BLUE = (42, 93, 170, 255)
DEEP = (22, 44, 92, 255)

def wordmark(height, sub=True):
    # draw big then downsample for clean edges
    S = 4
    H = height * S
    size = int(H * (0.78 if sub else 0.95))
    font = ImageFont.truetype(FONT, size)
    text = "PK:GB"
    l, t, r, b = font.getbbox(text)
    tw, th = r - l, b - t
    stroke = max(2, size // 9)
    shadow = max(2, size // 16)
    subfont = ImageFont.truetype(SUB, max(8, int(H * 0.15)))
    subtext = "POKÉMON  GAMEBOY"
    sl, st, sr, sb = subfont.getbbox(subtext)
    W = int(max(tw + 2 * stroke + shadow, sr - sl) + 2 * stroke)
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    x = (W - tw) // 2 - l
    y = stroke - t
    # drop shadow / extrusion
    for i in range(shadow, 0, -1):
        d.text((x + i, y + i), text, font=font, fill=DEEP, stroke_width=stroke, stroke_fill=DEEP)
    d.text((x, y), text, font=font, fill=YELLOW, stroke_width=stroke, stroke_fill=BLUE)
    if sub:
        sy = y + th + stroke + shadow + int(H * 0.09)
        sx = (W - (sr - sl)) // 2 - sl
        d.text((sx, sy - st), subtext, font=subfont, fill=(245, 247, 250, 255),
               stroke_width=max(2, subfont.size // 7), stroke_fill=DEEP)
    bbox = img.getbbox()
    img = img.crop(bbox)
    w, h = img.size
    return img.resize((max(1, w // S), max(1, h // S)), Image.LANCZOS)

def cover(size=1024):
    S = size
    bg = Image.new("RGB", (S, S), (20, 24, 29))
    d = ImageDraw.Draw(bg)
    bands = [(255,60,72),(70,150,255),(255,203,5),(218,145,32),(190,198,210),(132,196,228),(38,162,78)]
    step = S * 2 // len(bands)
    for i, c in enumerate(bands):
        x0 = -S + i * step
        d.polygon([(x0, S), (x0 + step, S), (x0 + step + S, 0), (x0 + S, 0)], fill=c)
    bg = bg.filter(ImageFilter.GaussianBlur(S // 18))
    shade = Image.new("RGB", (S, S), (15, 17, 21))
    bg = Image.blend(bg, shade, 0.45)
    mark = wordmark(int(S * 0.42))
    if mark.size[0] > S * 0.86:
        k = S * 0.86 / mark.size[0]
        mark = mark.resize((int(mark.size[0] * k), int(mark.size[1] * k)), Image.LANCZOS)
    bg.paste(mark, ((S - mark.size[0]) // 2, (S - mark.size[1]) // 2), mark)
    return bg

if __name__ == "__main__":
    out = sys.argv[1]
    wordmark(168).save(out + "/logo.png")
    wordmark(99, sub=False).save(out + "/minilogo.png")
    cover().save(out + "/cover.png")
