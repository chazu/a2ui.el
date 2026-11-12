#!/usr/bin/env python3
"""Draw GIFs from the frames scripts/demo-gif.el and scripts/example-gifs.el record.

Each frame becomes an SVG of an Emacs window (header line, buffer text
with a colour per face class, cursor, echo area) under a caption, and
ImageMagick turns them into an animated GIF.  Each frames file names
its GIF, the window's title and size.

    eldev -p emacs --batch -l scripts/demo-gif.el -f a2ui-demo-gif-frames
    python3 scripts/demo-gif.py                      # docs/demo-frames.json
    python3 scripts/demo-gif.py docs/*-frames.json   # every recorded GIF
"""

import json
import pathlib
import subprocess
import sys
import tempfile
from xml.sax.saxutils import escape

ROOT = pathlib.Path(__file__).resolve().parent.parent
FONT = "Menlo, DejaVu Sans Mono, monospace"
SIZE = 15
CW = SIZE * 0.6021          # Menlo's advance width
LH = 21
PAD = 16
BLOCKS = " ▁▂▃▄▅▆▇█"         # drawn as rectangles, so bars line up exactly
SHADE = "░"

BG, FG = "#1e1e2e", "#cdd6f4"
COLOURS = {
    "default": (FG, False), "heading": ("#89b4fa", True), "bold": (FG, True),
    "italic": ("#f5c2e7", False), "link": ("#74c7ec", False), "button": ("#74c7ec", False),
    "primary": ("#a6e3a1", True), "shadow": ("#6c7086", False), "error": ("#f38ba8", False),
    "rule": ("#45475a", False), "field": (FG, False), "code": ("#fab387", False),
    "added": ("#a6e3a1", False), "removed": ("#f38ba8", False), "hunk": ("#cba6f7", False),
    "file": ("#f9e2af", True), "keyword": ("#cba6f7", False), "string": ("#a6e3a1", False),
    "comment": ("#6c7086", False), "function": ("#89b4fa", False),
    "success": ("#a6e3a1", False), "warning": ("#f9e2af", False),
}


def text(x, y, s, colour=FG, bold=False, size=SIZE):
    weight = ' font-weight="bold"' if bold else ""
    return (f'<text x="{x:.1f}" y="{y}" font-family="{FONT}" font-size="{size}" fill="{colour}"'
            f'{weight} xml:space="preserve">{escape(s)}</text>')


def mix(colour, amount):
    """Return COLOUR blended over the background by AMOUNT, as a solid colour."""
    a = [int(colour[i:i + 2], 16) for i in (1, 3, 5)]
    b = [int(BG[i:i + 2], 16) for i in (1, 3, 5)]
    return "#" + "".join(f"{round(p * amount + q * (1 - amount)):02x}" for p, q in zip(a, b))


def cells(x, y, s, colour, bold):
    """Draw S at X: ASCII as text, other characters one per cell, as Emacs does."""
    out, run, start = [], "", x
    for i, ch in enumerate(s + "\0"):
        if ch != "\0" and ord(ch) < 128:
            run += ch
            continue
        if run.strip():
            out.append(text(start, y, run, colour, bold))
        cx = start + CW * len(run)
        if ch == "\0":
            break
        top = y - SIZE + 1
        height = LH - 3
        if ch in BLOCKS[1:]:
            h = height * BLOCKS.index(ch) / 8
            out.append(f'<rect x="{cx:.1f}" y="{top + height - h:.1f}" width="{CW + 0.3:.1f}" '
                       f'height="{h:.1f}" fill="{colour}"/>')
        elif ch == SHADE:
            out.append(f'<rect x="{cx:.1f}" y="{top:.1f}" width="{CW + 0.3:.1f}" '
                       f'height="{height}" fill="{mix(colour, 0.25)}"/>')
        else:
            out.append(f'<text x="{cx + CW / 2:.1f}" y="{y}" font-family="{FONT}" font-size="{SIZE}" '
                       f'fill="{colour}" text-anchor="middle"{" font-weight=\"bold\"" if bold else ""}>'
                       f'{escape(ch)}</text>')
        run, start = "", cx + CW
    return out


def wrap(frame, cols):
    """Return FRAME's lines wrapped at word boundaries to COLS, and the cursor moved to match.

    A long line continues on the next row, as in an Emacs window with word-wrap."""
    rows, cursor = [], None
    line, col = frame["cursor"] or (-1, 0)
    for n, spans in enumerate(frame["lines"]):
        chars = [(cls, ch) for cls, s in spans for ch in s]
        # Padding past the last column would only wrap onto an empty row.
        while len(chars) > cols and chars[-1] == ("default", " "):
            chars.pop()
        start = 0
        while True:
            end = len(chars)
            if end - start > cols:
                end = start + cols
                space = max((i for i in range(start + cols // 2, end) if chars[i][1] == " "), default=None)
                if space is not None:
                    end = space + 1
            last = end >= len(chars)
            if n == line and cursor is None and start <= col and (col < end or last):
                cursor = (len(rows), col - start)
            row = []
            for cls, ch in chars[start:end]:
                if row and row[-1][0] == cls:
                    row[-1][1] += ch
                else:
                    row.append([cls, ch])
            rows.append(row)
            if last:
                break
            start = end
            while start < len(chars) - 1 and chars[start][1] == " ":
                start += 1
    return rows, cursor


def frame_svg(frame, rows, cols, title):
    width = int(PAD * 2 + CW * cols)
    caption_h, title_h, header_h, echo_h = 40, 26, 24, 26
    top = caption_h + title_h + header_h
    height = top + rows * LH + 8 + echo_h
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}">',
           f'<rect width="100%" height="100%" fill="#11111b"/>',
           text(PAD, 26, frame["caption"], "#f5e0dc", True, 16),
           f'<rect x="0" y="{caption_h}" width="{width}" height="{height - caption_h}" fill="{BG}"/>',
           f'<rect x="0" y="{caption_h}" width="{width}" height="{title_h}" fill="#181825"/>']
    for i, c in enumerate(["#f38ba8", "#f9e2af", "#a6e3a1"]):
        out.append(f'<circle cx="{PAD + 6 + i * 18}" cy="{caption_h + 13}" r="5.5" fill="{c}"/>')
    out.append(text(width / 2 - CW * len(title) / 2, caption_h + 18, title, "#a6adc8", False, 13))
    # The header line names the agent that drew the surface.
    out.append(f'<rect x="0" y="{caption_h + title_h}" width="{width}" height="{header_h}" fill="#313244"/>')
    agent, _, surface = frame["header"].strip().partition("  ")
    out.append(text(PAD, caption_h + title_h + 17, agent, FG, True))
    out.append(text(PAD + CW * (len(agent) + 2), caption_h + title_h + 17, surface, "#a6adc8"))
    lines, cursor = wrap(frame, cols)
    line, col = cursor or (-1, 0)
    for n, spans in enumerate(lines[:rows]):
        y = top + 6 + (n + 1) * LH - 6
        x, used = PAD, 0
        if n == line:
            out.append(f'<rect x="{PAD + CW * col:.1f}" y="{y - SIZE + 2}" width="{CW:.1f}" '
                       f'height="{LH - 2}" fill="#f5e0dc" opacity="0.85"/>')
        for cls, s in spans:
            s = s[:max(0, cols - used)]       # wrap() keeps rows within cols; this is a guard
            used += len(s)
            colour, bold = COLOURS.get(cls, (FG, False))
            if cls == "field":
                out.append(f'<rect x="{x:.1f}" y="{y - SIZE + 1}" width="{CW * len(s):.1f}" '
                           f'height="{LH - 3}" fill="#313244"/>')
            out.extend(cells(x, y, s, colour, bold))
            x += CW * len(s)
    echo_y = height - echo_h
    echo = frame["echo"] if len(frame["echo"]) <= cols else frame["echo"][:cols - 1] + "…"
    out.append(f'<rect x="0" y="{echo_y}" width="{width}" height="{echo_h}" fill="#181825"/>')
    out.extend(cells(PAD, echo_y + 18, echo, "#f9e2af" if echo else FG, False))
    out.append("</svg>")
    return "\n".join(out)


def draw(path):
    meta = json.loads(path.read_text())
    frames = meta["frames"]
    cols = meta.get("cols") or 74
    rows = meta.get("rows") or max(len(wrap(f, cols)[0]) for f in frames)
    # How long each frame stays, in 1/100 s: hold the first and the last.
    default = [260] + [170] * (len(frames) - 2) + [450]
    delays = [f.get("delay") or d for f, d in zip(frames, default)]
    with tempfile.TemporaryDirectory() as tmp:
        pngs = []
        for i, frame in enumerate(frames):
            svg = pathlib.Path(tmp) / f"f{i:03d}.svg"
            svg.write_text(frame_svg(frame, rows, cols, meta.get("title") or "*a2ui*"))
            png = svg.with_suffix(".png")
            subprocess.run(["magick", "-density", "120", str(svg), str(png)], check=True)
            pngs.append(png)
        args = ["magick"]
        for png, delay in zip(pngs, delays):
            args += ["-delay", str(delay), str(png)]
        out = ROOT / meta["output"]
        out.parent.mkdir(parents=True, exist_ok=True)
        # No dithering: it speckles the flat background.
        args += ["+dither", "-loop", "0", "-layers", "Optimize", str(out)]
        subprocess.run(args, check=True)
        if meta.get("still"):
            (ROOT / meta["still"]).write_bytes(pngs[-1].read_bytes())
    print(f"wrote {out.relative_to(ROOT)} ({out.stat().st_size // 1024} KB, {len(frames)} frames)")


def main():
    for arg in sys.argv[1:] or ["docs/demo-frames.json"]:
        draw(ROOT / arg)


if __name__ == "__main__":
    main()
