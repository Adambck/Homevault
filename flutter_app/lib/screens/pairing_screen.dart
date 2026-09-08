import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../api/homevault_api.dart';
import 'main_shell.dart';

class PairingScreen extends StatefulWidget {
  const PairingScreen({super.key});
  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  final _hostCtrl = TextEditingController();
  final _tokenCtrl = TextEditingController();
  bool _busy = false;
  String? _error;

  Future<void> _connect(String host, String token) async {
    setState(() { _busy = true; _error = null; });
    final ok = await HomeVaultApi.verify(host, token);
    if (!ok) {
      setState(() { _busy = false; _error = 'Kan geen verbinding maken'; });
      return;
    }
    await HomeVaultApi.save(host, token);
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const MainShell()),
    );
  }

  Future<void> _scanQr() async {
    final result = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const _QrScannerScreen()),
    );
    if (result == null) return;
    final uri = Uri.tryParse(result);
    if (uri == null || uri.scheme != 'homevault') {
      setState(() => _error = 'Ongeldige QR-code'); return;
    }
    final host = uri.host;
    final token = uri.queryParameters['token'];
    if (host.isEmpty || token == null) {
      setState(() => _error = 'QR-code mist gegevens'); return;
    }
    await _connect(host, token);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 40),
              const Icon(Icons.shield_outlined, size: 72, color: Color(0xFF3B82F6)),
              const SizedBox(height: 16),
              Text('HomeVault', textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 8),
              const Text('Verbind met je mini-PC', textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white54)),
              const SizedBox(height: 40),
              FilledButton.icon(
                onPressed: _busy ? null : _scanQr,
                icon: const Icon(Icons.qr_code_scanner),
                label: const Padding(padding: EdgeInsets.symmetric(vertical: 14),
                    child: Text('Scan QR-code')),
              ),
              const SizedBox(height: 24),
              const Row(children: [
                Expanded(child: Divider()),
                Padding(padding: EdgeInsets.symmetric(horizontal: 12),
                    child: Text('of handmatig', style: TextStyle(color: Colors.white38))),
                Expanded(child: Divider()),
              ]),
              const SizedBox(height: 16),
              TextField(controller: _hostCtrl,
                decoration: const InputDecoration(labelText: 'IP-adres',
                    hintText: '192.168.128.201', border: OutlineInputBorder())),
              const SizedBox(height: 12),
              TextField(controller: _tokenCtrl, obscureText: true,
                decoration: const InputDecoration(labelText: 'Token', border: OutlineInputBorder())),
              const SizedBox(height: 12),
              if (_error != null)
                Padding(padding: const EdgeInsets.only(bottom: 12),
                    child: Text(_error!, style: const TextStyle(color: Colors.redAccent),
                        textAlign: TextAlign.center)),
              FilledButton(
                onPressed: _busy ? null : () => _connect(_hostCtrl.text.trim(), _tokenCtrl.text.trim()),
                child: Padding(padding: const EdgeInsets.symmetric(vertical: 14),
                  child: _busy
                      ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Verbinden')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _QrScannerScreen extends StatelessWidget {
  const _QrScannerScreen();
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan QR-code')),
      body: MobileScanner(onDetect: (capture) {
        final code = capture.barcodes.firstOrNull?.rawValue;
        if (code != null) Navigator.pop(context, code);
      }),
    );
  }
}
