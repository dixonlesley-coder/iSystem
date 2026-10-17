import 'dart:convert';
import 'dart:io';

/// Read a DXF file's text TOLERANTLY. Pre-2007 DXF (R12/R2000/R2004, still a
/// common "save as" target) is written in the drawing's `$DWGCODEPAGE` (e.g.
/// ANSI_1252), so a room label carrying `²`, `°` or `Ø` is a raw single byte
/// that strict UTF-8 refuses — `File.readAsString` throws and the whole import
/// aborts. `parseDxf` consumes only numeric group values and ASCII entity
/// names, so decoding malformed sequences to U+FFFD cannot change the geometry.
///
/// Every DXF reader in the app (import, canvas page, plan underlay, the
/// converted-DWG path) goes through these so they agree on the decode.
Future<String> readDxfText(String path) async =>
    decodeDxfBytes(await File(path).readAsBytes());

/// Synchronous [readDxfText] for the cached render/underlay paths.
String readDxfTextSync(String path) =>
    decodeDxfBytes(File(path).readAsBytesSync());

/// UTF-8 with malformed sequences replaced (never throws).
String decodeDxfBytes(List<int> bytes) =>
    utf8.decode(bytes, allowMalformed: true);
