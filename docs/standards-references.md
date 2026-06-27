# Standards references — SNI / PUIL source values

Canonical record of the **published-standard values** the engine sizes against, with
the exact clause/table numbers and sources, so the numbers in `packages/mechx_engine/
lib/standards/**` (and the sizing modules) are traceable to their origin.

## Provenance policy (mirrors `standards/sni.dart` `VerificationStatus`)

- **`sniVerbatim`** — confirmed against the official standard text itself. Only use this
  tier when the official PDF text has been read directly.
- **`secondarySource`** — a real figure with a specific clause/table reference,
  corroborated across independent sources that quote the standard, but the official PDF
  text has not yet been read end-to-end. Still surfaced as UNVERIFIED in reports.
- **`notAnSniClause`** — general engineering practice where no SNI clause prescribes a
  value.

The values below were corroborated against multiple sources that quote the standards
(with table/clause numbers). Treat them as **`secondarySource` with a precise citation**
until the official PDF is read verbatim — at which point the matching value may be
promoted to `sniVerbatim`. **Do not** promote on the strength of secondary sources alone.

---

## SNI 03-6572-2001 — Ventilation / air-conditioning (ACH)

`Tata cara perancangan sistem ventilasi dan pengkondisian udara pada bangunan gedung`.
**Tabel 4.4.1 "Kebutuhan ventilasi mekanis"** — recommended air changes per hour.

| Space (Bahasa)            | ACH | Notes |
|---------------------------|-----|-------|
| Kantor (office)           | 6   | + min fresh air 18 m³/h per person |
| Restoran (restaurant)     | 6   | |
| Toko / pasar swalayan (retail) | 6 | |
| Pabrik / bengkel (workshop) | 6 | |
| Kelas / bioskop (classroom / cinema) | 8 | |
| Lobi / koridor / tangga (lobby / corridor / stair) | 4 | |
| Kamar mandi / WC (toilet) | 10  | 2.25 m³/min per WC |
| Dapur (kitchen)           | 20  | |
| Ruang rapat (meeting room) | —  | specified per-person: 1.05 (smoking) / 0.21 (non-smoking) m³/min, not as ACH |

Spaces NOT in Tabel 4.4.1 (bedroom, living room, hospital ward, laboratory, server room)
remain general HVAC practice (`secondarySource`, ASHRAE 62.1-class).

> Drives `standards/ventilation.dart` `_achValue`. Earlier draft values that differ from the
> table (classroom 6→8, retail 8→6, restaurant 10→6, toilet 12→10, lobby 5→4) are TO BE
> corrected to these SNI figures (pending — applied in the standards-citation pass).

ACH cooling-load BTU/m² densities and AC PK conventions are NOT from this standard —
they stay general practice (`secondarySource`); see `sizing/cooling_load.dart`.

---

## SNI 8153:2015 — Plumbing (`Sistem plambing pada bangunan gedung`)

Revision/merge of SNI 03-6481-2000 + SNI 03-7065-2005; method based on UPC 2012 / IAPMO.

- Minimum pressure at a fixture discharge point: **0.5 kg/cm² ≈ 49 kPa** (5 m water column).
- Direct flush valve (katup gelontor langsung): **≥ 1 kg/cm² ≈ 98 kPa**.
- Pressure-reducing valve required when pressure **> 5 kg/cm² ≈ 490 kPa** (50 m water
  column) — the **zoning / PRV trigger**.

> Drives the max-fixture-pressure / PRV-zoning trigger in `standards/sni.dart`.
> UBAP (unit beban alat plambing) Tabel 3 per-fixture loads and the fixture-unit →
> probable-flow demand curve follow the UPC/Hunter method; the exact per-fixture UBAP
> numbers were not captured verbatim in this pass — they stay `secondarySource`.

---

## PUIL 2011 — Electrical (`Persyaratan Umum Instalasi Listrik`)

- Voltage drop between the consumer terminal and any point of the installation must not
  exceed **5 %** of nominal voltage — **clause 4.2.3.1**.
- A final circuit cable's continuous current capacity (KHA) must be **≥ 125 % of the
  full-load current** for a single motor — **clause 2.2.8.3**.
- KHA tables assume **30 °C** reference ambient; temperature + grouping correction factors
  are in **Tabel K.52.3.2** (PUIL 2011 amandemen 1:2013). Applied as `Ib' = Ib / (k1·k2)`.

> Drives `standards/puil.dart` voltage-drop limit, the 125 % continuous-load rule, and the
> derating basis (`electrical/sizing.dart` `deratingFactor`).

---

## SNI 03-3989-2000 — Automatic sprinklers

`Tata cara perencanaan dan pemasangan sistem springkler otomatik`. Density in mm/min.

- Light hazard (bahaya ringan): ~2.25 mm/min.
- **Ordinary hazard (bahaya sedang): 5 mm/min**, design operating area **72–360 m²**.
- Heavy hazard (bahaya berat): higher density per the occupancy classification.

> Drives the density / operating-area basis in `sizing/fire_sprinkler.dart`.

---

## SNI 03-1745-2000 — Standpipe & hydrant (references NFPA 14)

- Class I / III: **500 gpm** for the first/most-remote standpipe + **250 gpm** per
  additional standpipe, total not exceeding **1250 gpm**.
- Class II: **100 gpm (≈ 379 L/min)**.
- Residual pressure: **6.9 bar (100 psi)** at the most-remote 65 mm (2½″) outlet;
  **4.5 bar (65 psi)** at the most-remote 40 mm (1½″) outlet.

> Drives the flow + residual targets in `sizing/fire_standpipe.dart`.

---

## Sources

- SNI 8153:2015 — full text: <https://archive.org/details/SNI81532015SistemPlambingPadaBangunanGedung>
- SNI 03-6572-2001 — <https://www.endlessafe.com/wp-content/uploads/2022/03/SNI-03-6572-2001.pdf> (Tabel 4.4.1)
- PUIL 2011 — <https://gatrik.esdm.go.id/assets/uploads/download_index/files/d8197-buku-puil-2011.pdf> (cl. 4.2.3.1, 2.2.8.3, Tabel K.52.3.2)
- SNI 03-3989-2000 — <https://muhyidin.id/wp-content/uploads/2020/07/SNI-03-3989-2000-Tata-cara-perencanaan-dan-pemasangan-sistem-springkler-otomatik-untuk-pencegahan-bahaya-kebakaran-pada-bangunan-gedung.pdf>
- SNI 03-1745-2000 — <https://katigaku.top/wp-content/uploads/2016/03/sni_pipa_1745_2000.pdf>
- SNI 6390:2020 (AC energy / EER labels) — corroborated earlier: split-AC MEPS EER 8.53→10.41 BTU/h·W (COP ≈ 2.5–3.05).

> Direct PDF fetch was blocked (HTTP 403) through the build proxy during research; the
> values above were corroborated via multiple sources quoting these documents. Reading the
> official PDFs end-to-end is the remaining step to promote matching values to `sniVerbatim`.
