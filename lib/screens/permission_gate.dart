import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

/// First-run gate that requests the storage permission needed by dart:io.
///
/// MANAGE_EXTERNAL_STORAGE is the one that needs a user popup (all-files
/// access). The UI itself is deliberately confined to Downloads, but current
/// Android releases still require this grant for direct path-based move,
/// rename, archive extraction, and the one-time migration from older folders.
class PermissionGate extends StatefulWidget {
  final Widget child;
  const PermissionGate({super.key, required this.child});

  @override
  State<PermissionGate> createState() => _PermissionGateState();
}

class _PermissionGateState extends State<PermissionGate> {
  bool _granted = false;
  bool _checking = true;
  bool _denied = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final status = await Permission.manageExternalStorage.status;
    if (!mounted) return;
    if (status.isGranted) {
      setState(() {
        _granted = true;
        _checking = false;
      });
    } else {
      setState(() {
        _denied = status.isPermanentlyDenied;
        _checking = false;
      });
    }
  }

  Future<void> _request() async {
    setState(() => _checking = true);
    final status = await Permission.manageExternalStorage.request();
    if (!mounted) return;
    setState(() {
      _granted = status.isGranted;
      _denied = status.isPermanentlyDenied;
      _checking = false;
    });
  }

  Future<void> _openSettings() async {
    await openAppSettings();
    if (!mounted) return;
    _check();
  }

  @override
  Widget build(BuildContext context) {
    if (_granted) return widget.child;
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.folder_open, size: 64),
              const SizedBox(height: 16),
              const Text(
                'ROM Organizer needs access to your files',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              const Text(
                'This lets the app migrate older libraries, then browse, '
                'extract, rename and organize files only inside the Downloads '
                'folder. No ROM data leaves your phone.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              if (_checking)
                const CircularProgressIndicator()
              else if (_denied) ...[
                const Text(
                  'Access was denied. Enable "All files access" for ROM '
                  'Organizer in Settings to continue.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _openSettings,
                  icon: const Icon(Icons.settings),
                  label: const Text('Open settings'),
                ),
              ] else
                FilledButton.icon(
                  onPressed: _request,
                  icon: const Icon(Icons.check),
                  label: const Text('Allow file access'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
