/// Outcome of importing one archive or loose ROM.
class ImportResult {
  final String gameFolder;
  final int baseFiles;
  final int updateFiles;
  final int dlcFiles;
  final bool fullyExtracted;
  final String? titleId;
  final String? warning;
  final String? error;

  const ImportResult({
    required this.gameFolder,
    required this.baseFiles,
    required this.updateFiles,
    required this.dlcFiles,
    required this.fullyExtracted,
    this.titleId,
    this.warning,
    this.error,
  });
}
