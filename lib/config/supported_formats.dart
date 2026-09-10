/// File formats understood by the scanner and importer.
abstract final class SupportedFormats {
  static const switchRoms = <String>{
    '.nsp',
    '.xci',
    '.nsz',
    '.xcz',
    '.nca',
  };

  static const decodableArchives = <String>{
    '.zip',
    '.tar',
    '.gz',
    '.tgz',
    '.bz2',
    '.tbz2',
    '.xz',
    '.txz',
  };

  static const externallyExtractedArchives = <String>{'.7z', '.rar'};

  static const archives = <String>{
    ...decodableArchives,
    ...externallyExtractedArchives,
  };
}
