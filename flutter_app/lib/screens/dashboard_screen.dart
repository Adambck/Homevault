import 'dart:async';
import 'package:flutter/material.dart';

import '../api/homevault_api.dart';
import 'pairing_screen.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});
  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  HomeVaultApi? _api;
  List<Service> _services = [];
  SystemStats? _stats;
  Timer? _timer;
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _api = await HomeVaultApi.load();
    if (_api == null) return;
    await _refresh();
    _timer = Timer.periodic(const Duration(seconds: 25), (_) => _refresh());
  }

  Future<void> _refresh() async {
    try {
      final svc = await _api!.listServices();
      final stats = await _api!.systemStats();
      if (!mounted) return;
      setState(() { _services = svc; _stats = stats; _error = null; });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  Future<void> _unpair() async {
    _timer?.cancel();
    await HomeVaultApi.clear();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const PairingScreen()),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_stats?.hostname ?? 'HomeVault'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _refresh),
          IconButton(icon: const Icon(Icons.logout), onPressed: _unpair),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_stats != null) _SystemCard(stats: _stats!),
            const SizedBox(height: 20),
            Text('Services', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            ..._services.map((s) => _ServiceCard(
                  service: s,
                  onRestart: () async {
                    await _api!.restart(s.name);
                    await _refresh();
                  },
                  onToggle: () async {
                    if (s.isRunning) {
                      await _api!.stop(s.name);
                    } else {
                      await _api!.start(s.name);
                    }
                    await _refresh();
                  },
                )),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 20),
                child: Text(_error!,
                    style: const TextStyle(color: Colors.redAccent)),
              ),
          ],
        ),
      ),
    );
  }
}

class _SystemCard extends StatelessWidget {
  final SystemStats stats;
  const _SystemCard({required this.stats});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(stats.ip, style: const TextStyle(color: Colors.white54)),
            const SizedBox(height: 16),
            _Metric(label: 'CPU', value: '${stats.cpuPercent.toStringAsFixed(0)}%',
                    fraction: stats.cpuPercent / 100),
            const SizedBox(height: 12),
            _Metric(
              label: 'Geheugen',
              value: '${(stats.memoryUsedMb / 1024).toStringAsFixed(1)} / ${(stats.memoryTotalMb / 1024).toStringAsFixed(1)} GB',
              fraction: stats.memoryUsedMb / stats.memoryTotalMb,
            ),
            const SizedBox(height: 12),
            _Metric(
              label: 'Schijf',
              value: '${stats.diskUsedGb.toStringAsFixed(1)} / ${stats.diskTotalGb.toStringAsFixed(1)} GB',
              fraction: stats.diskUsedGb / stats.diskTotalGb,
            ),
          ],
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  final String label;
  final String value;
  final double fraction;
  const _Metric({required this.label, required this.value, required this.fraction});
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(label),
          Text(value, style: const TextStyle(color: Colors.white54)),
        ]),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: fraction.clamp(0.0, 1.0),
            minHeight: 6,
            backgroundColor: Colors.white12,
          ),
        ),
      ],
    );
  }
}

class _ServiceCard extends StatelessWidget {
  final Service service;
  final VoidCallback onRestart;
  final VoidCallback onToggle;
  const _ServiceCard({
    required this.service,
    required this.onRestart,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final color = switch (service.status) {
      'running' => const Color(0xFF22C55E),
      'stopped' => Colors.orange,
      _ => Colors.redAccent,
    };
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 10, height: 10,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(service.label,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  Text(service.status,
                      style: const TextStyle(color: Colors.white54, fontSize: 13)),
                ],
              ),
            ),
            if (service.status != 'missing') ...[
              IconButton(
                icon: Icon(service.isRunning ? Icons.stop_circle_outlined : Icons.play_circle_outline),
                onPressed: onToggle,
                tooltip: service.isRunning ? 'Stop' : 'Start',
              ),
              IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: service.isRunning ? onRestart : null,
                tooltip: 'Herstart',
              ),
            ],
          ],
        ),
      ),
    );
  }
}
