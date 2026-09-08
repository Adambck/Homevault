import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class Service {
  final String name;
  final String label;
  final String status;
  final int? port;
  final String? path;

  Service({
    required this.name,
    required this.label,
    required this.status,
    this.port,
    this.path,
  });

  factory Service.fromJson(Map<String, dynamic> j) => Service(
        name: j['name'],
        label: j['label'],
        status: j['status'],
        port: j['port'],
        path: j['path'],
      );

  bool get isRunning => status == 'running';
}

class SystemStats {
  final String hostname;
  final String ip;
  final double cpuPercent;
  final int memoryUsedMb;
  final int memoryTotalMb;
  final double diskUsedGb;
  final double diskTotalGb;

  SystemStats({
    required this.hostname,
    required this.ip,
    required this.cpuPercent,
    required this.memoryUsedMb,
    required this.memoryTotalMb,
    required this.diskUsedGb,
    required this.diskTotalGb,
  });

  factory SystemStats.fromJson(Map<String, dynamic> j) => SystemStats(
        hostname: j['hostname'],
        ip: j['ip'],
        cpuPercent: (j['cpu_percent'] as num).toDouble(),
        memoryUsedMb: j['memory_used_mb'],
        memoryTotalMb: j['memory_total_mb'],
        diskUsedGb: (j['disk_used_gb'] as num).toDouble(),
        diskTotalGb: (j['disk_total_gb'] as num).toDouble(),
      );
}

class HomeVaultApi {
  final String host;
  final String token;

  HomeVaultApi({required this.host, required this.token});

  static Future<HomeVaultApi?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final host = prefs.getString('host');
    final token = prefs.getString('token');
    if (host == null || token == null) return null;
    return HomeVaultApi(host: host, token: token);
  }

  static Future<void> save(String host, String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('host', host);
    await prefs.setString('token', token);
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('host');
    await prefs.remove('token');
  }

  Uri _uri(String path) => Uri.parse('http://$host:8000$path');
  Map<String, String> get _headers => {'Authorization': 'Bearer $token'};

  /// Verify a host/token pair without saving them.
  static Future<bool> verify(String host, String token) async {
    try {
      final r = await http.get(
        Uri.parse('http://$host:8000/api/services'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 5));
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<List<Service>> listServices() async {
    final r = await http.get(_uri('/api/services'), headers: _headers);
    if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
    final list = json.decode(r.body) as List;
    return list.map((e) => Service.fromJson(e)).toList();
  }

  Future<SystemStats> systemStats() async {
    final r = await http.get(_uri('/api/system/stats'), headers: _headers);
    if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
    return SystemStats.fromJson(json.decode(r.body));
  }

  Future<void> restart(String name) async {
    await http.post(_uri('/api/services/$name/restart'), headers: _headers);
  }

  Future<void> stop(String name) async {
    await http.post(_uri('/api/services/$name/stop'), headers: _headers);
  }

  Future<void> start(String name) async {
    await http.post(_uri('/api/services/$name/start'), headers: _headers);
  }
}
