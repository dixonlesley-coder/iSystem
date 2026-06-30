# ODA File Converter (DWG → DXF) — optional bundle

iSystem reads **DWG** floor plans by converting them to DXF on import, using the
free **ODA File Converter** from the Open Design Alliance. DWG is a proprietary
binary format with no in-process reader, so this external converter is the
offline-friendly path (it batch-converts DWG↔DXF with no network).

The converter binary is **not committed to this repo** — ODA's licence governs
its redistribution. To ship DWG support:

1. Download the **ODA File Converter** for Windows from
   <https://www.opendesign.com/guestfiles/oda_file_converter> (free, registration
   required). Review its licence/redistribution terms for your distribution.
2. Copy its installed files (at minimum `ODAFileConverter.exe` and its DLLs) into
   this folder: `installer/vendor/oda/`.
3. Build the installer as usual. `iSystem.iss` bundles everything here into
   `{app}\oda\`, where the app's `OdaDwgConverter.resolveBinary` finds
   `ODAFileConverter.exe` automatically.

If this folder is empty at build time the installer still builds (the source is
flagged `skipifsourcedoesntexist`); DWG import then reports "DWG converter not
found — install the ODA File Converter or export your drawing to DXF", while PDF
and DXF import are unaffected.

### Alternative: point at an existing install

Instead of bundling, set the `ODA_CONVERTER` environment variable to the full
path of `ODAFileConverter.exe`; the app prefers it over the bundled copy.
