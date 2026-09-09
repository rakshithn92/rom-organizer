import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

/// First-run gate that requests all required permissions up front.
///
/// MANAGE_EXTERNAL_STORAGE is the one that needs a user popup (all-files
/// access). INTERNET is auto-granted and needs no prompt. The gate blocks the
/// app until storage access is granted, then hands off to the main UI.
class PermissionGate extends StatefulWidget {
  final Widget child;
  const PermissionGate({super.key, required this.child});

  @override
  State<PermissionGate> createState() => _PermissionGateState();
}

class _PermissionGateState extends State<PermissionGate> {
  bool _granted = false;
  bool _checking = true;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final status = await Permission.manageExternalStorage.status;
    if (status.isGranted) {
      setState(() {
        _granted = true;
        _checking = false;
      });
    } else {
      setState(() => _checking = false);
    }
  }

  Future<void> _request() async {
    setState(() => _checking = true);
    final status = await Permission.manageExternalStorage.request();
    setState(() {
      _granted = status.isGranted;
      _checking = false;
    });
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
                'This lets the app browse, extract, rename and organize your '
                'Switch ROMs on this device. No data leaves your phone.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              if (_checking)
                const CircularProgressIndicator()
              else
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
