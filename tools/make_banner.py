#!/usr/bin/env python3
"""Generates the README hero banners: docs/banner.ru.svg and docs/banner.en.svg."""
import os
from xml.sax.saxutils import escape

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
SANS = "'Segoe UI','Helvetica Neue',Arial,sans-serif"
MONO = "'JetBrains Mono','DejaVu Sans Mono',Menlo,Consolas,monospace"

TEXT = {
    "ru": {
        "title": "PostgreSQL на VPS",
        "sub": "Развёртывание и администрирование одним скриптом",
        "chips": ["Автотюнинг", "БД на каждый проект", "Бэкапы", "NAT", "RU · EN"],
        "lines": [
            ("$ sudo ./pg_server_setup.sh setup", "#cdd6f4"),
            ("✔ PostgreSQL 17 установлен", "#a6e3a1"),
            ("✔ Настроено под 2 ядра / 4 ГБ", "#a6e3a1"),
            ("✔ Бэкап: ежедневно в 03:00", "#a6e3a1"),
            ("● Готово: 203.0.113.9:5432", "#89dceb"),
        ],
    },
    "en": {
        "title": "PostgreSQL on a VPS",
        "sub": "Deploy and manage with a single script",
        "chips": ["Auto-tuning", "DB per project", "Backups", "NAT-ready", "EN · RU"],
        "lines": [
            ("$ sudo ./pg_server_setup.sh setup", "#cdd6f4"),
            ("✔ PostgreSQL 17 installed", "#a6e3a1"),
            ("✔ Tuned for 2 cores / 4 GB", "#a6e3a1"),
            ("✔ Backups: daily at 03:00", "#a6e3a1"),
            ("● Ready: 203.0.113.9:5432", "#89dceb"),
        ],
    },
}


def banner(lang):
    t = TEXT[lang]
    w, h = 1280, 340
    o = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}" role="img" '
        f'aria-label="{escape(t["title"])} — {escape(t["sub"])}">',
        '<defs>'
        '<linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">'
        '<stop offset="0" stop-color="#0b1220"/><stop offset="0.55" stop-color="#11306b"/>'
        '<stop offset="1" stop-color="#0e7490"/></linearGradient>'
        '<linearGradient id="ttl" x1="0" y1="0" x2="1" y2="0">'
        '<stop offset="0" stop-color="#ffffff"/><stop offset="1" stop-color="#93c5fd"/></linearGradient>'
        '<radialGradient id="glow" cx="0.85" cy="0.1" r="0.7">'
        '<stop offset="0" stop-color="#38bdf8" stop-opacity="0.35"/><stop offset="1" stop-color="#38bdf8" stop-opacity="0"/>'
        '</radialGradient>'
        '<pattern id="dots" width="22" height="22" patternUnits="userSpaceOnUse">'
        '<circle cx="2" cy="2" r="1.2" fill="#ffffff" fill-opacity="0.07"/></pattern>'
        '<filter id="shadow" x="-10%" y="-10%" width="120%" height="130%">'
        '<feDropShadow dx="0" dy="10" stdDeviation="14" flood-color="#000" flood-opacity="0.45"/></filter>'
        '</defs>',
        f'<rect width="{w}" height="{h}" rx="18" fill="url(#bg)"/>',
        f'<rect width="{w}" height="{h}" rx="18" fill="url(#dots)"/>',
        f'<rect width="{w}" height="{h}" rx="18" fill="url(#glow)"/>',
        # database cylinder icon
        '<g transform="translate(64 62)" fill="none" stroke="#7dd3fc" stroke-width="5" stroke-linecap="round">'
        '<ellipse cx="42" cy="18" rx="38" ry="14" fill="#0ea5e9" fill-opacity="0.25"/>'
        '<path d="M4 18v30c0 8 17 14 38 14s38-6 38-14V18"/>'
        '<path d="M4 48v30c0 8 17 14 38 14s38-6 38-14V48"/>'
        '<path d="M4 33c0 8 17 14 38 14s38-6 38-14" stroke-opacity="0.6"/>'
        '</g>',
        f'<text x="176" y="120" font-family="{SANS}" font-size="60" font-weight="800" fill="url(#ttl)" '
        f'textLength="{len(t["title"]) * 34}" lengthAdjust="spacingAndGlyphs">{escape(t["title"])}</text>',
        f'<text x="178" y="166" font-family="{SANS}" font-size="22" fill="#bfdbfe">{escape(t["sub"])}</text>',
    ]
    # chips
    x = 64
    y = 224
    for chip in t["chips"]:
        cw = len(chip) * 10.2 + 34
        o.append(f'<rect x="{x}" y="{y}" width="{cw:.0f}" height="42" rx="21" fill="#ffffff" fill-opacity="0.10" '
                 f'stroke="#93c5fd" stroke-opacity="0.45"/>')
        o.append(f'<text x="{x + cw / 2:.0f}" y="{y + 27}" text-anchor="middle" font-family="{SANS}" font-size="17" '
                 f'font-weight="600" fill="#e0f2fe">{escape(chip)}</text>')
        x += cw + 12
    # terminal card
    tx, ty, tw, th = 826, 50, 404, 240
    o.append(f'<g filter="url(#shadow)"><rect x="{tx}" y="{ty}" width="{tw}" height="{th}" rx="14" fill="#1e1e2e"/></g>')
    o.append(f'<path d="M{tx} {ty + 14}a14 14 0 0 1 14-14h{tw - 28}a14 14 0 0 1 14 14v18H{tx}z" fill="#181825"/>')
    for i, c in enumerate(("#f38ba8", "#f9e2af", "#a6e3a1")):
        o.append(f'<circle cx="{tx + 22 + i * 20}" cy="{ty + 16}" r="6" fill="{c}"/>')
    ly = ty + 62
    for text, color in t["lines"]:
        o.append(f'<text x="{tx + 24}" y="{ly}" font-family="{MONO}" font-size="16" fill="{color}" '
                 f'xml:space="preserve">{escape(text)}</text>')
        ly += 34
    o.append('</svg>')
    return "\n".join(o) + "\n"


def main():
    os.makedirs(os.path.join(ROOT, "docs"), exist_ok=True)
    for lang in ("ru", "en"):
        path = os.path.join(ROOT, "docs", f"banner.{lang}.svg")
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(banner(lang))
        print("wrote", os.path.normpath(path))


if __name__ == "__main__":
    main()
