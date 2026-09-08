import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class Service {
  final String name, label, status;
  final int? port;
  final String? path;
  Service({required this.name, required this.label, required this.status, this.port, this.path});
  factory Service.fromJson(Map<String, dynamic> j) => Service(
    name: j['name'], label: j['label'], status: j['status'],
    port: j['port'], path: j['path'],
  );
  bool get isRunning => status == 'running';
}

class SystemStats {
  final String hostname, ip;
  final double cpuPercent;
  final int memoryUsedMb, memoryTotalMb;
  final double diskUsedGb, diskTotalGb;
  SystemStats({
    required this.hostname, required this.ip, required this.cpuPercent,
    required this.memoryUsedMb, required this.memoryTotalMb,
    required this.diskUsedGb, required this.diskTotalGb,
  });
  factory SystemStats.fromJson(Map<String, dynamic> j) => SystemStats(
    hostname: j['hostname'], ip: j['ip'],
    cpuPercent: (j['cpu_percent'] as num).toDouble(),
    memoryUsedMb: j['memory_used_mb'], memoryTotalMb: j['memory_total_mb'],
    diskUsedGb: (j['disk_used_gb'] as num).toDouble(),
    diskTotalGb: (j['disk_total_gb'] as num).toDouble(),
  );
}

class FileEntry {
  final String name, path;
  final bool isDir;
  final int size;
  FileEntry({required this.name, required this.path, required this.isDir, required this.size});
  factory FileEntry.fromJson(Map<String, dynamic> j) => FileEntry(
    name: j['name'], path: j['path'], isDir: j['is_dir'], size: j['size'] ?? 0,
  );
}

class HomeVaultApi {
  final String host;
  final int port;
  final String token;
  HomeVaultApi({required this.host, required this.token, this.port = 8000});

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

  Uri _uri(String path) => Uri.parse('http://$host:$port$path');
  Map<String, String> get _headers => {'Authorization': 'Bearer $token'};

  static Future<bool> verify(String host, String token, {int port = 8000}) async {
    try {
      final r = await http.get(
        Uri.parse('http://$host:$port/api/services'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 5));
      return r.statusCode == 200;
    } catch (_) { return false; }
  }

  Future<List<Service>> listServices() async {
    final r = await http.get(_uri('/api/services'), headers: _headers);
    if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
    return (json.decode(r.body) as List).map((e) => Service.fromJson(e)).toList();
  }

  Future<SystemStats> systemStats() async {
    final r = await http.get(_uri('/api/system/stats'), headers: _headers);
    if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
    return SystemStats.fromJson(json.decode(r.body));
  }

  Future<void> restart(String name) => http.post(_uri('/api/services/$name/restart'), headers: _headers);
  Future<void> stop(String name) => http.post(_uri('/api/services/$name/stop'), headers: _headers);
  Future<void> start(String name) => http.post(_uri('/api/services/$name/start'), headers: _headers);

  Future<List<FileEntry>> listFiles(String path) async {
    final r = await http.get(_uri('/api/files?path=${Uri.encodeComponent(path)}'), headers: _headers);
    if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
    return (json.decode(r.body) as List).map((e) => FileEntry.fromJson(e)).toList();
  }

  Future<void> deleteFile(String path) async {
    final r = await http.delete(_uri('/api/files?path=${Uri.encodeComponent(path)}'), headers: _headers);
    if (r.statusCode >= 400) throw Exception('HTTP ${r.statusCode}');
  }

  Future<void> mkdir(String path) async {
    final r = await http.post(_uri('/api/files/mkdir?path=${Uri.encodeComponent(path)}'), headers: _headers);
    if (r.statusCode >= 400) throw Exception('HTTP ${r.statusCode}');
  }

  String downloadUrl(String path) =>
      _uri('/api/files/download?path=${Uri.encodeComponent(path)}').toString();
}
