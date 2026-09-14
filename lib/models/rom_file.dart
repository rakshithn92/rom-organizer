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

  String get sizeLabel => formatBytes(sizeBytes);

  /// Formats [bytes] as a short human-readable size, e.g. `1.2 GB`, `345 MB`,
  /// `12 KB`, `512 B`. One decimal below GB so multi-GB ROMs are comparable at
  /// a glance; whole numbers above it, where the extra digit is noise.
  static String formatBytes(int bytes) {
    const kb = 1024.0;
    const mb = kb * 1024;
    const gb = mb * 1024;
    if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(1)} GB';
    if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(0)} MB';
    if (bytes >= kb) return '${(bytes / kb).toStringAsFixed(0)} KB';
    return '$bytes B';
  }
}
