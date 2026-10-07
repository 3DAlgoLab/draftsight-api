#!/usr/bin/env python3
"""Measure plotted PDFs instead of trusting PrintOut.

PrintOut is silent on success, and DraftSight applies paper margins you may not have asked
for, so check three things per page:

  page size      - did the requested paper actually land (A4 landscape = 842 x 595 pt)
  ink-to-edge    - distance from the ink bounding box to each paper edge, in px
  colored pixels - monochrome.ctb should drive this to ~0.00%; unstyled output sits near 4%

  pip install pypdfium2 pillow
  python verify-plot.py DIR [--scale 1.1] [--max-colored 0.10] [--max-edge-margin 6]

Exit code 1 if any page exceeds --max-colored or keeps ink further from an edge than
--max-edge-margin (0 disables that gate). A PDF plotter with SetPrintMargins(0,0,0,0) should
come out near 0; a page plotted with the paper's default margins shows tens of px.
"""
import argparse
import pathlib
import sys

import pypdfium2 as pdfium
from PIL import Image


def measure(img, step=2):
    w, h = img.size
    px = img.get_flattened_data() if hasattr(img, 'get_flattened_data') else list(img.getdata())
    colored = ink = sampled = 0
    minx, miny, maxx, maxy = w, h, -1, -1
    for y in range(0, h, step):
        row = y * w
        for x in range(0, w, step):
            r, g, b = px[row + x]
            sampled += 1
            if max(r, g, b) - min(r, g, b) > 12:
                colored += 1
            if max(r, g, b) < 200:
                ink += 1
                minx, maxx = min(minx, x), max(maxx, x)
                miny, maxy = min(miny, y), max(maxy, y)
    return dict(colored=100.0 * colored / sampled, ink=100.0 * ink / sampled,
                edges=(minx, w - 1 - maxx, miny, h - 1 - maxy))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('dir')
    ap.add_argument('--scale', type=float, default=1.1)
    ap.add_argument('--max-colored', type=float, default=0.10)
    ap.add_argument('--max-edge-margin', type=int, default=6)
    ap.add_argument('--preview', action='store_true', help='write <name>_preview.png next to each PDF')
    a = ap.parse_args()

    base = pathlib.Path(a.dir)
    bad = []
    for p in sorted(base.glob('*.pdf')):
        doc = pdfium.PdfDocument(str(p))
        for i in range(len(doc)):
            pw, ph = doc[i].get_size()
            img = doc[i].render(scale=a.scale).to_pil().convert('RGB')
            m = measure(img)
            tag = '%s p%d  %.0fx%.0fpt  colored %6.3f%%  ink %6.3f%%  edges L=%d R=%d T=%d B=%d' % (
                p.name, i, pw, ph, m['colored'], m['ink'], *m['edges'])
            print(tag)
            if a.preview:
                img.save(str(base / (p.stem + '_preview.png')))
            if m['colored'] > a.max_colored:
                bad.append(tag + '  <- colored above gate')
            if a.max_edge_margin and max(m['edges']) > a.max_edge_margin:
                bad.append(tag + '  <- ink kept away from an edge')
    if bad:
        print('\nFAILED:')
        for b in bad:
            print(' ', b)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
