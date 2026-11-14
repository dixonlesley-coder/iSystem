#!/usr/bin/env python3
"""Reference-building drawing sets: rasterise, contact sheets, scripted pre-check.

Input: the folders written by `test/reference_drawing_set_export_test.dart`
(REF_EXPORT=1), one per building under ROOT (default build/ref_drawings):
    ROOT/<building>/<Project>-*.pdf|dxf|csv|md

Writes, per building:
    png/<file>-p<N>.png       every page of every DRAWING PDF at 150 dpi
                              (the A4 calc / MEP reports are documents, not
                              sheets: read for item 24, not rasterised)
    contact/contact-<k>.png   <= 6 pages per montage, ~1100 px per tile
    precheck.md               one line per sheet per item, PASS / FAIL / N-A
and ROOT/INDEX.md (sheet tables + summary counts).

Items checked (docs/DRAFTING-CHECKLIST.md): 1/3 title block fields, 4 legend
text inside its LEGEND box (scripted part), 2/23
numbers unique + drawing list, 5 smallest text pt, 6 stamped overlap warning,
7 garbled glyphs, 9 every legend code is printed on its sheet (scripted
part, plans + risers + single-lines + schedules), 6 the supply / drainage
notes clear of linework, 21 panel-schedule totals add up to the DAYA rows
(E-201 / E-601), 23 no orphan schedule page, 24 cross-document figures, 25
PDF vs DXF text; fix round 4: 6 key / detail-bubble leaders clear of every
text, riser key circles clear of every symbol, no stroke through a printed
glyph on a plan / detail sheet; fix round 5: 8 key / bubble leaders within
their cap, uncrossed and clear of other key circles. Report only:
it never edits a drawing.

Needs: pdftoppm + pdftotext (poppler), ImageMagick `montage`, python3 with
pdfplumber.  Usage:  python3 tool/ref_drawings_precheck.py [ROOT]
"""
import glob
import hashlib
import os
import re
import subprocess
import sys
from collections import Counter, OrderedDict, defaultdict

import pdfplumber

BUILDINGS = ['house', 'shophouse', 'office', 'apartment', 'tower']
REPORT_SUFFIXES = ('-report.pdf', '-mep-report.pdf')
MIN_PT = 7.0
GLYPH_OK = set('ØøÆæ·°²³±×÷µΩ—–…éèáàüöäÉ≤≥‰’‘“”•√∆ΔΣ')
TB_LABELS = ['PROJECT', 'TITLE', 'DWG NO', 'REV', 'SCALE', 'DATE', 'DRAWN',
             'CHECKED', 'APPROVED', 'SHEET']


def sh(*args):
    return subprocess.run(args, capture_output=True, text=True).stdout


def pdftext(path, page=None, mode='-raw'):
    a = ['pdftotext', mode]
    if page:
        a += ['-f', str(page), '-l', str(page)]
    return sh(*a, path, '-')


def nows(s):
    return re.sub(r'\s+', '', s or '')


def norm_title(s):
    return nows(s).upper()


# ── title block ──────────────────────────────────────────────────────────────
def title_block(text):
    lines = [l.strip() for l in text.splitlines()]
    # A drawing label on the PROJECT row's baseline ('4.0 m PROJECT ...')
    # is merged into that line by `pdftotext -raw`: start the row at PROJECT.
    lines = [re.sub(r'^.*?\s(?=PROJECT(\s|$))', '', l)
             if re.search(r'\sPROJECT(\s|$)', l) and not l.startswith('PROJECT')
             else l for l in lines]
    starts = [i for i, l in enumerate(lines) if re.match(r'^PROJECT(\s|$)', l)]
    if not starts:
        return None
    i0 = starts[-1]
    tb = OrderedDict((k, None) for k in TB_LABELS)
    cur = None
    for l in lines[i0:i0 + 40]:
        hit = None
        for k in TB_LABELS:
            if l == k or l.startswith(k + ' '):
                hit = k
                break
        if hit:
            cur = hit
            v = l[len(hit):].strip()
            tb[hit] = v if v else (tb[hit] or '')
            if hit == 'SHEET':
                break
        elif cur == 'TITLE' and l:
            tb['TITLE'] = (tb['TITLE'] + ' ' + l).strip()
    return tb


# ── DXF text ────────────────────────────────────────────────────────────────
def dxf_strings(path):
    with open(path, encoding='utf-8', errors='replace') as f:
        raw = f.read().splitlines()
    out, ent, buf = [], None, []
    for i in range(0, len(raw) - 1, 2):
        code, val = raw[i].strip(), raw[i + 1]
        if code == '0':
            if buf:
                out.append(''.join(buf))
            buf, ent = [], val.strip()
        elif ent in ('TEXT', 'MTEXT', 'ATTRIB') and code in ('1', '3'):
            buf.append(val)
    if buf:
        out.append(''.join(buf))
    clean = []
    for s in out:
        s = s.replace('\\P', ' ')
        s = re.sub(r'\\[A-Za-z][^;\\]*;', '', s)
        s = s.replace('{', '').replace('}', '').replace('%%c', 'Ø')
        s = s.replace('%%d', '°').replace('%%p', '±')
        s = re.sub(r'%%(\d{3})', lambda m: chr(int(m.group(1))), s)
        s = re.sub(r'\s+', ' ', s).strip()
        if s:
            clean.append(s)
    return clean


# ── per building ────────────────────────────────────────────────────────────
def stem_of(path):
    return os.path.splitext(os.path.basename(path))[0]


def short(stem, project):
    return stem[len(project) + 1:] if stem.startswith(project + '-') else stem


def rasterise(bdir, pdfs):
    pdir = os.path.join(bdir, 'png')
    os.makedirs(pdir, exist_ok=True)
    for f in glob.glob(os.path.join(pdir, '*.png')):
        os.remove(f)
    pngs = {}
    for p in pdfs:
        st = stem_of(p)
        tmp = os.path.join(pdir, '_tmp')
        subprocess.run(['pdftoppm', '-r', '150', '-png', p, tmp], check=True)
        for t in sorted(glob.glob(tmp + '-*.png')):
            n = int(re.search(r'-(\d+)\.png$', t).group(1))
            dst = os.path.join(pdir, f'{st}-p{n}.png')
            os.replace(t, dst)
            pngs[(st, n)] = dst
    return pngs


def contact_sheets(bdir, ordered_pages, pngs, project):
    cdir = os.path.join(bdir, 'contact')
    os.makedirs(cdir, exist_ok=True)
    for f in glob.glob(os.path.join(cdir, '*.png')):
        os.remove(f)
    where = {}
    for k in range(0, len(ordered_pages), 6):
        chunk = ordered_pages[k:k + 6]
        out = os.path.join(cdir, f'contact-{k // 6 + 1:02d}.png')
        args = ['montage']
        for (st, n) in chunk:
            args += ['-label', f'{short(st, project)}  p{n}', pngs[(st, n)]]
        args += ['-geometry', '1100x+12+12', '-tile', '2x3',
                 '-pointsize', '22', '-background', '#d8d8d8', out]
        subprocess.run(args, check=True)
        for pg in chunk:
            where[pg] = os.path.relpath(out, bdir)
    return where


def parse_drawing_list(cover_pdf):
    rows = []
    for l in pdftext(cover_pdf, mode='-layout').splitlines():
        m = re.match(r'^\s*(\d+)\s+([A-Z]{1,2}-\d{3})\s+(.+?)\s{2,}(\S+)\s+'
                     r'(\d{4}-\d{2}-\d{2})\s*$', l)
        if m:
            rows.append(dict(no=int(m.group(1)), number=m.group(2),
                             title=m.group(3).strip(), rev=m.group(4)))
    return rows


def true_size(ch):
    """The rendered font size of a pdfplumber char, valid for ROTATED text
    too (pdfplumber's own `size` is the axis-aligned bbox extent, which for
    a 90-degree label is the glyph advance, not the font size)."""
    a, b, c, d = ch['matrix'][:4]
    u = (a * a + b * b) ** 0.5 or 1.0
    cos, sin = abs(a / u), abs(b / u)
    adv = ch.get('adv') or 0.0
    w, h = ch['x1'] - ch['x0'], ch['bottom'] - ch['top']
    if sin > 0.5:
        return (w - adv * u * cos) / sin
    return (h - adv * u * sin) / cos


def page_words(pdf):
    """[(page_no, width, height, [(string, true pt size)])]: runs of
    consecutive glyphs that share one rendered size."""
    res = []
    with pdfplumber.open(pdf) as doc:
        for i, pg in enumerate(doc.pages, 1):
            runs, cur, cur_s = [], '', None
            for ch in pg.chars:
                ts = round(true_size(ch), 2)
                if cur_s is not None and abs(ts - cur_s) > 0.05:
                    runs.append((cur, cur_s))
                    cur = ''
                cur, cur_s = cur + ch['text'], ts
            if cur:
                runs.append((cur, cur_s))
            res.append((i, float(pg.width), float(pg.height),
                        [(t.strip(), sz) for t, sz in runs if t.strip()]))
    return res


def key_table_hits(pdf):
    """Fix round F4 - {page: [intruding text]} for every KETERANGAN PIPA /
    PIPE KEY table on a plan: glyphs that are not the table's own and come
    within half a text height of the table (or print inside it). Works on
    single glyphs (pdfplumber's word grouping garbles a touching label)."""
    out = {}
    with pdfplumber.open(pdf) as doc:
        for i, pg in enumerate(doc.pages, 1):
            up = [c for c in pg.chars if c.get('upright', True)]
            rows = defaultdict(list)
            for c in up:
                rows[round(c['top'], 1)].append(c)
            titles = []
            for top, cs in rows.items():
                cs.sort(key=lambda c: c['x0'])
                txt = ''.join(c['text'] for c in cs)
                for m in re.finditer('KETERANGAN PIPA', txt):
                    titles.append(cs[m.start()])
            # Pass 1: every key-table block's box and own glyph rows. A
            # split table's blocks may abut (one table, continued): a glyph
            # owned by ANY block is never an intruder.
            tables = []
            for t in titles:
                ts = t['bottom'] - t['top']
                hz = [l for l in pg.lines if abs(l['x0'] - t['x0']) < 1.0
                      and abs(l['top'] - l['bottom']) < 0.5
                      and t['bottom'] - 1 <= l['top'] <= t['bottom'] + 3 * ts]
                if not hz:
                    continue
                x1 = max(l['x1'] for l in hz)
                gtop = min(l['top'] for l in hz)
                vt = [l for l in pg.lines if abs(l['x0'] - l['x1']) < 0.5
                      and t['x0'] - 1 <= l['x0'] <= x1 + 1
                      and abs(l['top'] - gtop) < 1.0]
                if not vt:
                    continue
                bot = max(l['bottom'] for l in vt)
                cols = sorted({l['x0'] for l in vt})
                strict = (t['x0'] - 0.5, t['top'] - 0.2 * ts - 0.5,
                          x1 + 0.5, bot + 0.5)

                def within(c, st=strict):
                    return (c['x0'] >= st[0] and c['x1'] <= st[2]
                            and c['top'] >= st[1] and c['bottom'] <= st[3])
                own_tops = {round(t['top'], 1)}
                for c in up:
                    if within(c) and any(abs(c['x0'] - (x + 0.5 * ts)) < 1.0
                                         for x in cols):
                        own_tops.add(round(c['top'], 1))
                tables.append((ts, strict, within, own_tops))

            def owned(c):
                return c.get('upright', True) and any(
                    w(c) and round(c['top'], 1) in tops
                    for _, _, w, tops in tables)

            def meets(b, r):
                return (b[0] < r[2] and r[0] < b[2] and b[1] < r[3]
                        and r[1] < b[3])
            hits = []
            for ts, strict, _, _ in tables:
                m = 0.5 * ts
                infl = (strict[0] - m, strict[1] - m, strict[2] + m,
                        strict[3] + m)
                bad = []
                for c in pg.chars:
                    b = (c['x0'], c['top'], c['x1'], c['bottom'])
                    if not meets(b, infl) or not c['text'].strip():
                        continue
                    if not owned(c):
                        bad.append(c['text'])
                if bad:
                    hits.append(''.join(bad)[:40])
            if hits:
                out[i] = hits
    return out


def paper(w, h):
    a, b = sorted((round(w), round(h)))
    return {(595, 842): 'A4', (842, 1191): 'A3', (1191, 1684): 'A2',
            (1684, 2384): 'A1', (2384, 3370): 'A0'}.get((a, b),
                                                         f'{a}x{b}pt')


def plan_signature(text, floor_name):
    """Text fingerprint of a plan with the floor-specific tokens masked (the
    floor name, per-floor tags `-L5`, levels `+21.00`, numbers, counters), so
    typical floors that differ only in their floor collapse to one type."""
    t = text
    i = t.rfind('PROJECT')
    if i > 0:
        t = t[:i]
    t = t.replace(floor_name, '<FLOOR>') if floor_name else t
    f = nows(t)
    f = re.sub(r'Lantai\d+', 'Lantai#', f)
    f = re.sub(r'-(L\d+|GF|B\d+|RF)', '-L#', f)
    f = re.sub(r'[+-]\d+\.\d{2}', '+#', f)
    f = re.sub(r'[A-Z]-\d{3}', 'X-NNN', f)
    f = re.sub(r'\d+of\d+', '#of#', f)
    return hashlib.sha1(f.encode()).hexdigest()[:10]


def sizes(rx, text):
    return sorted({int(x) for x in re.findall(rx, text)})


def figures(bdir, project, drawing_pdfs):
    out = []
    p = lambda s: os.path.join(bdir, f'{project}-{s}')
    bom = open(p('bom.csv'), encoding='utf-8-sig').read() \
        if os.path.exists(p('bom.csv')) else ''
    riser = pdftext(p('riser-sld.pdf')) if os.path.exists(p('riser-sld.pdf')) \
        else ''
    plans = ''.join(pdftext(f) for f in drawing_pdfs
                    if re.search(r'-plan-\d+-', f))
    for svc, bomname, code in [('cold-water riser', 'Cold water', 'CW'),
                               ('drainage stack', 'Drainage', 'D')]:
        b = sizes(rf'{bomname} pipe riser DN(\d+)', bom)
        pl = sizes(rf'(?<![A-Z]){code}-R\d+\s*·\s*DN(\d+)', plans)
        r = sizes(rf'(?<![A-Z0-9])(\d+)-{code}-', riser)
        if not b and not pl:
            out.append(f'- 24 {svc}: N-A (no riser of this service)')
            continue
        missing_r = [x for x in sorted(set(b) | set(pl)) if x not in r]
        diff_bp = sorted(set(b) ^ set(pl))
        ok = not missing_r and not diff_bp
        out.append(
            f'- 24 {svc} DN: {"PASS" if ok else "FAIL"} - plan riser tags '
            f'{code}-Rn {pl}; BOM "{bomname} pipe riser" {b}; riser SLD '
            f'"<DN>-{code}-" labels {r}'
            + (f'; BOM vs plan differ on {diff_bp}' if diff_bp else '')
            + (f'; not on riser SLD: {missing_r}' if missing_r else ''))
    rx = r'Incomer (MCCB|MCB|ACB) [A-D]?(\d+)A/(\d)P (\S+?)kA'
    sched = pdftext(p('panel-schedules.pdf'), 1) \
        if os.path.exists(p('panel-schedules.pdf')) else ''
    sld = pdftext(p('electrical-sld.pdf'), 1) \
        if os.path.exists(p('electrical-sld.pdf')) else ''
    rep = open(p('electrical-report.md'), encoding='utf-8').read() \
        if os.path.exists(p('electrical-report.md')) else ''
    vals = {}
    for name, txt in [('panel schedule', sched), ('electrical SLD', sld)]:
        m = re.search(rx, txt)
        if m:
            vals[name] = f'{m.group(2)} A {m.group(1)} {m.group(3)}P ' \
                         f'{m.group(4)} kA'
    m = re.search(r'- Incomer: (\d+) A (MCCB|MCB|ACB) (\d)P (\S+) kA', rep)
    if m:
        vals['electrical report'] = f'{m.group(1)} A {m.group(2)} ' \
                                    f'{m.group(3)}P {m.group(4)} kA'
    if not vals:
        out.append('- 24 main incomer: N-A (no electrical panels)')
    else:
        ok = len(set(vals.values())) == 1 and len(vals) >= 2
        miss = [n for n in ('panel schedule', 'electrical SLD',
                            'electrical report') if n not in vals]
        out.append(f'- 24 main incomer (first board): '
                   f'{"PASS" if ok else "FAIL"} - '
                   + '; '.join(f'{k} {v}' for k, v in vals.items())
                   + (f' (not available: {", ".join(miss)})' if miss else ''))
    return out



# ── Fix round 3 (2026-11-13) helpers ────────────────────────────────────────
def glyph_quad(ch, page_h):
    """The printed glyph area of a pdfplumber char as a convex quad in
    pdfplumber's top-down coordinates: the advance along the baseline, from
    0.12 em below the baseline (descenders) to 0.72 em above it (cap height),
    for upright and ROTATED text alike (from the text matrix)."""
    a, b, c, d, e, f = ch['matrix']
    u = (a * a + b * b) ** 0.5 or 1.0
    ux, uy = a / u, b / u
    vx, vy = -uy, ux
    adv = (ch.get('adv') or 0.0) * u
    fs = true_size(ch)
    pts = []
    for t, sv in ((0, -0.12 * fs), (adv, -0.12 * fs), (adv, 0.72 * fs),
                  (0, 0.72 * fs)):
        x = e + ux * t + vx * sv
        y = f + uy * t + vy * sv
        pts.append((x, page_h - y))
    return pts


def circle_quad_gap(cx, cy, r, quad):
    """Distance from the circle (cx, cy, r) to the convex [quad]: negative
    when they overlap (0 = tangent)."""
    def inside(px, py):
        sgn = 0
        for i in range(4):
            x1, y1 = quad[i]
            x2, y2 = quad[(i + 1) % 4]
            cr = (x2 - x1) * (py - y1) - (y2 - y1) * (px - x1)
            if abs(cr) < 1e-12:
                continue
            s_ = 1 if cr > 0 else -1
            if sgn and s_ != sgn:
                return False
            sgn = s_
        return True
    if inside(cx, cy):
        return -r
    best = float('inf')
    for i in range(4):
        x1, y1 = quad[i]
        x2, y2 = quad[(i + 1) % 4]
        dx, dy = x2 - x1, y2 - y1
        ll = dx * dx + dy * dy
        t = 0.0 if ll == 0 else max(0.0, min(1.0, ((cx - x1) * dx +
                                                   (cy - y1) * dy) / ll))
        px, py = x1 + t * dx, y1 + t * dy
        best = min(best, ((cx - px) ** 2 + (cy - py) ** 2) ** 0.5)
    return best - r


def page_circles(pgp):
    """Distinct circles on a page (a closed curve with a square bbox)."""
    out, seen = [], set()
    for c in pgp.curves:
        w, h = c['x1'] - c['x0'], c['bottom'] - c['top']
        if not (2.5 < w < 30 and abs(w - h) < 0.8):
            continue
        cx, cy = (c['x0'] + c['x1']) / 2, (c['top'] + c['bottom']) / 2
        k = (round(cx, 1), round(cy, 1))
        if k in seen:
            continue
        seen.add(k)
        out.append((cx, cy, w / 2))
    return out


def key_circle_hits(pdf, clear=0.3):
    """Fix round 3 (S5/S6) - {page: [(key, text hit)]}: every KEY circle (a
    circle whose own text is a number) that comes within [clear] pt of the
    printed glyph of ANY other text - a pipe tag, a duct label, a fixture
    code (WC, LAV ...), a terminal label - on that page."""
    out = {}
    with pdfplumber.open(pdf) as doc:
        for i, pg in enumerate(doc.pages, 1):
            H = float(pg.height)
            chars = [ch for ch in pg.chars if ch['text'].strip()]
            quads = [glyph_quad(ch, H) for ch in chars]
            hits = []
            for cx, cy, r in page_circles(pg):
                # The key's own digits: glyphs wholly inside the circle.
                own = [k for k in range(len(chars))
                       if all((x - cx) ** 2 + (y - cy) ** 2 < r * r
                              for x, y in quads[k])]
                key = ''.join(chars[k]['text'] for k in
                              sorted(own, key=lambda k: chars[k]['x0']))
                if not re.fullmatch(r'\d{1,3}', key):
                    continue
                bad = [chars[k]['text'] for k in range(len(chars))
                       if k not in own and
                       circle_quad_gap(cx, cy, r, quads[k]) < clear]
                if bad:
                    hits.append((key, ''.join(bad)[:20]))
            if hits:
                out[i] = hits
    return out


def symbol_text_hits(pdf):
    """Fix round 3 (S1) - {page: [text]}: on a power one-line, a text run
    (consecutive glyphs on one line) that touches a symbol circle it is not
    inside, or the run of another line."""
    out = {}
    with pdfplumber.open(pdf) as doc:
        for i, pg in enumerate(doc.pages, 1):
            H = float(pg.height)
            ws = pg.extract_words(keep_blank_chars=True, x_tolerance=3)
            circles = page_circles(pg)
            bad = []
            for w in ws:
                q = [(w['x0'], w['top'] + 0.15 * (w['bottom'] - w['top'])),
                     (w['x1'], w['top'] + 0.15 * (w['bottom'] - w['top'])),
                     (w['x1'], w['bottom'] - 0.1 * (w['bottom'] - w['top'])),
                     (w['x0'], w['bottom'] - 0.1 * (w['bottom'] - w['top']))]
                for cx, cy, r in circles:
                    mx, my = (w['x0'] + w['x1']) / 2, (w['top'] + w['bottom']) / 2
                    if (mx - cx) ** 2 + (my - cy) ** 2 < r * r:
                        continue  # the symbol's own letter (G)
                    if circle_quad_gap(cx, cy, r, q) < 0.3:
                        bad.append(w['text'].strip()[:40])
                        break
            for a in range(len(ws)):
                for b2 in range(a + 1, len(ws)):
                    p_, q_ = ws[a], ws[b2]
                    ov_x = min(p_['x1'], q_['x1']) - max(p_['x0'], q_['x0'])
                    ov_y = min(p_['bottom'], q_['bottom']) - \
                        max(p_['top'], q_['top'])
                    if ov_x > 0.5 and ov_y > 0.25 * (p_['bottom'] - p_['top']):
                        bad.append(f'{p_["text"].strip()[:20]} / '
                                   f'{q_["text"].strip()[:20]}')
            if bad:
                out[i] = bad
    return out


# ── Fix round 4 (2026-11-13) helpers ────────────────────────────────────────
def _page_lines(pg):
    """Every straight stroked segment on a page: (x1, y1, x2, y2, width,
    colour) in pdfplumber's top-down coordinates (lines and rect edges)."""
    out = []
    for l in pg.lines:
        pts = l.get('pts') or [(l['x0'], l['top']), (l['x1'], l['bottom'])]
        for a, b in zip(pts, pts[1:]):
            out.append((a[0], a[1], b[0], b[1], l.get('linewidth') or 0.0,
                        l.get('stroking_color')))
    for r in pg.rects:
        if not r.get('stroke', True):
            continue
        x0, t, x1, bt = r['x0'], r['top'], r['x1'], r['bottom']
        for a, b in (((x0, t), (x1, t)), ((x1, t), (x1, bt)),
                     ((x1, bt), (x0, bt)), ((x0, bt), (x0, t))):
            out.append((a[0], a[1], b[0], b[1], r.get('linewidth') or 0.0,
                        r.get('stroking_color')))
    return out


def _grey(col):
    """The setting-out grid's chain grey (a tag may cross a grid line)."""
    return (isinstance(col, (list, tuple)) and len(col) == 3 and
            all(abs(c - 0.55) < 0.02 for c in col))


def _seg_hits_quad(x1, y1, x2, y2, q):
    """Does the segment touch the INTERIOR of the convex quad [q]?"""
    def inside(px, py):
        sg = 0
        for i in range(4):
            ax, ay = q[i]
            bx, by = q[(i + 1) % 4]
            c = (bx - ax) * (py - ay) - (by - ay) * (px - ax)
            if abs(c) < 1e-9:
                return False
            t = 1 if c > 0 else -1
            if sg and t != sg:
                return False
            sg = t
        return True
    if inside(x1, y1) or inside(x2, y2):
        return True

    def o(px, py, qx, qy, rx, ry):
        return (qx - px) * (ry - py) - (qy - py) * (rx - px)
    for i in range(4):
        ax, ay = q[i]
        bx, by = q[(i + 1) % 4]
        d1, d2 = o(ax, ay, bx, by, x1, y1), o(ax, ay, bx, by, x2, y2)
        d3, d4 = o(x1, y1, x2, y2, ax, ay), o(x1, y1, x2, y2, bx, by)
        if (d1 > 1e-9) != (d2 > 1e-9) and (d3 > 1e-9) != (d4 > 1e-9) and \
                min(abs(d1), abs(d2), abs(d3), abs(d4)) > 1e-9:
            return True
    return False


def _shrunk(q, f=0.1):
    """[q] shrunk about its centre by [f] (a tangent touch is not a hit)."""
    cx = sum(p[0] for p in q) / 4
    cy = sum(p[1] for p in q) / 4
    return [(cx + (x - cx) * (1 - f), cy + (y - cy) * (1 - f)) for x, y in q]


def _seg_point_dist(px, py, x1, y1, x2, y2):
    dx, dy = x2 - x1, y2 - y1
    ll = dx * dx + dy * dy
    t = 0.0 if ll == 0 else max(0.0, min(1.0, ((px - x1) * dx +
                                               (py - y1) * dy) / ll))
    return ((px - x1 - t * dx) ** 2 + (py - y1 - t * dy) ** 2) ** 0.5


def _circle_marks(pg, chars, quads):
    """[(cx, cy, r, mark, own char indices)] for every circle on the page
    holding a KEY number (digits) or a DETAIL bubble letter (capitals)."""
    out = []
    for cx, cy, r in page_circles(pg):
        own = [k for k in range(len(chars))
               if all((x - cx) ** 2 + (y - cy) ** 2 < r * r
                      for x, y in quads[k])]
        mark = ''.join(chars[k]['text'] for k in
                       sorted(own, key=lambda k: chars[k]['x0']))
        if re.fullmatch(r'\d{1,3}|[A-Z]{1,2}', mark):
            out.append((cx, cy, r, mark, set(own)))
    return out


def _leaders(lines, marks):
    """The leaders of [marks]: a straight line with one end ON the circle
    (within 0.6 pt of its perimeter), the other outside it, running
    radially (its extension passes within 0.3 r of the centre)."""
    out = []
    for (x1, y1, x2, y2, w, col) in lines:
        if _grey(col):
            continue
        for cx, cy, r, mark, own in marks:
            d1 = ((x1 - cx) ** 2 + (y1 - cy) ** 2) ** 0.5
            d2 = ((x2 - cx) ** 2 + (y2 - cy) ** 2) ** 0.5
            if not ((abs(d1 - r) < 0.6 and d2 > r + 0.5) or
                    (abs(d2 - r) < 0.6 and d1 > r + 0.5)):
                continue
            ll = ((x2 - x1) ** 2 + (y2 - y1) ** 2) ** 0.5
            if ll < 1e-6:
                continue
            perp = abs((x2 - x1) * (y1 - cy) - (y2 - y1) * (x1 - cx)) / ll
            if perp < 0.3 * r:
                out.append(((x1, y1, x2, y2), mark, own))
                break
    return out


def leader_text_hits(pdf):
    """Fix round 4 (R1) - {page: [(mark, text hit)]}: a KEY or DETAIL-bubble
    leader that runs through the printed glyph of any text (a tag, a detail
    caption, an UP/DN mark, another key's number)."""
    out = {}
    with pdfplumber.open(pdf) as doc:
        for i, pg in enumerate(doc.pages, 1):
            H = float(pg.height)
            chars = [ch for ch in pg.chars if ch['text'].strip()]
            quads = [glyph_quad(ch, H) for ch in chars]
            marks = _circle_marks(pg, chars, quads)
            hits = []
            for (x1, y1, x2, y2), mark, own in _leaders(_page_lines(pg), marks):
                bx0, bx1 = min(x1, x2), max(x1, x2)
                by0, by1 = min(y1, y2), max(y1, y2)
                bad = []
                for k, q in enumerate(quads):
                    if k in own:
                        continue
                    if max(p[0] for p in q) < bx0 or min(p[0] for p in q) > bx1 \
                            or max(p[1] for p in q) < by0 or \
                            min(p[1] for p in q) > by1:
                        continue
                    if _seg_hits_quad(x1, y1, x2, y2, _shrunk(q)):
                        bad.append(chars[k]['text'])
                if bad:
                    hits.append((mark, ''.join(bad)[:20]))
            if hits:
                out[i] = hits
    return out


def riser_key_symbol_hits(pdf, clear=0.3):
    """Fix round 4 (R2) - {page: [(key, n strokes)]}: on a riser sheet, a KEY
    circle within [clear] pt of a drawn SYMBOL - a closed glyph of thin
    strokes (a tank, a pump's impeller, a fixture triangle, a valve body), a
    junction box or a symbol circle (a pump / fan body). Pipes (the heavier
    strokes), open marks (flow chevrons) and its own leader are not symbols."""
    out = {}
    with pdfplumber.open(pdf) as doc:
        for i, pg in enumerate(doc.pages, 1):
            H = float(pg.height)
            chars = [ch for ch in pg.chars if ch['text'].strip()]
            quads = [glyph_quad(ch, H) for ch in chars]
            keys = [m for m in _circle_marks(pg, chars, quads)
                    if m[3].isdigit()]
            if not keys:
                continue
            lines = _page_lines(pg)
            # Pipes are the heaviest strokes on a riser; symbols, leaders,
            # chevrons and rules are drawn lighter.
            thin = 0.85 * max([l[4] for l in lines] or [0.0])
            # Closed shapes of thin strokes: a connected component with at
            # least as many strokes as distinct end points holds a cycle.
            tl = [l for l in lines if l[4] <= thin and not _grey(l[5])]
            parent = {}

            def find(a):
                while parent.setdefault(a, a) != a:
                    parent[a] = parent[parent[a]]
                    a = parent[a]
                return a

            def pt(x, y):
                return (round(x * 10), round(y * 10))
            for (x1, y1, x2, y2, _, _) in tl:
                ra, rb = find(pt(x1, y1)), find(pt(x2, y2))
                if ra != rb:
                    parent[ra] = rb
            n_edges, n_nodes = defaultdict(int), defaultdict(set)
            for (x1, y1, x2, y2, _, _) in tl:
                root = find(pt(x1, y1))
                n_edges[root] += 1
                n_nodes[root] |= {pt(x1, y1), pt(x2, y2)}
            sym = [l for l in tl
                   if n_edges[find(pt(l[0], l[1]))] >=
                   len(n_nodes[find(pt(l[0], l[1]))])]
            key_centres = {(round(k[0], 1), round(k[1], 1)) for k in keys}
            circles = [c for c in page_circles(pg)
                       if (round(c[0], 1), round(c[1], 1)) not in key_centres
                       and c[2] <= 15]
            hits = []
            for cx, cy, r, mark, _ in keys:
                n = 0
                for (x1, y1, x2, y2, _, _) in sym:
                    d1 = ((x1 - cx) ** 2 + (y1 - cy) ** 2) ** 0.5
                    d2 = ((x2 - cx) ** 2 + (y2 - cy) ** 2) ** 0.5
                    ll = ((x2 - x1) ** 2 + (y2 - y1) ** 2) ** 0.5
                    radial = ll > 1e-6 and abs(
                        (x2 - x1) * (y1 - cy) - (y2 - y1) * (x1 - cx)) / ll \
                        < 0.3 * r
                    if radial and min(abs(d1 - r), abs(d2 - r)) < 0.6:
                        continue  # its own leader, ending on the circle
                    if _seg_point_dist(cx, cy, x1, y1, x2, y2) - r < clear:
                        n += 1
                for ox, oy, orr in circles:
                    d = ((ox - cx) ** 2 + (oy - cy) ** 2) ** 0.5
                    if d - r - orr < clear and d + orr > r and d + r > orr:
                        n += 1
                if n:
                    hits.append((mark, n))
            if hits:
                out[i] = hits
    return out


def foreign_line_tag_hits(pdf):
    """Fix round 4 (R3) - {page: [text]}: on a plan / detail sheet, a printed
    glyph (a pipe / duct tag, an UP/DN mark, a key number) crossed by a
    straight stroke - another run, its flow chevron, a leader. Measured on
    the glyph quads (Helvetica advance, rotated text included); a tag may
    still cross a setting-out GRID line (grey chain), and a tangent touch
    is forgiven."""
    out = {}
    with pdfplumber.open(pdf) as doc:
        for i, pg in enumerate(doc.pages, 1):
            H = float(pg.height)
            lines = [l for l in _page_lines(pg) if not _grey(l[5])]
            cell = 24.0
            grid = defaultdict(list)
            for l in lines:
                x1, y1, x2, y2 = l[:4]
                for gx in range(int(min(x1, x2) // cell),
                                int(max(x1, x2) // cell) + 1):
                    for gy in range(int(min(y1, y2) // cell),
                                    int(max(y1, y2) // cell) + 1):
                        grid[(gx, gy)].append(l)
            bad = []
            for ch in pg.chars:
                if not ch['text'].strip():
                    continue
                q = _shrunk(glyph_quad(ch, H))
                xs, ys = [p[0] for p in q], [p[1] for p in q]
                seen = set()
                hit = False
                for gx in range(int(min(xs) // cell), int(max(xs) // cell) + 1):
                    for gy in range(int(min(ys) // cell),
                                    int(max(ys) // cell) + 1):
                        for l in grid.get((gx, gy), ()):
                            if id(l) in seen:
                                continue
                            seen.add(id(l))
                            if _seg_hits_quad(*l[:4], q):
                                hit = True
                                break
                        if hit:
                            break
                    if hit:
                        break
                if hit:
                    bad.append(ch['text'])
            if bad:
                out[i] = bad
    return out


# ── Fix round 5 (2026-11-14) helpers ────────────────────────────────────────
# Key leader caps, x the key number's own text height: the riser's
# kMechRiserKeyLeaderCapLabelHeights and the plan's
# kPlanKeyTagLeaderReachFactor (a detail bubble is measured in its letter).
RISER_KEY_LEADER_CAP = 10.0
PLAN_KEY_LEADER_CAP = 12.0


def _segs_cross(a, b):
    """Proper crossing of two segments (shared ends / touches excluded)."""
    (x1, y1, x2, y2), (x3, y3, x4, y4) = a, b

    def o(px, py, qx, qy, rx, ry):
        return (qx - px) * (ry - py) - (qy - py) * (rx - px)
    d1, d2 = o(x3, y3, x4, y4, x1, y1), o(x3, y3, x4, y4, x2, y2)
    d3, d4 = o(x1, y1, x2, y2, x3, y3), o(x1, y1, x2, y2, x4, y4)
    e = 1e-6
    return ((d1 > e and d2 < -e) or (d1 < -e and d2 > e)) and \
        ((d3 > e and d4 < -e) or (d3 < -e and d4 > e))


def key_leader_hits(pdf, cap):
    """Fix round 5 (item 8) - {page: [message]}: a KEY / DETAIL-bubble leader
    longer than [cap] x its mark's text height, two such leaders crossing,
    or one passing through ANOTHER key / bubble circle."""
    out = {}
    with pdfplumber.open(pdf) as doc:
        for i, pg in enumerate(doc.pages, 1):
            H = float(pg.height)
            chars = [ch for ch in pg.chars if ch['text'].strip()]
            quads = [glyph_quad(ch, H) for ch in chars]
            marks = _circle_marks(pg, chars, quads)
            size = {}
            for cx, cy, r, mark, own in marks:
                size[(round(cx, 1), round(cy, 1))] = max(
                    [true_size(chars[k]) for k in own] or [0.0])
            leads = []
            for (seg, mark, own) in _leaders(_page_lines(pg), marks):
                # The mark this leader ends on.
                m = min(marks, key=lambda c: min(
                    abs(((seg[0] - c[0]) ** 2 + (seg[1] - c[1]) ** 2) ** 0.5
                        - c[2]),
                    abs(((seg[2] - c[0]) ** 2 + (seg[3] - c[1]) ** 2) ** 0.5
                        - c[2])))
                leads.append((seg, m))
            bad = []
            for seg, m in leads:
                ll = ((seg[2] - seg[0]) ** 2 + (seg[3] - seg[1]) ** 2) ** 0.5
                ts = size.get((round(m[0], 1), round(m[1], 1)), 0.0)
                if ts > 0 and ll > cap * ts + 0.5:
                    bad.append(f'{m[3]} leader {ll / ts:.1f} text heights')
                for c in marks:
                    if c is m:
                        continue
                    if _seg_point_dist(c[0], c[1], *seg) < c[2] - 0.3:
                        bad.append(f'{m[3]} leader through circle {c[3]}')
            for a in range(len(leads)):
                for b in range(a + 1, len(leads)):
                    if _segs_cross(leads[a][0], leads[b][0]):
                        bad.append(f'{leads[a][1][3]} / {leads[b][1][3]} '
                                   'leaders cross')
            if bad:
                out[i] = bad
    return out


def red_strokes(pgp):
    """Stroked linework in the essential (red) ink on a page."""
    def red(col):
        return (col is not None and isinstance(col, (list, tuple))
                and len(col) == 3 and col[0] > 0.6 and col[1] < 0.3
                and col[2] < 0.3)
    return [g for g in list(pgp.lines) + list(pgp.rects) + list(pgp.curves)
            if red(g.get('stroking_color'))]


def red_text_lines(pgp):
    rows = defaultdict(list)
    for c in pgp.chars:
        col = c.get('non_stroking_color')
        if col and isinstance(col, (list, tuple)) and len(col) == 3 and \
                col[0] > 0.6 and col[1] < 0.3:
            rows[round(c['top'])].append(c)
    return [''.join(c['text'] for c in sorted(v, key=lambda q: q['x0']))
            for _, v in sorted(rows.items())]

def run_building(root, b):
    bdir = os.path.join(root, b)
    cover = glob.glob(os.path.join(bdir, '*-00-cover-sheets.pdf'))
    if not cover:
        return None
    project = os.path.basename(cover[0])[:-len('-00-cover-sheets.pdf')]
    pdfs = sorted(f for f in glob.glob(os.path.join(bdir, '*.pdf'))
                  if not f.endswith(REPORT_SUFFIXES))
    dl = parse_drawing_list(cover[0])

    # Per-page facts.
    pages = []  # dict per page
    for pdf in pdfs:
        st = stem_of(pdf)
        words = page_words(pdf)
        for (n, w, h, ws) in words:
            text = pdftext(pdf, n)
            tb = title_block(text)
            pages.append(dict(pdf=pdf, stem=st, page=n, w=w, h=h, words=ws,
                              text=text, tb=tb, paper=paper(w, h)))

    # Order: cover, then the drawing-list order, then anything else.
    num_first = {}
    for pg in pages:
        nr = (pg['tb'] or {}).get('DWG NO')
        if nr and nr not in num_first:
            num_first.setdefault(nr, pg['stem'])
    rank = {}
    rank[stem_of(cover[0])] = -1
    for i, r in enumerate(dl):
        st = num_first.get(r['number'])
        if st and st not in rank:
            rank[st] = i
    pages.sort(key=lambda pg: (rank.get(pg['stem'], 999), pg['stem'],
                               pg['page']))
    ordered = [(pg['stem'], pg['page']) for pg in pages]

    pngs = rasterise(bdir, pdfs)
    where = contact_sheets(bdir, ordered, pngs, project)

    # Distinct plan types.
    sig_seen = {}
    for pg in pages:
        m = re.search(r'-(elec-)?plan-\d+-(.+)$', pg['stem'])
        if not m:
            pg['type'] = 'distinct'
            continue
        sig = (m.group(1) or '') + plan_signature(pg['text'], m.group(2))
        if sig in sig_seen:
            pg['type'] = f'repeat of {short(sig_seen[sig], project)}'
        else:
            sig_seen[sig] = pg['stem']
            pg['type'] = 'distinct'

    lines = [f'# Pre-check - {project} ({b})', '',
             'Scripted by tool/ref_drawings_precheck.py; one line per sheet '
             'per item. Visual items (4, 8-22) are NOT scripted - review the '
             'PNGs.', '']
    counts = Counter()

    def emit(item, verdict, label, ev):
        counts[verdict] += 1
        lines.append(f'- [{verdict}] item {item} | {label} | {ev}')

    # 2/23 — numbers unique per drawing + list agreement.
    by_num = defaultdict(set)
    for pg in pages:
        nr = (pg['tb'] or {}).get('DWG NO')
        if nr:
            by_num[nr].add(pg['stem'])
    listed = {r['number']: r for r in dl}
    lines.append('## Items 2 / 23 - drawing numbers and the Daftar Gambar')
    for nr, stems in sorted(by_num.items()):
        lab = ', '.join(short(s, project) for s in sorted(stems))
        if len(stems) > 1:
            emit(2, 'FAIL', nr, f'number used by {len(stems)} drawings: {lab}')
        else:
            emit(2, 'PASS', nr, f'unique ({lab})')
    for pg in pages:
        # The front matter is three DISTINCT drawings (G-001..G-003, the
        # register may continue on further G-002 pages): every page of the
        # cover file is checked; any other file by its first page.
        is_cover = pg['stem'] == stem_of(cover[0])
        if pg['page'] != 1 and not is_cover:
            continue
        lab = short(pg['stem'], project)
        if is_cover:
            lab += f' p{pg["page"]}'
        tb = pg['tb'] or {}
        nr = tb.get('DWG NO')
        if not nr:
            emit(23, 'FAIL', lab, 'no drawing number on the sheet, so it '
                 'cannot be on the drawing list')
            continue
        r = listed.get(nr)
        if not r:
            emit(23, 'FAIL', lab, f'{nr} not on the Daftar Gambar')
        elif norm_title(r['title']) != norm_title(tb.get('TITLE')):
            emit(23, 'FAIL', lab, f'{nr} list title "{r["title"]}" vs '
                 f'title block "{tb.get("TITLE")}"')
        elif r['rev'] != (tb.get('REV') or ''):
            emit(23, 'FAIL', lab, f'{nr} list rev {r["rev"]} vs sheet '
                 f'{tb.get("REV")}')
        else:
            emit(23, 'PASS', lab, f'{nr} listed as "{r["title"]}"')
    for r in dl:
        if r['number'] not in by_num:
            emit(23, 'FAIL', r['number'], f'listed ("{r["title"]}") but no '
                 'issued sheet carries it')
    # Drawing review R1 - every DETAIL callout on a plan names an issued
    # detail sheet (a plan never points at a drawing the set lacks).
    for pg in pages:
        refs = sorted(set(re.findall(r'DETAIL [A-Z]+ - LIHAT (\S+)',
                                     pg['text'].replace('\n', ' '))))
        if not refs:
            continue
        lab = f'{short(pg["stem"], project)} p{pg["page"]}'
        missing = [r for r in refs if r not in by_num]
        if missing:
            emit(23, 'FAIL', lab, f'detail callout points at {missing}, '
                 'not issued')
        else:
            emit(23, 'PASS', lab, f'detail callouts -> {", ".join(refs)} '
                 'issued')
    # Order: within each series prefix + hundred, numbers ascend.
    seq = [r['number'] for r in dl]
    bad = [f'{a} before {c}' for a, c in zip(seq, seq[1:])
           if a[0] == c[0] and a[2] == c[2] and a > c]
    emit(23, 'FAIL' if bad else 'PASS', 'list order',
         ('; '.join(bad)) if bad else ' -> '.join(seq))

    # 1/3 — title block.
    lines += ['', '## Items 1 / 3 - title block fields']
    for pg in pages:
        lab = f'{short(pg["stem"], project)} p{pg["page"]}'
        tb = pg['tb']
        if tb is None:
            emit('1/3', 'FAIL', lab, 'no title block (no PROJECT/.../SHEET '
                 'block in the page text)')
            continue
        need = list(TB_LABELS)
        empty = [k for k in need if not (tb.get(k) or '').strip()]
        sm = re.match(r'^(\d+) of (\d+)$', tb.get('SHEET') or '')
        if sm and not (1 <= int(sm.group(1)) <= int(sm.group(2))):
            empty.append('SHEET(i>n)')
        if sm is None and 'SHEET' not in empty:
            empty.append('SHEET(format)')
        ev = '; '.join(f'{k}={tb.get(k)!s}' for k in
                       ('DWG NO', 'REV', 'SCALE', 'SHEET'))
        if empty:
            emit('1/3', 'FAIL', lab, f'missing/empty: {", ".join(empty)} '
                 f'({ev})')
        else:
            emit('1/3', 'PASS', lab, ev)

    # 5 — smallest text.
    lines += ['', f'## Item 5 - smallest text (FAIL < {MIN_PT:g} pt at the '
              'issued paper size)']
    for pg in pages:
        lab = f'{short(pg["stem"], project)} p{pg["page"]} ({pg["paper"]})'
        if not pg['words']:
            emit(5, 'N-A', lab, 'no text')
            continue
        mn = min(s for _, s in pg['words'])
        # Fix round F3 - a sheet stamping the legibility warning is a
        # mark-up on an issued sheet: FAIL it whatever the measured size.
        st = re.search(r'PERHATIAN:\s*label tercetak\s*([\d.]+)\s*pt',
                       pg['text'].replace('\n', ' '))
        if st:
            emit(5, 'FAIL', lab, f'sheet stamps the legibility warning '
                 f'"label tercetak {st.group(1)} pt" (min {mn:.2f} pt)')
            continue
        small = sorted({(round(s, 2), -len(t), t) for t, s in pg['words']
                        if s < MIN_PT - 1e-6})
        if small:
            ex = ', '.join(f'"{t}" {s:g}pt' for s, _, t in small[:5])
            emit(5, 'FAIL', lab, f'min {mn:.2f} pt; {len(small)} strings '
                 f'below: {ex}')
        else:
            emit(5, 'PASS', lab, f'min {mn:.2f} pt')

    # 6 — stamped overlap warning.
    lines += ['', '## Item 6 - stamped label-overlap warning (exporter count)']
    kt_hits = {}
    for pdf in pdfs:
        if re.search(r'-plan-', stem_of(pdf)):
            for n, h in key_table_hits(pdf).items():
                kt_hits[(stem_of(pdf), n)] = h
    for pg in pages:
        lab = f'{short(pg["stem"], project)} p{pg["page"]}'
        m = re.search(r'PERHATIAN:\s*(\d+)\s*label bertumpuk',
                      pg['text'].replace('\n', ' '))
        kh = kt_hits.get((pg['stem'], pg['page']))
        if kh:
            # Fix round F4 - a pipe-key table touching the drawing is an
            # overlap whatever the exporter counted.
            emit(6, 'FAIL', lab, f'{len(kh)} pipe-key table(s) touched by '
                 'drawing text: ' + ', '.join(f'"{x}"' for x in kh[:6]))
        elif m:
            emit(6, 'FAIL', lab, f'sheet stamps {m.group(1)} overlapping '
                 'labels')
        elif re.search(r'-(elec-)?plan-', pg['stem']):
            # Plans and their DETAIL sheets (`plan-N-<floor>-detail`, a split
            # plan's further sheets `-detail-2`...) keep the overlap counter.
            kind = ('detail sheet' if re.search(r'-detail(-\d+)?$', pg['stem'])
                    else 'plan')
            emit(6, 'PASS', lab, f'{kind}: no overlap warning stamped '
                 '(count 0); visual check still due')
        else:
            emit(6, 'N-A', lab, 'exporter keeps no overlap counter for this '
                 'sheet type; visual check')

    # 14 (scripted part, backlog C-1) - on a mechanical plan / detail sheet
    # of a floor named "Lantai N", every run tag's level code is LN (the tag
    # names the floor the sheet is titled for, never the index one below).
    lines += ['', '## Item 14 - run-tag level code matches the sheet\'s '
              '"Lantai N" (scripted part)']
    tag_re = re.compile(r'(?<![A-Z0-9])([A-Z]{1,3})-(L\d+|GF|B\d+|RF)(?![0-9A-Za-z])')
    for pg in pages:
        m = re.search(r'(?<!elec)-plan-\d+-Lantai\s*(\d+)(-detail(-\d+)?)?$',
                      pg['stem'])
        if not m:
            continue
        lab = f'{short(pg["stem"], project)} p{pg["page"]}'
        want = f'L{int(m.group(1))}'
        tags = tag_re.findall(pg['text'])
        if not tags:
            emit(14, 'N-A', lab, 'no run tag printed')
            continue
        bad = sorted({f'{c}-{lv}' for c, lv in tags if lv != want})
        if bad:
            emit(14, 'FAIL', lab, f'{len(bad)} tag(s) not {want}: '
                 + ', '.join(bad[:6]))
        else:
            emit(14, 'PASS', lab, f'{len(tags)} run tags all -{want}')

    # 4 (scripted part) — legend text stays inside its LEGEND box: on every
    # page, the smallest stroked rect around a "LEGEND" / "LEGENDA" heading is
    # the box; a text run that starts inside it must end inside it (a run =
    # consecutive glyphs on one baseline, gaps < 6 pt). FAIL otherwise.
    lines += ['', '## Item 4 - legend text inside its LEGEND box (scripted '
              'part; the rest of item 4 is visual)']
    for pdf in pdfs:
        st = stem_of(pdf)
        with pdfplumber.open(pdf) as doc:
            for n, pgp in enumerate(doc.pages, 1):
                heads = [w for w in pgp.extract_words()
                         if w['text'] in ('LEGEND', 'LEGENDA')]
                if not heads:
                    continue
                lab = f'{short(st, project)} p{n}'
                rects = [r for r in pgp.rects
                         if r['width'] > 20 and r['height'] > 10]
                bad, checked = [], 0
                for h in heads:
                    cx = (h['x0'] + h['x1']) / 2
                    cy = (h['top'] + h['bottom']) / 2
                    box = [r for r in rects if r['x0'] <= cx <= r['x1']
                           and r['top'] <= cy <= r['bottom']]
                    if not box:
                        continue
                    r = min(box, key=lambda q: q['width'] * q['height'])
                    checked += 1
                    rows = defaultdict(list)
                    for ch in pgp.chars:
                        my = (ch['top'] + ch['bottom']) / 2
                        if r['top'] <= my <= r['bottom']:
                            rows[round(ch['top'], 0)].append(ch)
                    for _, chs in rows.items():
                        chs.sort(key=lambda c: c['x0'])
                        run, inside = [], False
                        for ch in chs:
                            if run and ch['x0'] - run[-1]['x1'] > 6:
                                if inside and run[-1]['x1'] > r['x1'] + 0.5:
                                    bad.append(''.join(c['text'] for c in run))
                                run, inside = [], False
                            if not run:
                                inside = r['x0'] - 0.5 <= ch['x0'] <= r['x1']
                            run.append(ch)
                        if run and inside and run[-1]['x1'] > r['x1'] + 0.5:
                            bad.append(''.join(c['text'] for c in run))
                if not checked:
                    continue
                if bad:
                    emit(4, 'FAIL', lab, f'{len(bad)} legend line(s) run out '
                         'of the LEGEND box: ' + '; '.join(
                             f'"{b[:70]}"' for b in bad[:3]))
                else:
                    emit(4, 'PASS', lab, 'legend text inside its box')

    # 9 (scripted part, backlog I-4) — a legend never keys a code the sheet
    # does not print: on every page carrying a LEGEND box, each one-token
    # code (`CW`, `PRV`, `NYM`, `TX`...) must appear in the page text outside
    # the legend; a riser-tag example (`CW-R3`) needs any `CW-R<n>`. Line-
    # style classes (Normal / Essential / Source / Earth / Board) are keyed by
    # colour and gated in the engine; multi-word codes are skipped.
    lines += ['', '## Item 9 - every legend code is printed on its sheet '
              '(scripted part)']
    style = {'Normal', 'Essential', 'Source', 'Earth', 'Board'}
    for pg in pages:
        tl = pg['text'].splitlines()
        idx, on = [], False
        for i, l in enumerate(tl):
            st = l.strip()
            if st in ('LEGEND', 'LEGENDA'):
                on = True
                continue
            if on:
                if not st or st.startswith(tuple(TB_LABELS)) or \
                        st.startswith('CLIENT'):
                    on = False
                    continue
                idx.append(i)
        if not idx:
            continue
        lab = f'{short(pg["stem"], project)} p{pg["page"]}'
        sidx = set(idx)
        body = '\n'.join(l for i, l in enumerate(tl) if i not in sidx)
        missing = []
        for i in idx:
            l = tl[i].strip()
            if ' - ' not in l:
                continue
            code = l.split(' - ')[0].strip()
            if not code or ' ' in code or code in style:
                continue
            if re.fullmatch(r'[A-Z]+-R\d+', code):
                pat = re.escape(code.split('-')[0]) + r'-R\d+'
            else:
                pat = r'(?<![A-Za-z])' + re.escape(code) + r'(?![A-Za-z])'
            if not re.search(pat, body):
                missing.append(code)
        if missing:
            emit(9, 'FAIL', lab, 'legend keys code(s) the sheet does not '
                 'print: ' + ', '.join(missing))
        else:
            emit(9, 'PASS', lab, 'every legend code printed on the sheet')

    # 6 (scripted part, backlog I-4) — the supply-capacity note (DEMAND >
    # DECLARED ... SUBSCRIBED DAYA) and the drainage terminus note (KE
    # SALURAN PEMBUANGAN) are never struck by a line: no stroked segment
    # crosses one of their words (the word box shrunk by a hairline).
    lines += ['', '## Item 6 - supply / drainage notes clear of linework '
              '(scripted part)']
    note_words = {'DEMAND', 'DECLARED', 'SUBSCRIBED', 'SALURAN', 'PEMBUANGAN'}

    def seg_hits(a, b, box):
        (x1, y1), (x2, y2) = a, b
        bx0, by0, bx1, by1 = box
        t0, t1 = 0.0, 1.0
        dx, dy = x2 - x1, y2 - y1
        for pp, q in ((-dx, x1 - bx0), (dx, bx1 - x1), (-dy, y1 - by0),
                      (dy, by1 - y1)):
            if pp == 0:
                if q < 0:
                    return False
                continue
            t = q / pp
            if pp < 0:
                if t > t1:
                    return False
                t0 = max(t0, t)
            else:
                if t < t0:
                    return False
                t1 = min(t1, t)
        return t0 < t1

    for pdf in pdfs:
        st = stem_of(pdf)
        if not re.search(r'-(riser-sld|electrical-[a-z-]+)$', st):
            continue
        with pdfplumber.open(pdf) as doc:
            for n, pgp in enumerate(doc.pages, 1):
                ws = [w for w in pgp.extract_words()
                      if w['text'] in note_words]
                if not ws:
                    continue
                segs = []
                for l in pgp.lines:
                    pts = l.get('pts') or [(l['x0'], l['top']),
                                           (l['x1'], l['bottom'])]
                    segs += list(zip(pts, pts[1:]))
                for c in pgp.curves:
                    pts = c.get('pts') or []
                    segs += list(zip(pts, pts[1:]))
                for r in pgp.rects:
                    x0, t, x1, b = r['x0'], r['top'], r['x1'], r['bottom']
                    q = [(x0, t), (x1, t), (x1, b), (x0, b), (x0, t)]
                    segs += list(zip(q, q[1:]))
                hit = sorted({w['text'] for w in ws if any(
                    seg_hits(a, b, (w['x0'] + 0.4, w['top'] + 0.8,
                                    w['x1'] - 0.4, w['bottom'] - 0.8))
                    for a, b in segs)})
                lab = f'{short(st, project)} p{n}'
                if hit:
                    emit(6, 'FAIL', lab, 'note struck by a line: '
                         + ', '.join(hit))
                else:
                    emit(6, 'PASS', lab, 'supply / drainage note clear of '
                         'linework')

    # 23 (scripted part, backlog I-4) — no orphan schedule page: the last
    # page of a multi-page equipment schedule carries at least three body
    # lines (a table never strands its last row or two, nor a footnote tail).
    lines += ['', '## Item 23 - no orphan schedule page (scripted part)']
    for pdf in pdfs:
        st = stem_of(pdf)
        if not st.endswith('-equipment-schedule'):
            continue
        sp = sorted((q for q in pages if q['pdf'] == pdf),
                    key=lambda q: q['page'])
        if len(sp) < 2:
            continue
        last = sp[-1]
        body = [l.strip() for l in last['text'].splitlines()
                if l.strip() and not l.strip().startswith(tuple(TB_LABELS))
                and not re.search(r'Page \d+ of \d+$', l.strip())
                and not l.strip().startswith(('Tag ', 'CLIENT'))]
        lab = f'{short(st, project)} p{last["page"]}'
        if len(body) < 3:
            emit(23, 'FAIL', lab, f'orphan page: {len(body)} body line(s) '
                 + '; '.join(f'"{b[:40]}"' for b in body))
        else:
            emit(23, 'PASS', lab, f'{len(body)} body lines on the last page')


    # ── Fix round 3 (2026-11-13) ─────────────────────────────────────────
    # S1 (item 6) - on the power one-line every caption is clear of every
    # symbol and of every other caption.
    lines += ['', '## Item 6 - power one-line captions clear of symbols and '
              'of each other (scripted part)']
    for pdf in pdfs:
        st = stem_of(pdf)
        if not st.endswith('-electrical-power-one-line'):
            continue
        hits = symbol_text_hits(pdf)
        with pdfplumber.open(pdf) as doc:
            n_pages = len(doc.pages)
        for n in range(1, n_pages + 1):
            lab = f'{short(st, project)} p{n}'
            h = hits.get(n)
            if h:
                emit(6, 'FAIL', lab, f'{len(h)} caption(s) touch a symbol or '
                     'another caption: ' + '; '.join(f'"{x}"' for x in h[:4]))
            else:
                emit(6, 'PASS', lab, 'captions clear of symbols and each other')

    # S5 / S6 (item 6) - a KEY circle never touches any text (pipe tag, duct
    # label, fixture / terminal code) on a plan, detail or riser sheet.
    lines += ['', '## Item 6 - key circles clear of every text (scripted part)']
    for pdf in pdfs:
        st = stem_of(pdf)
        if not re.search(r'-(plan-\d+-.+|riser-sld)$', st) or \
                re.search(r'-elec-plan-', st):
            continue
        hits = key_circle_hits(pdf)
        with pdfplumber.open(pdf) as doc:
            n_pages = len(doc.pages)
        for n in range(1, n_pages + 1):
            lab = f'{short(st, project)} p{n}'
            h = hits.get(n)
            if h:
                emit(6, 'FAIL', lab, f'{len(h)} key circle(s) on text: ' +
                     ', '.join(f'key {k} on "{t}"' for k, t in h[:6]))
            else:
                emit(6, 'PASS', lab, 'every key circle clear of text')

    # ── Fix round 4 (2026-11-13) ─────────────────────────────────────────
    # R1 (item 6) - a key / detail-bubble leader never runs through text.
    lines += ['', '## Item 6 - key and detail-bubble leaders clear of every '
              'text (scripted part)']
    for pdf in pdfs:
        st = stem_of(pdf)
        if not re.search(r'-(plan-\d+-.+|riser-sld)$', st) or \
                re.search(r'-elec-plan-', st):
            continue
        hits = leader_text_hits(pdf)
        with pdfplumber.open(pdf) as doc:
            n_pages = len(doc.pages)
        for n in range(1, n_pages + 1):
            lab = f'{short(st, project)} p{n}'
            h = hits.get(n)
            if h:
                emit(6, 'FAIL', lab, f'{len(h)} leader(s) through text: ' +
                     ', '.join(f'{m} through "{t}"' for m, t in h[:6]))
            else:
                emit(6, 'PASS', lab, 'every key / bubble leader clear of text')

    # ── Fix round 5 (2026-11-14) ─────────────────────────────────────────
    # Item 8 - key / bubble leaders are short (capped), cross no other key
    # leader and pass through no other key circle (plans, details, risers).
    lines += ['', '## Item 8 - key leaders capped, uncrossed, clear of other '
              'key circles (scripted part)']
    for pdf in pdfs:
        st = stem_of(pdf)
        riser = st.endswith('-riser-sld')
        if not (riser or re.search(r'-plan-\d+-.+$', st)) or \
                re.search(r'-elec-plan-', st):
            continue
        hits = key_leader_hits(
            pdf, RISER_KEY_LEADER_CAP if riser else PLAN_KEY_LEADER_CAP)
        with pdfplumber.open(pdf) as doc:
            n_pages = len(doc.pages)
        for n in range(1, n_pages + 1):
            lab = f'{short(st, project)} p{n}'
            h = hits.get(n)
            if h:
                emit(8, 'FAIL', lab, f'{len(h)} key leader fault(s): ' +
                     '; '.join(h[:6]))
            else:
                emit(8, 'PASS', lab, 'key leaders capped, uncrossed, clear')

    # R2 (item 6) - a riser key circle never sits on (or tight to) a symbol.
    lines += ['', '## Item 6 - riser key circles clear of every symbol '
              '(scripted part)']
    for pdf in pdfs:
        st = stem_of(pdf)
        if not st.endswith('-riser-sld'):
            continue
        hits = riser_key_symbol_hits(pdf)
        with pdfplumber.open(pdf) as doc:
            n_pages = len(doc.pages)
        for n in range(1, n_pages + 1):
            lab = f'{short(st, project)} p{n}'
            h = hits.get(n)
            if h:
                emit(6, 'FAIL', lab, f'{len(h)} key circle(s) on a symbol: ' +
                     ', '.join(f'key {k} ({c} stroke(s))' for k, c in h[:6]))
            else:
                emit(6, 'PASS', lab, 'every key circle clear of the symbols')

    # R3 (item 6) - no foreign linework through a tag on a plan / detail.
    lines += ['', '## Item 6 - no linework through a tag on plans and details '
              '(scripted part)']
    for pdf in pdfs:
        st = stem_of(pdf)
        if not re.search(r'-plan-\d+-.+$', st) or \
                re.search(r'-elec-plan-', st):
            continue
        hits = foreign_line_tag_hits(pdf)
        with pdfplumber.open(pdf) as doc:
            n_pages = len(doc.pages)
        for n in range(1, n_pages + 1):
            lab = f'{short(st, project)} p{n}'
            h = hits.get(n)
            if h:
                emit(6, 'FAIL', lab, f'{len(h)} glyph(s) crossed by a line: "' +
                     ''.join(h)[:40] + '"')
            else:
                emit(6, 'PASS', lab, 'no stroke crosses a printed glyph')

    # S3 (item 9) - an SLD-family legend keys 'Essential' only when the page
    # draws essential (red) linework: a red NOTE is not an essential supply.
    lines += ['', '## Item 9 - SLD legend "Essential" only with essential '
              'linework drawn (E-301 / E-401 / E-501)']
    for pdf in pdfs:
        st = stem_of(pdf)
        if not re.search(r'-electrical-(overview-sld|riser|power-one-line)$',
                         st):
            continue
        with pdfplumber.open(pdf) as doc:
            for n, pgp in enumerate(doc.pages, 1):
                lab = f'{short(st, project)} p{n}'
                txt = pdftext(pdf, n)
                keyed = re.search(r'^\s*Essential - ', txt, re.M) is not None
                drawn = bool(red_strokes(pgp))
                if keyed and not drawn:
                    emit(9, 'FAIL', lab, 'legend keys "Essential" but no '
                         'essential board / feeder is drawn')
                else:
                    emit(9, 'PASS', lab, f'Essential keyed={keyed}, essential '
                         f'linework drawn={drawn}')

    # S2 (item 24) - the essential bus on E-501 prints the SAME demand as the
    # essential board on E-301 (the red board-rating line on page 1).
    lines += ['', '## Item 24 - E-501 essential bus = the essential board on '
              'E-301']
    pol = [f for f in pdfs if stem_of(f).endswith('-electrical-power-one-line')]
    ov = [f for f in pdfs if stem_of(f).endswith('-electrical-overview-sld')]
    if pol and ov:
        t5 = pdftext(pol[0]).replace('\n', ' ')
        m = re.search(r'Essential bus\s+(?:demand\s+)?([\d.]+) kVA', t5)
        if not m:
            emit(24, 'N-A', 'E-501', 'no essential bus on the power one-line')
        else:
            with pdfplumber.open(ov[0]) as doc:
                reds = red_text_lines(doc.pages[0])
            kvas = [float(x) for l in reds
                    for x in re.findall(r'kW / ([\d.]+) kVA', l)]
            want = float(m.group(1))
            ok = any(abs(k - want) < 1e-6 for k in kvas) or \
                (kvas and abs(sum(kvas) - want) < 0.051)
            basis = re.search(r'genset basis ([\d.]+) kVA', t5)
            emit(24, 'PASS' if ok else 'FAIL', 'E-501 vs E-301',
                 f'E-501 essential bus demand {want:g} kVA; E-301 essential '
                 f'board(s) {kvas}'
                 + (f'; genset basis {basis.group(1)} kVA named' if basis
                    else ''))

    # S4 (item 20) - every feeder on the electrical riser carries its tag:
    # an off-sheet feeder ("DARI (lembar lain): A > B") prints cable · device
    # · length under the mark, and the set prints at least one tag per fed
    # board.
    lines += ['', '## Item 20 - every riser feeder labelled (E-401, scripted '
              'part)']
    tag_re = re.compile(r'(NYY|NYM|FRC|N2XSY|NA2XY|N2XY|NYFGbY|BC)\S*.*'
                        r'(MCB|MCCB|ACB|FUSE|Fuse)\S* .*\d+(\.\d+)? m\b')
    for pdf in pdfs:
        st = stem_of(pdf)
        if not st.endswith('-electrical-riser'):
            continue
        sp = sorted((q for q in pages if q['pdf'] == pdf),
                    key=lambda q: q['page'])
        boards = tags = 0
        for pg in sp:
            lab = f'{short(st, project)} p{pg["page"]}'
            tl = [l.strip() for l in pg['text'].splitlines()]
            boards += sum(1 for l in tl if re.match(r'^\d+A \dP · ', l))
            # A tag wrapped at its ' · ' separators (the DARI gutter) counts
            # once: a cable line without its length joins the next line.
            cab = re.compile(r'^(NYY|NYM|FRC|N2XSY|NA2XY|N2XY|NYFGbY|BC|'
                             r'\d+x\()')
            k = 0
            while k < len(tl):
                if tag_re.search(tl[k]):
                    tags += 1
                elif cab.match(tl[k]) and k + 1 < len(tl) and \
                        tag_re.search(tl[k] + ' · ' + tl[k + 1]):
                    tags += 1
                    k += 1
                k += 1
            bad = []
            for i, l in enumerate(tl):
                if not l.startswith('DARI (lembar lain)'):
                    continue
                for k in range(i + 1, min(i + 10, len(tl))):
                    if ' > ' not in tl[k]:
                        continue
                    # The feeder tag rides the next 1-3 lines (wrapped at
                    # its ' · ' separators).
                    nxt = ' · '.join(tl[k + 1:k + 3])
                    if not tag_re.search(tl[k + 1] if k + 1 < len(tl)
                                         else '') and not tag_re.search(nxt):
                        bad.append(tl[k])
            if bad:
                emit(20, 'FAIL', lab, 'off-sheet feeder(s) without cable · '
                     'device · length: ' + ', '.join(bad))
            elif any(l.startswith('DARI (lembar lain)') for l in tl):
                emit(20, 'PASS', lab, 'off-sheet feeder(s) carry their tag')
        roots = 1
        emit(20, 'PASS' if tags >= boards - roots else 'FAIL',
             short(st, project), f'{tags} feeder tags for {boards} boards '
             f'drawn ({roots} root)')

    # O1 (item 14) - a TIPIKAL detail sheet prints no single floor's level
    # code or FFL: tags read -Ln and one note keys n.
    lines += ['', '## Item 14 - TIPIKAL detail sheets: no single-floor level '
              'code or FFL']
    for pg in pages:
        if not re.search(r'-plan-\d+-.+-detail(-\d+)?$', pg['stem']):
            continue
        flat = pg['text'].replace('\n', ' ')
        if 'TIPIKAL' not in flat:
            continue
        lab = f'{short(pg["stem"], project)} p{pg["page"]}'
        lv = sorted(set(re.findall(
            r'(?<![A-Z0-9])[A-Z]{1,3}-(?:L\d+|GF|B\d+|RF)(?![0-9A-Za-z])',
            flat)))
        bad = []
        if lv:
            bad.append('floor-specific tags ' + ', '.join(lv[:5]))
        if re.search(r'FFL [+-]\d', flat):
            bad.append('prints a single floor FFL')
        if 'TIPIKAL: n = ' not in flat:
            bad.append('no TIPIKAL n note')
        emit(14, 'FAIL' if bad else 'PASS', lab,
             '; '.join(bad) if bad else 'tags -Ln + TIPIKAL note, no FFL')

    # O2 (item 18) - every plant item on a riser PLANT page prints its duty:
    # pumps Q · H · kW, tanks a capacity or '-'; each LANJUTAN DARI mark
    # names the pipe it continues.
    lines += ['', '## Item 18 - PLANT pages: plant duty + continuation tags']
    for pg in pages:
        if not pg['stem'].endswith('-riser-sld') or ' - PLANT' not in \
                pg['text']:
            continue
        lab = f'{short(pg["stem"], project)} p{pg["page"]}'
        tl = [l.strip() for l in pg['text'].splitlines()]
        bad = []
        for l in tl:
            for m in re.finditer(r'\b((?:P|HWP)-\d+) Pump · ([^P]*?)'
                                 r'(?=(?:\s(?:P|HWP|TK)-\d+ )|$)', l):
                d = m.group(2)
                if not re.search(r'Q [\d.]+ L/s · H [\d.]+ m · [\d.]+ kW', d):
                    bad.append(f'{m.group(1)} "{d.strip()[:30]}"')
            for m in re.finditer(r'\b(TK-\d+) [A-Za-z ]*tank(?: · (\S+))?', l):
                if not m.group(2):
                    bad.append(f'{m.group(1)} no capacity')
            if l.startswith('LANJUTAN DARI') and \
                    not re.search(r'\(\S*-\S+.*\)', l):
                bad.append(f'"{l}" names no pipe')
        emit(18, 'FAIL' if bad else 'PASS', lab,
             ('; '.join(bad[:6])) if bad else 'pumps Q · H · kW, tanks '
             'capacity, continuation marks name their pipe')

    # O3 (item 22) - a standby genset on E-301 reaches the bus through the
    # transfer switch E-501 draws; and (item 23) a paginated E-301 leaves no
    # chunk page but the last with under half the boards of the fullest one.
    lines += ['', '## Items 22 / 23 - E-301 genset transfer switch; chunk '
              'pages filled']
    if ov:
        sp = sorted((q for q in pages if q['pdf'] == ov[0]),
                    key=lambda q: q['page'])
        t1 = sp[0]['text'] if sp else ''
        if pol and re.search(r'\bGENSET\b', t1):
            sw = re.search(r'\b(ATS|COS)\b', pdftext(pol[0]))
            if sw:
                ok = re.search(r'\b' + sw.group(1) + r'\b', t1) is not None
                emit(22, 'PASS' if ok else 'FAIL', 'E-301 p1',
                     f'E-501 transfers via {sw.group(1)}; E-301 '
                     + ('draws it' if ok else 'does not draw it'))
        chunk = [q for q in sp if re.search(r'LANJUT: .*\(lembar lain\)',
                                            q['text'])]
        if len(chunk) > 1:
            # Boards drawn: one per rating line, a TIPIKAL xN node counting
            # its N boards.
            def nboards(t):
                ls = [l.strip() for l in t.splitlines()]
                return (sum(1 for l in ls if re.match(r'^\d+A \dP · ', l))
                        + sum(int(m.group(1)) - 1 for l in ls for m in
                              [re.match(r'^\S+\.\.\S+ \(TIPIKAL x(\d+)\)$',
                                        l)] if m))
            cnt = [nboards(q['text']) for q in chunk]
            full = max(cnt)
            # The page carrying the source spine (supply head, transformer,
            # genset) is width-bound by the spine: it is filled first-fit and
            # judged on the pages without it.
            def spine(q):
                return re.search(r'\b(PLN|GENSET|TRANSFORMER)\b',
                                 q['text']) is not None
            free = [c for q, c in zip(chunk, cnt) if not spine(q)]
            full = max(free) if free else full
            thin = [f'p{q["page"]} {c}' for q, c in zip(chunk[:-1], cnt[:-1])
                    if 2 * c < full and not spine(q)]
            emit(23, 'FAIL' if thin else 'PASS', 'E-301 chunk pages',
                 f'boards per chunk page {cnt} (fullest spine-free {full}; '
                 f'spine page filled first-fit)'
                 + (f'; under half: {", ".join(thin)}' if thin else ''))

    # 7 — garbled glyphs.
    lines += ['', '## Item 7 - garbled glyphs (? tokens, U+FFFD, tofu '
              'candidates)']
    for pg in pages:
        lab = f'{short(pg["stem"], project)} p{pg["page"]}'
        toks = pg['text'].split()
        q = [t for t in toks if re.fullmatch(r'\?+', t)]
        fffd = pg['text'].count('�')
        odd = Counter(ch for ch in pg['text'] if ord(ch) > 126 and
                      ch not in GLYPH_OK and not ch.isspace())
        bad = []
        if q:
            bad.append(f'{len(q)} "?"-only tokens')
        if fffd:
            bad.append(f'{fffd} U+FFFD')
        if odd:
            bad.append('non-ASCII outside allow-list: ' + ', '.join(
                f'U+{ord(c):04X} "{c}" x{n}' for c, n in odd.most_common(5)))
        emit(7, 'FAIL' if bad else 'PASS', lab,
             '; '.join(bad) if bad else 'clean')

    # 21 — totals add up to the rows shown (E-201 single-line + E-601 panel
    # schedules): every "TERPASANG / CONNECTED n WATT" total equals the sum of
    # the DAYA rows it covers (rows since the previous total, across pages;
    # a "(W1-Wn, LEMBAR / SHEETS a-b)" total must cover exactly ways 1..n on
    # sheets a..b). An unlabelled TOTAL on these sheets FAILs.
    lines += ['', '## Item 21 - panel-schedule TOTAL = sum of the DAYA rows '
              '(E-201 / E-601)']
    row_re = re.compile(r'^W(\d+)\s.*?\s(\d{1,3}(?:\.\d{3})*) WATT\b')
    tot_re = re.compile(r'^TOTAL(?: \(W1-W(\d+)(?:, LEMBAR / SHEETS '
                        r'(\d+)-(\d+))?\))?\s+(.*)$')
    con_re = re.compile(r'TERPASANG / CONNECTED (\d{1,3}(?:\.\d{3})*) WATT')
    for pdf in pdfs:
        st = stem_of(pdf)
        if not (st.endswith('-electrical-sld') or
                st.endswith('-panel-schedules')):
            continue
        acc = []  # (page, way, W) since the previous total
        for pg in sorted((q for q in pages if q['pdf'] == pdf),
                         key=lambda q: q['page']):
            lab = f'{short(st, project)} p{pg["page"]}'
            for raw in pg['text'].splitlines():
                ln = raw.strip()
                m = row_re.match(ln)
                if m:
                    acc.append((pg['page'], int(m.group(1)),
                                int(m.group(2).replace('.', ''))))
                    continue
                t = tot_re.match(ln)
                if not t:
                    continue
                c = con_re.search(t.group(4))
                if not c:
                    emit(21, 'FAIL', lab, f'TOTAL not labelled connected / '
                         f'demand: "{ln[:80]}"')
                    acc = []
                    continue
                printed = int(c.group(1).replace('.', ''))
                rows = sum(w for _, _, w in acc)
                bad = []
                if abs(rows - printed) > 1:
                    bad.append(f'rows sum {rows} W vs CONNECTED {printed} W')
                if t.group(1):
                    n = int(t.group(1))
                    ways = sorted({w for _, w, _ in acc})
                    if ways and ways[-1] != n:
                        bad.append(f'covers W1-W{n} but rows reach '
                                   f'W{ways[-1]}')
                    if t.group(2):
                        a, b = int(t.group(2)), int(t.group(3))
                        pgs = sorted({q for q, _, _ in acc})
                        if pgs and (pgs[0] != a or pgs[-1] != b or
                                    pg['page'] != b):
                            bad.append(f'says sheets {a}-{b}, rows on '
                                       f'p{pgs[0]}-p{pgs[-1]}')
                    elif len({q for q, _, _ in acc}) > 1:
                        bad.append('multi-page total names no sheets')
                elif len({q for q, _, _ in acc}) > 1:
                    bad.append('total covers several pages but does not '
                               'say which')
                span = sorted({q for q, _, _ in acc})
                cov = (f'p{span[0]}-p{span[-1]}' if len(span) > 1
                       else f'p{pg["page"]}')
                emit(21, 'FAIL' if bad else 'PASS', lab,
                     '; '.join(bad) if bad else
                     f'{len(acc)} rows ({cov}) sum {rows} W = CONNECTED '
                     f'{printed} W')
                acc = []
        if acc:
            emit(21, 'FAIL', short(st, project),
                 f'{len(acc)} DAYA rows after the last TOTAL')

    # 25 — PDF vs DXF text.
    lines += ['', '## Item 25 - PDF vs DXF text (whitespace-insensitive '
              'substring match; heuristic)']
    seen = set()
    for pg in pages:
        st = pg['stem']
        if st in seen:
            continue
        seen.add(st)
        dxf = os.path.join(bdir, st + '.dxf')
        lab = short(st, project)
        if not os.path.exists(dxf):
            emit(25, 'N-A', lab, 'no DXF issued')
            continue
        ptext = ''.join(p['text'] for p in pages if p['stem'] == st)
        dstr = dxf_strings(dxf)
        # The DXF writes ASCII ' - ' where the PDF prints ' · ': count that
        # substitution separately, then compare with it folded.
        mid = sum(1 for s in dstr if ' - ' in s and
                  s.replace(' - ', ' · ') in ptext)
        fold = lambda x: nows(x).replace('·', '-')
        pflat = fold(ptext)
        dflat = fold(''.join(dstr))
        dset = sorted({fold(s) for s in dstr if fold(s)}, key=len,
                      reverse=True)
        only_dxf = sorted({s for s in dstr if fold(s) and
                           fold(s) not in pflat})

        def covered(line):
            f = fold(line)
            if f in dflat:
                return True
            for d in dset:  # a PDF line may join several DXF strings
                if len(d) >= 2:
                    f = f.replace(d, '')
            return len(f) < 2

        plines = {l.strip() for l in ptext.splitlines()
                  if len(nows(l)) >= 3}
        only_pdf = sorted({l for l in plines if not covered(l)})
        note = (f' [{mid} strings print "-" in DXF for "·" in PDF]'
                if mid else '')
        if only_dxf or only_pdf:
            emit(25, 'FAIL', lab,
                 f'{len(only_dxf)} DXF-only: '
                 + ', '.join(f'"{s}"' for s in only_dxf[:10])
                 + f' || {len(only_pdf)} PDF-only: '
                 + ', '.join(f'"{s[:90]}"' for s in only_pdf[:10]) + note)
        elif mid:
            emit(25, 'FAIL', lab, 'same strings except' + note)
        else:
            emit(25, 'PASS', lab, f'{len(dstr)} DXF strings all in the PDF '
                 'and vice versa')

    # 24 — cross-document figures.
    lines += ['', '## Item 24 - cross-document figures']
    for l in figures(bdir, project, pdfs):
        v = re.search(r'(PASS|FAIL|N-A)', l).group(1)
        counts[v] += 1
        lines.append(l.replace('- 24 ', f'- [{v}] item 24 | ', 1))

    with open(os.path.join(bdir, 'precheck.md'), 'w') as f:
        f.write('\n'.join(lines) + '\n')

    err = os.path.join(bdir, 'EXPORT-ERRORS.txt')
    return dict(project=project, pages=pages, where=where, pngs=pngs,
                counts=counts, dl=dl,
                errors=open(err).read().strip() if os.path.exists(err) else '')


def main():
    root = os.path.abspath(sys.argv[1] if len(sys.argv) > 1
                           else 'build/ref_drawings')
    idx = ['# Reference-building drawing sets - index', '',
           f'Root: `{root}`. Generated by `test/reference_drawing_set_export_'
           'test.dart` (REF_EXPORT=1) + `tool/ref_drawings_precheck.py`. The '
           'A4 calc / MEP reports are not rasterised (documents, not sheets).',
           '']
    for b in BUILDINGS:
        r = run_building(root, b)
        if r is None:
            idx += [f'## {b}', '', 'not exported', '']
            continue
        pr = r['project']
        c = r['counts']
        idx += [f'## {b} - {pr}', '',
                f'{len({p["stem"] for p in r["pages"]})} drawing files, '
                f'{len(r["pages"])} pages. Pre-check: PASS {c["PASS"]}, '
                f'FAIL {c["FAIL"]}, N-A {c["N-A"]} (`{b}/precheck.md`).', '']
        if r['errors']:
            idx += [f'Export blocked: {r["errors"]}', '']
        idx += ['| file | page | drawing no. | title | paper | PNG | contact '
                '| type |', '|---|---|---|---|---|---|---|---|']
        for pg in r['pages']:
            tb = pg['tb'] or {}
            key = (pg['stem'], pg['page'])
            idx.append(
                f'| {short(pg["stem"], pr)}.pdf | {pg["page"]} | '
                f'{tb.get("DWG NO") or "-"} | {tb.get("TITLE") or "-"} | '
                f'{pg["paper"]} | {b}/{os.path.relpath(r["pngs"][key], os.path.join(root, b))} | '
                f'{b}/{r["where"][key]} | {pg["type"]} |')
        idx.append('')
    with open(os.path.join(root, 'INDEX.md'), 'w') as f:
        f.write('\n'.join(idx) + '\n')
    print(os.path.join(root, 'INDEX.md'))


if __name__ == '__main__':
    main()
