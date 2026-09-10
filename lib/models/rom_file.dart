/// A single ROM file discovered on disk.
class RomFile {
  final String path;
  final String name;
  final String baseName;
  final String extension;
  final int sizeBytes;
  final DateTime modified;

  const RomFile({
    required this.path,
    required this.name,
    required this.baseName,
    required this.extension,
    required this.sizeBytes,
    required this.modified,
  });

  String get sizeLabel {
    const kb = 1024.0;
    const mb = kb * 1024;
    const gb = mb * 1024;
    if (sizeBytes >= gb) return '${(sizeBytes / gb).toStringAsFixed(1)} GB';
    if (sizeBytes >= mb) return '${(sizeBytes / mb).toStringAsFixed(0)} MB';
    if (sizeBytes >= kb) return '${(sizeBytes / kb).toStringAsFixed(0)} KB';
    return '$sizeBytes B';
  }
}
