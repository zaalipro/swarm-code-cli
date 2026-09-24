#!/usr/bin/env python3
"""Tiny VT emulator: replay a raw terminal log, dump the final (or Nth-frame) screen.

usage: vt.py LOG COLS ROWS OUT_PREFIX [--upto BYTES]
writes OUT_PREFIX.txt (UTF-8 glyphs) and OUT_PREFIX.svg (true colours).
"""
import sys, unicodedata, html

def wcw(ch):
    if unicodedata.combining(ch):
        return 0
    ea = unicodedata.east_asian_width(ch)
    return 2 if ea in ("W", "F") else 1

def main():
    log, cols, rows, out = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
    upto = None
    if "--upto" in sys.argv:
        upto = int(sys.argv[sys.argv.index("--upto") + 1])
    data = open(log, "rb").read()
    if upto:
        data = data[:upto]
    text = data.decode("utf-8", "replace")
    DEF_FG, DEF_BG = (200, 200, 200), (0, 0, 0)
    grid = [[[" ", DEF_FG, DEF_BG, False] for _ in range(cols)] for _ in range(rows)]
    cy = cx = 0
    fg, bg, bold = DEF_FG, DEF_BG, False
    i, n = 0, len(text)
    frames = 0
    while i < n:
        c = text[i]
        if c == "\x1b":
            if i + 1 < n and text[i + 1] == "[":
                j = i + 2
                while j < n and not ("\x40" <= text[j] <= "\x7e"):
                    j += 1
                params, final = text[i + 2 : j], text[j] if j < n else ""
                i = j + 1
                if final == "H" or final == "f":
                    p = params.split(";") if params else []
                    cy = (int(p[0]) - 1) if p and p[0] else 0
                    cx = (int(p[1]) - 1) if len(p) > 1 and p[1] else 0
                elif final == "K":
                    for x in range(cx, cols):
                        if 0 <= cy < rows:
                            grid[cy][x] = [" ", fg, bg, False]
                elif final == "J":
                    if params in ("2", "3"):
                        for y in range(rows):
                            for x in range(cols):
                                grid[y][x] = [" ", fg, bg, False]
                elif final == "m":
                    p = [int(x) if x else 0 for x in params.split(";")] if params else [0]
                    k = 0
                    while k < len(p):
                        v = p[k]
                        if v == 0:
                            fg, bg, bold = DEF_FG, DEF_BG, False
                        elif v == 1:
                            bold = True
                        elif v == 22:
                            bold = False
                        elif v == 38 and k + 4 < len(p) + 0 and p[k + 1] == 2:
                            fg = tuple(p[k + 2 : k + 5]); k += 4
                        elif v == 48 and p[k + 1] == 2:
                            bg = tuple(p[k + 2 : k + 5]); k += 4
                        elif v == 39:
                            fg = DEF_FG
                        elif v == 49:
                            bg = DEF_BG
                        elif v == 7:
                            fg, bg = bg, fg
                        k += 1
                elif final == "h" and params == "?2026":
                    pass
                elif final == "l" and params == "?2026":
                    frames += 1
                elif final == "C":
                    cx += int(params or 1)
                elif final == "A":
                    cy -= int(params or 1)
                elif final == "B":
                    cy += int(params or 1)
                elif final == "D":
                    cx -= int(params or 1)
                elif final == "G":
                    cx = int(params or 1) - 1
                continue
            elif i + 1 < n and text[i + 1] == "]":
                j = i + 2
                while j < n and text[j] not in "\x07":
                    if text[j] == "\x1b" and j + 1 < n and text[j + 1] == "\\":
                        j += 1
                        break
                    j += 1
                i = j + 1
                continue
            else:
                i += 3 if i + 1 < n and text[i + 1] in "()" else 2
                continue
        if c == "\r":
            cx = 0
        elif c == "\n":
            cy += 1
        elif c == "\b":
            cx = max(0, cx - 1)
        elif c in "\x07\x0e\x0f":
            pass
        elif ord(c) >= 32:
            w = wcw(c)
            if 0 <= cy < rows and 0 <= cx < cols:
                grid[cy][cx] = [c, fg, bg, bold]
                if w == 2 and cx + 1 < cols:
                    grid[cy][cx + 1] = ["", fg, bg, bold]
            cx += w
        i += 1
    with open(out + ".txt", "w") as f:
        for row in grid:
            f.write("".join(cell[0] for cell in row).rstrip() + "\n")
    cw, ch = 9, 18
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{cols*cw}" height="{rows*ch}" font-family="Menlo, monospace" font-size="14">']
    for y, row in enumerate(grid):
        for x, (g, cf, cb, b) in enumerate(row):
            parts.append(f'<rect x="{x*cw}" y="{y*ch}" width="{cw+0.5}" height="{ch+0.5}" fill="rgb{cb}"/>')
    for y, row in enumerate(grid):
        for x, (g, cf, cb, b) in enumerate(row):
            if g.strip():
                wt = ' font-weight="bold"' if b else ""
                parts.append(f'<text x="{x*cw}" y="{y*ch+14}" fill="rgb{cf}"{wt}>{html.escape(g)}</text>')
    parts.append("</svg>")
    open(out + ".svg", "w").write("\n".join(parts))
    print(f"frames={frames} bytes={len(data)}")

main()
