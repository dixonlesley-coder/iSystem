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
7 garbled glyphs, 21 panel-schedule totals add up to the DAYA rows (E-201 /
E-601), 24 cross-document figures, 25 PDF vs DXF text. Report only:
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
