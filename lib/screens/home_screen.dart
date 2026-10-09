import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/ad_service.dart';
import '../services/project_store.dart';
import 'editor_screen.dart';
import 'export_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<ProjectEntry> _projects = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await ProjectStore.load();
    if (mounted) setState(() => _projects = list);
  }

  Future<void> _newProject() async {
    final picked = await ImagePicker().pickVideo(source: ImageSource.gallery);
    if (picked == null || !mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => EditorScreen(videoPath: picked.path)),
    );
    _load();
  }

  Future<void> _open(ProjectEntry p) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ExportScreen(path: p.path)),
    );
    _load();
  }

  String _date(DateTime d) => '${d.day}/${d.month}/${d.year}';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'QuickCut',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 64,
                child: FilledButton.icon(
                  onPressed: _newProject,
                  icon: const Icon(Icons.add_circle_outline),
                  label: const Text(
                    'New project',
                    style: TextStyle(fontSize: 18),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'Recent Projects',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: _projects.isEmpty
                    ? const Center(
                        child: Text(
                          'Nothing here yet.\nTap "New project" to edit a video.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white54),
                        ),
                      )
                    : GridView.builder(
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          mainAxisSpacing: 12,
                          crossAxisSpacing: 12,
                          childAspectRatio: 1.15,
                        ),
                        itemCount: _projects.length,
                        itemBuilder: (context, i) {
                          final p = _projects[i];
                          return InkWell(
                            borderRadius: BorderRadius.circular(14),
                            onTap: () => _open(p),
                            child: Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: const Color(0xFF17171F),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Expanded(
                                    child: Center(
                                      child: Icon(
                                        Icons.movie_creation_outlined,
                                        size: 40,
                                        color: Colors.white38,
                                      ),
                                    ),
                                  ),
                                  Text(
                                    p.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  Text(
                                    _date(p.createdAt),
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Colors.white54,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: const SafeArea(
        child: SizedBox(
          height: 50,
          child: Center(child: BannerAdWidget()),
        ),
      ),
    );
  }
}
