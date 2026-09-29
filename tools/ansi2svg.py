#!/usr/bin/env python3
"""Convert ANSI-coloured terminal text (stdin) into a standalone SVG "terminal screenshot".

Usage: ansi2svg.py OUT.svg [--title "root@host: ~"]  < ansi.txt

Only SGR colour/style sequences are interpreted (bold, dim, reverse, 16/256 colours);
every other escape sequence is ignored. Text is laid out on a fixed grid so box-drawing
characters line up regardless of the font used by the viewer.
"""
import re
import sys
from xml.sax.saxutils import escape

BG = "#1e1e2e"
FG = "#cdd6f4"
CHROME = "#181825"
ANSI16 = {
    30: "#45475a", 31: "#f38ba8", 32: "#a6e3a1", 33: "#f9e2af",
    34: "#89b4fa", 35: "#cba6f7", 36: "#89dceb", 37: "#bac2de",
    90: "#585b70", 91: "#f38ba8", 92: "#a6e3a1", 93: "#f9e2af",
    94: "#89b4fa", 95: "#cba6f7", 96: "#89dceb", 97: "#ffffff",
}
CW, LH, FS = 8.4, 19.0, 14
PAD_X, PAD_Y, BAR = 18, 14, 34
SGR = re.compile(r"\x1b\[([0-9;?]*)([A-Za-z])")


def xterm256(n):
    if n < 16:
        base = [30, 31, 32, 33, 34, 35, 36, 37, 90, 91, 92, 93, 94, 95, 96, 97][n]
        return ANSI16[base]
    if n >= 232:
        v = 8 + (n - 232) * 10
        return "#%02x%02x%02x" % (v, v, v)
    n -= 16
    lv = [0, 95, 135, 175, 215, 255]
    return "#%02x%02x%02x" % (lv[n // 36], lv[(n // 6) % 6], lv[n % 6])


def parse(text):
    """-> list of lines; each line is a list of (char, fg, bold, dim, reverse)."""
    fg, bold, dim, rev = None, False, False, False
    lines, cur = [], []
    pos = 0
    for m in SGR.finditer(text):
        for ch in text[pos:m.start()]:
            if ch == "\n":
                lines.append(cur)
                cur = []
            elif ch == "\r":
                continue
            else:
                cur.append((ch, fg, bold, dim, rev))
        pos = m.end()
        if m.group(2) != "m":
            continue
        params = [int(p) if p else 0 for p in m.group(1).split(";")] or [0]
        i = 0
        while i < len(params):
            p = params[i]
            if p == 0:
                fg, bold, dim, rev = None, False, False, False
            elif p == 1:
                bold = True
            elif p == 2:
                dim = True
            elif p == 22:
                bold = dim = False
            elif p == 7:
                rev = True
            elif p == 27:
                rev = False
            elif p == 39:
                fg = None
            elif p in ANSI16:
                fg = ANSI16[p]
            elif p == 38 and i + 2 < len(params) and params[i + 1] == 5:
                fg = xterm256(params[i + 2])
                i += 2
            i += 1
    for ch in text[pos:]:
        if ch == "\n":
            lines.append(cur)
            cur = []
        elif ch != "\r":
            cur.append((ch, fg, bold, dim, rev))
    if cur:
        lines.append(cur)
    while lines and not lines[-1]:
        lines.pop()
    while lines and not lines[0]:
        lines.pop(0)
    return lines


def runs(line):
    out = []
    for ch, fg, bold, dim, rev in line:
        key = (fg, bold, dim, rev)
        if out and out[-1][0] == key:
            out[-1][1].append(ch)
        else:
            out.append((key, [ch]))
    return out


def render(lines, title):
    cols = max((len(l) for l in lines), default=1)
    w = cols * CW + PAD_X * 2
    h = len(lines) * LH + PAD_Y * 2 + BAR
    o = [
        '<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d" role="img" aria-label="%s">'
        % (w, h, w, h, escape(title)),
        '<rect width="100%%" height="100%%" rx="10" fill="%s"/>' % BG,
        '<path d="M0 10a10 10 0 0 1 10-10h%dp10 10v%dH0z" fill="%s"/>' % (w - 20, BAR - 10, CHROME),
        '<circle cx="20" cy="17" r="6" fill="#f38ba8"/><circle cx="40" cy="17" r="6" fill="#f9e2af"/>'
        '<circle cx="60" cy="17" r="6" fill="#a6e3a1"/>',
        '<text x="%d" y="22" fill="#6c7086" font-size="12" text-anchor="middle" '
        'font-family="\'JetBrains Mono\',\'DejaVu Sans Mono\',Menlo,Consolas,monospace">%s</text>'
        % (w // 2, escape(title)),
        '<g font-family="\'JetBrains Mono\',\'DejaVu Sans Mono\',Menlo,Consolas,monospace" font-size="%d">' % FS,
    ]
    for r, line in enumerate(lines):
        y = BAR + PAD_Y + r * LH + LH * 0.72
        x = PAD_X
        for (fg, bold, dim, rev), chars in runs(line):
            s = "".join(chars)
            width = len(s) * CW
            color = fg or FG
            if rev:
                o.append('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" fill="%s"/>'
                         % (x, y - LH * 0.72, width, LH, color))
                color = BG
            if s.strip():
                attrs = ' fill="%s"' % color
                if bold:
                    attrs += ' font-weight="bold"'
                if dim:
                    attrs += ' opacity="0.6"'
                o.append('<text x="%.1f" y="%.1f"%s textLength="%.1f" lengthAdjust="spacingAndGlyphs" '
                         'xml:space="preserve">%s</text>' % (x, y, attrs, width, escape(s)))
            x += width
    o.append("</g></svg>")
    return "\n".join(o)


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    out = sys.argv[1]
    title = "root@pg-server-01: ~"
    if "--title" in sys.argv:
        title = sys.argv[sys.argv.index("--title") + 1]
    data = sys.stdin.buffer.read().decode("utf-8", "replace")
    svg = render(parse(data), title)
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        f.write(svg + "\n")


if __name__ == "__main__":
    main()
