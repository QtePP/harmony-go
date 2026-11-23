#!/usr/bin/env python3
"""Render the HarmonyGo mark (parallelogram bar + bolt) into the raster icons.

Why this exists: `entry/src/main/resources/base/media/{foreground,startIcon,app_logo}.png`
and `AppScope/resources/base/media/foreground.png` are bitmaps of the same mark as
`logo.svg` / `bolt.svg`. They had drifted (they still carried the old 3.2-unit-tall
capsule bar while the SVG said 2.6), because nothing regenerated them. Run this after
touching the mark so the launcher icon and the in-app logo stay one object.

Geometry is the source of truth and is mirrored from the SVGs:
  * viewBox 0 0 24 24, mapped to 512px with a 0.9px offset
  * bar: parallelogram, top edge y=3.2 from x=4.3..20.8, bottom edge y=5.8 from
    x=3.2..19.7 — sides parallel, leaning 1.1 units left over 2.6 units down (~23°)
  * bolt: unchanged polygon
  * shadows: the two blurred layers logo.svg uses (far 0.20 @ 1.7, near 0.34 @ 0.5)

Usage:  python3 scripts/make-mark-icons.py
"""
import os
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

SS = 4                      # supersample factor
SIZE = 512                  # output px
U = SIZE / 24.0             # units -> px
OFF = 0.9                   # px offset (the 24-unit box is not exactly flush)
INK = 19                    # near-black used by the existing icons (#131313)
SHEAR = 1.1                 # bar shear, units left per 2.6 units down

BAR = [(3.2 + SHEAR, 3.2), (20.8, 3.2), (20.8 - SHEAR, 5.8), (3.2, 5.8)]
BOLT = [(12.5, 5.5), (9.2, 13.2), (12.0, 13.2), (9.8, 20.5),
        (15.8, 11.8), (12.6, 11.8), (14.2, 5.5)]
SHADOWS = ((0.20, 1.7, 0.5, 1.8), (0.34, 0.5, 0.4, 0.9))

TARGETS = (
    'entry/src/main/resources/base/media/foreground.png',
    'entry/src/main/resources/base/media/startIcon.png',
    'entry/src/main/resources/base/media/app_logo.png',
    'AppScope/resources/base/media/foreground.png',
)


def mask(poly):
    im = Image.new('L', (SIZE * SS, SIZE * SS), 0)
    ImageDraw.Draw(im).polygon([(OFF + x * U * SS, OFF + y * U * SS) for x, y in poly], fill=255)
    return im.resize((SIZE, SIZE), Image.LANCZOS)


def render():
    m_bar, m_bolt = mask(BAR), mask(BOLT)
    dark = np.zeros((SIZE, SIZE))                       # 0 = paper, 1 = black
    for opacity, sigma, dx, dy in SHADOWS:
        cov = np.zeros((SIZE, SIZE))
        for m in (m_bar, m_bolt):
            b = np.array(m.filter(ImageFilter.GaussianBlur(sigma * U))) / 255.0
            b = np.roll(np.roll(b, int(round(dy * U)), axis=0), int(round(dx * U)), axis=1)
            cov = np.maximum(cov, b)
        dark = 1 - (1 - dark) * (1 - opacity * cov)
    ink = np.maximum(np.array(m_bar), np.array(m_bolt)) / 255.0 * (1 - INK / 255.0)
    dark = 1 - (1 - dark) * (1 - ink)
    return Image.fromarray(np.clip(255 * (1 - dark), 0, 255).astype('uint8'))


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    icon = render()
    for rel in TARGETS:
        path = os.path.join(root, rel)
        icon.save(path)
        print('wrote', rel, icon.size, 'mode', icon.mode)


if __name__ == '__main__':
    main()
