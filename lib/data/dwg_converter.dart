import 'dart:io';

/// Outcome of a DWG → DXF conversion.
enum DwgConvertStatus {
  /// Converted; [DwgConvertResult.dxfPath] points at the produced DXF.
  ok,

  /// No converter binary could be found — the user must install/bundle it.
  converterNotFound,

  /// The converter ran but failed (corrupt DWG, unsupported version, …).
  failed,
}

/// The result of a DWG → DXF conversion: a status plus, on success, the path to
/// the produced DXF; on failure a human-readable [message].
class DwgConvertResult {
  final DwgConvertStatus status;
  final String? dxfPath;
  final String? message;

  const DwgConvertResult.ok(this.dxfPath)
      : status = DwgConvertStatus.ok,
        message = null;
  const DwgConvertResult.notFound(this.message)
      : status = DwgConvertStatus.converterNotFound,
        dxfPath = null;
  const DwgConvertResult.failed(this.message)
      : status = DwgConvertStatus.failed,
        dxfPath = null;

  bool get isOk => status == DwgConvertStatus.ok && dxfPath != null;
}

/// Converts a binary DWG into a DXF we can parse. Injectable so the import flow
/// is testable with a fake; the real implementation shells out to a bundled
/// command-line converter (DWG's format is proprietary — there is no in-process
/// reader).
abstract interface class DwgConverter {
  /// Convert [dwgPath] into a DXF written under [outDir]; return its path.
  Future<DwgConvertResult> toDxf(String dwgPath, String outDir);
}

/// Production [DwgConverter] backed by the **ODA File Converter** — the Open
/// Design Alliance's free DWG/DXF batch converter. It is a folder-based batch
/// tool, so we stage the single DWG in a temp input folder, run the converter,
/// and read the produced `<stem>.dxf` back out.
///
/// The converter binary is NOT redistributed in this repo (ODA's licence governs
/// redistribution); the Windows installer drops it at `oda/ODAFileConverter.exe`
/// beside the app when the maintainer supplies it. Resolution order:
/// 1. the `ODA_CONVERTER` environment variable (full path to the exe),
/// 2. `<app dir>/oda/ODAFileConverter[.exe]` (bundled),
/// 3. a NORMALLY-INSTALLED ODA File Converter found under Program Files (so an
///    engineer can just run ODA's own MSI and iSystem auto-detects it — no
///    bundling), and
/// 4. the bare name on `PATH`.
class OdaDwgConverter implements DwgConverter {
  /// Output DXF version handed to ODA (a widely-compatible recent ACAD format).
  static const String outputVersion = 'ACAD2018';

  const OdaDwgConverter();

  /// The converter executable name per platform.
  static String get _exeName =>
      Platform.isWindows ? 'ODAFileConverter.exe' : 'ODAFileConverter';

  /// Resolve the converter binary path, or null to fall back to the bare name on
  /// `PATH`. Pure (takes the env + app dir + any discovered system installs) so
  /// it is unit-testable; [extraCandidates] are already-formed exe paths tried
  /// after the bundled copy (see [systemOdaCandidates]).
  static String? resolveBinary({
    required Map<String, String> environment,
    required String appDir,
    required bool Function(String path) exists,
    List<String> extraCandidates = const [],
  }) {
    final fromEnv = environment['ODA_CONVERTER'];
    if (fromEnv != null && fromEnv.isNotEmpty && exists(fromEnv)) {
      return fromEnv;
    }
    final bundled = _join(_join(appDir, 'oda'), _exeName);
    if (exists(bundled)) return bundled;
    for (final c in extraCandidates) {
      if (exists(c)) return c;
    }
    return null; // let Process resolve the bare name on PATH
  }

  /// Candidate `ODAFileConverter.exe` paths from a NORMAL ODA install (its MSI
  /// installs to `C:\Program Files\ODA\ODAFileConverter <ver>\`). Scans the
  /// Program Files roots for `ODA\ODAFileConverter*` folders, newest-name first,
  /// so a version-suffixed install is found without the user configuring
  /// anything. Non-Windows / no install ⇒ empty. Never throws.
  static List<String> systemOdaCandidates() {
    if (!Platform.isWindows) return const [];
    final roots = <String>{
      for (final k in const ['ProgramFiles', 'ProgramFiles(x86)', 'ProgramW6432'])
        if ((Platform.environment[k] ?? '').isNotEmpty)
          Platform.environment[k]!,
      r'C:\Program Files',
      r'C:\Program Files (x86)',
    };
    final out = <String>[];
    for (final root in roots) {
      try {
        final odaDir = Directory(_join(root, 'ODA'));
        if (!odaDir.existsSync()) continue;
        final installs = odaDir
            .listSync()
            .whereType<Directory>()
            .where((d) => d.uri.pathSegments
                .where((s) => s.isNotEmpty)
                .last
                .toLowerCase()
                .startsWith('odafileconverter'))
            .toList()
          // Newest version-suffixed folder first.
          ..sort((a, b) => b.path.compareTo(a.path));
        for (final d in installs) {
          out.add(_join(d.path, _exeName));
        }
      } catch (_) {
        // Unreadable root — skip.
      }
    }
    return out;
  }

  /// The positional argument list ODA File Converter expects:
  /// `<inDir> <outDir> <outVer> <outType> <recurse> <audit> <filter>`.
  /// Pure + unit-testable.
  static List<String> odaArgs(String inDir, String outDir) => [
        inDir,
        outDir,
        outputVersion,
        'DXF',
        '0', // recurse off
        '1', // audit on (repair minor corruption)
        '*.DWG',
      ];

  @override
  Future<DwgConvertResult> toDxf(String dwgPath, String outDir) async {
    final src = File(dwgPath);
    if (!src.existsSync()) {
      return const DwgConvertResult.failed('DWG file not found.');
    }

    final appDir = File(Platform.resolvedExecutable).parent.path;
    final binary = resolveBinary(
          environment: Platform.environment,
          appDir: appDir,
          exists: (p) => File(p).existsSync(),
          extraCandidates: systemOdaCandidates(),
        ) ??
        _exeName;

    // Stage the single DWG in a private input folder (ODA batches a folder).
    final stamp = dwgPath.hashCode.toUnsigned(32).toRadixString(16);
    final inDir = Directory(_join(outDir, 'in_$stamp'));
    final realOut = Directory(_join(outDir, 'out_$stamp'));
    try {
      inDir.createSync(recursive: true);
      realOut.createSync(recursive: true);
      final stem = _stem(src.uri.pathSegments.last);
      src.copySync(_join(inDir.path, '$stem.dwg'));

      ProcessResult run;
      try {
        run = await Process.run(binary, odaArgs(inDir.path, realOut.path));
      } on ProcessException catch (e) {
        return DwgConvertResult.notFound(
          'DWG converter not found ($binary). Install the ODA File Converter '
          'or export your drawing to DXF. ($e)',
        );
      }

      final produced = File(_join(realOut.path, '$stem.dxf'));
      if (produced.existsSync()) {
        return DwgConvertResult.ok(produced.path);
      }
      return DwgConvertResult.failed(
        'DWG conversion produced no DXF '
        '(exit ${run.exitCode}). ${run.stderr}'.trim(),
      );
    } catch (e) {
      return DwgConvertResult.failed('DWG conversion failed: $e');
    }
  }

  static String _stem(String basename) {
    final i = basename.toLowerCase().lastIndexOf('.dwg');
    return i > 0 ? basename.substring(0, i) : basename;
  }
}

String _join(String a, String b) {
  final sep = Platform.isWindows ? '\\' : '/';
  if (a.endsWith('/') || a.endsWith('\\')) return '$a$b';
  return '$a$sep$b';
}
