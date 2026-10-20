#!/usr/bin/env python3
"""Draw docs/demo.gif from the frames scripts/demo-gif.el records.

Each frame becomes an SVG of an Emacs window (header line, buffer text
with a colour per face class, cursor, echo area) under a caption, and
ImageMagick turns them into an animated GIF.

    eldev -p emacs --batch -l scripts/demo-gif.el -f a2ui-demo-gif-frames
    python3 scripts/demo-gif.py
"""

import json
import pathlib
import subprocess
import tempfile
from xml.sax.saxutils import escape

ROOT = pathlib.Path(__file__).resolve().parent.parent
FONT = "Menlo, DejaVu Sans Mono, monospace"
SIZE = 15
CW = SIZE * 0.6021          # Menlo's advance width
LH = 21
PAD = 16
COLS = 74

BG, FG = "#1e1e2e", "#cdd6f4"
COLOURS = {
    "default": (FG, False), "heading": ("#89b4fa", True), "bold": (FG, True),
    "italic": ("#f5c2e7", False), "link": ("#74c7ec", False), "button": ("#74c7ec", False),
    "primary": ("#a6e3a1", True), "shadow": ("#6c7086", False), "error": ("#f38ba8", False),
    "rule": ("#45475a", False), "field": (FG, False), "code": ("#fab387", False),
    "added": ("#a6e3a1", False), "removed": ("#f38ba8", False), "hunk": ("#cba6f7", False),
    "file": ("#f9e2af", True), "keyword": ("#cba6f7", False), "string": ("#a6e3a1", False),
    "comment": ("#6c7086", False), "function": ("#89b4fa", False),
}


def text(x, y, s, colour=FG, bold=False, size=SIZE):
    weight = ' font-weight="bold"' if bold else ""
    return (f'<text x="{x:.1f}" y="{y}" font-family="{FONT}" font-size="{size}" fill="{colour}"'
            f'{weight} xml:space="preserve">{escape(s)}</text>')


def frame_svg(frame, rows):
    width = int(PAD * 2 + CW * COLS)
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
    out.append(text(width / 2 - 60, caption_h + 18, "*a2ui: review*", "#a6adc8", False, 13))
    # The header line names the agent that drew the surface.
    out.append(f'<rect x="0" y="{caption_h + title_h}" width="{width}" height="{header_h}" fill="#313244"/>')
    agent, _, surface = frame["header"].strip().partition("  ")
    out.append(text(PAD, caption_h + title_h + 17, agent, FG, True))
    out.append(text(PAD + CW * (len(agent) + 2), caption_h + title_h + 17, surface, "#a6adc8"))
    line, col = frame["cursor"]
    for n, spans in enumerate(frame["lines"]):
        y = top + 6 + (n + 1) * LH - 6
        x = PAD
        if n == line:
            out.append(f'<rect x="{PAD + CW * col:.1f}" y="{y - SIZE + 2}" width="{CW:.1f}" '
                       f'height="{LH - 2}" fill="#f5e0dc" opacity="0.85"/>')
        for cls, s in spans:
            colour, bold = COLOURS.get(cls, (FG, False))
            if cls == "field":
                out.append(f'<rect x="{x:.1f}" y="{y - SIZE + 1}" width="{CW * len(s):.1f}" '
                           f'height="{LH - 3}" fill="#313244"/>')
            if s.strip():
                out.append(text(x, y, s, colour, bold))
            x += CW * len(s)
    echo_y = height - echo_h
    out.append(f'<rect x="0" y="{echo_y}" width="{width}" height="{echo_h}" fill="#181825"/>')
    out.append(text(PAD, echo_y + 18, frame["echo"], "#f9e2af" if frame["echo"] else FG))
    out.append("</svg>")
    return "\n".join(out)


def main():
    frames = json.loads((ROOT / "docs/demo-frames.json").read_text())
    rows = max(len(f["lines"]) for f in frames)
    # How long each frame stays, in 1/100 s: hold the first and the last.
    delays = [260] + [170] * (len(frames) - 2) + [450]
    with tempfile.TemporaryDirectory() as tmp:
        pngs = []
        for i, frame in enumerate(frames):
            svg = pathlib.Path(tmp) / f"f{i:02d}.svg"
            svg.write_text(frame_svg(frame, rows))
            png = svg.with_suffix(".png")
            subprocess.run(["magick", "-density", "120", str(svg), str(png)], check=True)
            pngs.append(png)
        args = ["magick"]
        for png, delay in zip(pngs, delays):
            args += ["-delay", str(delay), str(png)]
        out = ROOT / "docs/demo.gif"
        args += ["-loop", "0", "-layers", "Optimize", str(out)]
        subprocess.run(args, check=True)
        (ROOT / "docs/demo.png").write_bytes(pngs[-1].read_bytes())
    print(f"wrote {out.relative_to(ROOT)} ({out.stat().st_size // 1024} KB, {len(frames)} frames)")


if __name__ == "__main__":
    main()
