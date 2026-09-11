import 'package:flutter/material.dart';

import '../config/app_paths.dart';
import '../services/storage_migrator.dart';
import '../services/tag_db.dart';

/// Prepares the Downloads-only layout and performs the legacy move once.
class StorageMigrationGate extends StatefulWidget {
  final Widget child;

  const StorageMigrationGate({super.key, required this.child});

  @override
  State<StorageMigrationGate> createState() => _StorageMigrationGateState();
}

class _StorageMigrationGateState extends State<StorageMigrationGate> {
  MigrationReport? _report;
  bool _running = true;

  @override
  void initState() {
    super.initState();
    _migrate();
  }

  Future<void> _migrate() async {
    setState(() => _running = true);
    final report = await StorageMigrator(
      libraryRoot: AppPaths.libraryRoot,
      contentRoot: AppPaths.contentRoot,
      legacyLibraryRoots: AppPaths.legacyLibraryRoots,
      legacyContentRoots: AppPaths.legacyContentRoots,
      migrateMetadata: TagDb().migratePathPrefix,
    ).run();
    if (!mounted) return;
    setState(() {
      _report = report;
      _running = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_running) {
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Preparing ROM Manager in Downloads…'),
            ],
          ),
        ),
      );
    }

    final report = _report!;
    if (!report.succeeded) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, size: 56),
                const SizedBox(height: 16),
                const Text(
                  'ROM Manager could not prepare Downloads',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(report.errors.join('\n'), textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _migrate,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (report.changed || report.conflicts.isNotEmpty) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.drive_file_move, size: 56),
                const SizedBox(height: 16),
                const Text(
                  'Downloads migration complete',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text('${report.movedFiles} file(s) moved to ROM Manager.'),
                if (report.conflicts.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    '${report.conflicts.length} conflicting item(s) were left '
                    'in their original folders so nothing was overwritten.',
                    textAlign: TextAlign.center,
                  ),
                ],
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () => setState(
                    () => _report = const MigrationReport(
                      movedFiles: 0,
                      conflicts: [],
                      errors: [],
                      alreadyCompleted: true,
                    ),
                  ),
                  child: const Text('Continue'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return widget.child;
  }
}
