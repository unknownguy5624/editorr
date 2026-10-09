import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

class ProjectEntry {
  final String path;
  final DateTime createdAt;
  ProjectEntry(this.path, this.createdAt);

  String get name => path.split('/').last;

  Map<String, dynamic> toJson() => {
        'path': path,
        'createdAt': createdAt.toIso8601String(),
      };

  static ProjectEntry fromJson(Map<String, dynamic> j) => ProjectEntry(
        j['path'] as String,
        DateTime.tryParse(j['createdAt'] as String? ?? '') ?? DateTime.now(),
      );
}

/// Remembers exported videos so they show up under "Recent Projects".
class ProjectStore {
  static const _key = 'recent_exports';

  static Future<List<ProjectEntry>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_key) ?? [];
    final out = <ProjectEntry>[];
    for (final s in raw) {
      try {
        final e = ProjectEntry.fromJson(jsonDecode(s) as Map<String, dynamic>);
        if (File(e.path).existsSync()) out.add(e);
      } catch (_) {}
    }
    return out;
  }

  static Future<void> add(String path) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_key) ?? [];
    raw.insert(0, jsonEncode(ProjectEntry(path, DateTime.now()).toJson()));
    await prefs.setStringList(_key, raw.take(30).toList());
  }
}
