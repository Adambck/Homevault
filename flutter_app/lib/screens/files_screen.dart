import 'package:flutter/material.dart';
import '../api/homevault_api.dart';

class FilesScreen extends StatefulWidget {
  const FilesScreen({super.key});
  @override
  State<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends State<FilesScreen> {
  HomeVaultApi? _api;
  String _path = '/';
  List<FileEntry> _files = [];
  String? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _api = await HomeVaultApi.load();
    await _load(_path);
  }

  Future<void> _load(String path) async {
    setState(() { _loading = true; _error = null; });
    try {
      final files = await _api!.listFiles(path);
      if (!mounted) return;
      setState(() { _path = path; _files = files; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Future<void> _delete(FileEntry f) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Verwijderen'),
        content: Text(f.name),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuleer')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Verwijder')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _api!.deleteFile(f.path);
      await _load(_path);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _mkdir() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) {
        final ctrl = TextEditingController();
        return AlertDialog(
          title: const Text('Nieuwe map'),
          content: TextField(controller: ctrl, autofocus: true,
              decoration: const InputDecoration(hintText: 'Naam')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuleer')),
            TextButton(onPressed: () => Navigator.pop(context, ctrl.text.trim()), child: const Text('Maken')),
          ],
        );
      },
    );
    if (name == null || name.isEmpty) return;
    final target = (_path == '/' ? '' : _path) + '/' + name;
    try {
      await _api!.mkdir(target);
      await _load(_path);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  String _formatSize(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
    return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  IconData _icon(FileEntry f) {
    if (f.isDir) return Icons.folder;
    final ext = f.name.split('.').last.toLowerCase();
    if (['jpg', 'jpeg', 'png', 'gif', 'webp'].contains(ext)) return Icons.image;
    if (['mp4', 'mkv', 'mov'].contains(ext)) return Icons.movie;
    if (['mp3', 'wav', 'flac'].contains(ext)) return Icons.music_note;
    if (['pdf'].contains(ext)) return Icons.picture_as_pdf;
    return Icons.description;
  }

  @override
  Widget build(BuildContext context) {
    final parts = _path.split('/').where((s) => s.isNotEmpty).toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Bestanden'),
        actions: [
          IconButton(icon: const Icon(Icons.create_new_folder_outlined), onPressed: _mkdir),
          IconButton(icon: const Icon(Icons.refresh), onPressed: () => _load(_path)),
        ],
      ),
      body: Column(
        children: [
          // Breadcrumb
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                GestureDetector(
                  onTap: () => _load('/'),
                  child: const Icon(Icons.home_outlined, size: 20),
                ),
                for (int i = 0; i < parts.length; i++) ...[
                  const Text(' / ', style: TextStyle(color: Colors.white38)),
                  GestureDetector(
                    onTap: () => _load('/' + parts.sublist(0, i + 1).join('/')),
                    child: Text(parts[i],
                        style: const TextStyle(color: Color(0xFF60A5FA))),
                  ),
                ],
              ]),
            ),
          ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          if (_error != null)
            Padding(padding: const EdgeInsets.all(16),
                child: Text(_error!, style: const TextStyle(color: Colors.redAccent))),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => _load(_path),
              child: _files.isEmpty && !_loading
                  ? const Center(child: Text('📭', style: TextStyle(fontSize: 40)))
                  : ListView.builder(
                      itemCount: _files.length,
                      itemBuilder: (_, i) {
                        final f = _files[i];
                        return ListTile(
                          leading: Icon(_icon(f),
                              color: f.isDir ? const Color(0xFF60A5FA) : Colors.white70),
                          title: Text(f.name),
                          subtitle: f.isDir ? null : Text(_formatSize(f.size)),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => _delete(f),
                          ),
                          onTap: f.isDir ? () => _load(f.path) : null,
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
