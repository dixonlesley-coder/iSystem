# ODA File Converter (DWG → DXF) — bundled at build time

iSystem reads **DWG** floor plans by converting them to DXF on import, using the
free **ODA File Converter** from the Open Design Alliance. DWG is a proprietary
binary format with no in-process reader, so this external converter is the
offline-friendly path (it batch-converts DWG↔DXF with no network).

The converter binary is **not committed to this repo** — it is large and ODA's
licence governs its redistribution. Instead, the **release workflow fetches it at
build time** and Inno Setup bundles it into `{app}\oda\`, where the app's
`OdaDwgConverter.resolveBinary` finds `ODAFileConverter.exe` automatically. Do it
once and every future release ships DWG support.

> ⚠️ **Licence:** embedding the ODA File Converter in a distributed installer is
> redistribution. Confirm your rights under ODA's terms (an ODA membership may be
> required for commercial redistribution) before publishing a release that
> bundles it. The mechanism below is intentionally opt-in.

## Prepare the bundle (one time)

1. Download the **ODA File Converter** for Windows from
   <https://www.opendesign.com/guestfiles/oda_file_converter>.
2. From its install folder, collect the files needed to run it headless — at
   minimum `ODAFileConverter.exe` plus its Qt DLLs (`Qt5*.dll`) and the
   `platforms\qwindows.dll` (and any other DLLs sitting beside the exe).
3. **Zip them** so `ODAFileConverter.exe` is at the top level (or in a single
   nested folder — CI flattens one level). Name it e.g. `oda-file-converter.zip`.

## Give CI the bundle (pick ONE)

- **Repo release asset (no secrets):** create a one-time GitHub Release/tag named
  **`vendor-oda`** and upload the zip as an asset. The release workflow downloads
  it with the built-in token — nothing else to configure.

  ```sh
  gh release create vendor-oda oda-file-converter.zip \
    --title "ODA File Converter bundle" \
    --notes "Bundled by the release workflow into {app}\\oda (not for public download)."
  ```

- **Secret URL:** host the zip anywhere reachable and set the repo secret
  **`ODA_ZIP_URL`** to its direct download URL. It takes priority over the
  `vendor-oda` asset.

## What happens on release

The `Fetch bundled ODA File Converter (optional)` step in
`.github/workflows/release.yml` pulls the zip (secret URL first, else the
`vendor-oda` asset), extracts + flattens it here, and the installer bundles it
into `{app}\oda\`. If neither source is present the step is a no-op: the build
still succeeds and DWG import reports *"converter not found — install the ODA File
Converter or export your drawing to DXF"*, while PDF and DXF import are
unaffected.

## Alternative: point at an existing install (per machine, no bundling)

Set the `ODA_CONVERTER` environment variable to the full path of
`ODAFileConverter.exe`; the app prefers it over the bundled copy.
