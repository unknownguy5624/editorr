import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../services/ad_service.dart';
import '../services/edit_settings.dart';
import '../services/export_service.dart';
import '../services/project_store.dart';
import 'export_screen.dart';

enum Tool { trim, speed, filters, text, music }

class EditorScreen extends StatefulWidget {
  final String videoPath;
  const EditorScreen({super.key, required this.videoPath});

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  late final VideoPlayerController _c;
  final EditSettings s = EditSettings();
  final TextEditingController _textCtrl = TextEditingController();

  bool _ready = false;
  double _duration = 0; // seconds
  Tool _tool = Tool.trim;
  bool _exporting = false;
  double _progress = 0;

  @override
  void initState() {
    super.initState();
    AdService.loadInterstitial();
    _c = VideoPlayerController.file(File(widget.videoPath));
    _c.initialize().then((_) {
      if (!mounted) return;
      _duration = _c.value.duration.inMilliseconds / 1000.0;
      s.start = 0;
      s.end = _duration;
      _c.addListener(_onTick);
      setState(() => _ready = true);
    });
  }

  @override
  void dispose() {
    _c.removeListener(_onTick);
    _c.dispose();
    _textCtrl.dispose();
    super.dispose();
  }

  // Keep playback inside the trimmed range.
  void _onTick() {
    if (!_c.value.isInitialized || _exporting) return;
    final pos = _c.value.position.inMilliseconds / 1000.0;
    if (_c.value.isPlaying && pos >= s.end) {
      _seekTo(s.start);
    }
    if (mounted) setState(() {});
  }

  void _seekTo(double seconds) {
    _c.seekTo(Duration(milliseconds: (seconds * 1000).round()));
  }

  void _togglePlay() {
    if (_c.value.isPlaying) {
      _c.pause();
    } else {
      final pos = _c.value.position.inMilliseconds / 1000.0;
      if (pos < s.start || pos >= s.end) _seekTo(s.start);
      _c.play();
    }
    setState(() {});
  }

  String _fmt(double seconds) {
    final total = seconds.round();
    final m = total ~/ 60;
    final sec = total % 60;
    return '${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }

  Future<void> _pickMusic() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.audio);
    if (result == null || result.files.isEmpty) return;
    final f = result.files.single;
    if (f.path == null) return;
    setState(() {
      s.musicPath = f.path;
      s.musicName = f.name;
    });
  }

  Future<void> _export() async {
    await _c.pause();
    FocusScope.of(context).unfocus();
    setState(() {
      _exporting = true;
      _progress = 0;
    });

    final result = await ExportService.export(
      inputPath: widget.videoPath,
      s: s,
      onProgress: (p) {
        if (mounted) setState(() => _progress = p);
      },
    );

    if (!mounted) return;
    setState(() => _exporting = false);

    final path = result.path;
    if (path == null) {
      showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Export failed'),
          content: SingleChildScrollView(
            child: Text(result.error ?? 'Unknown error'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }

    await ProjectStore.add(path);
    if (!mounted) return;
    // Ad is shown only AFTER the export has finished.
    AdService.showInterstitial(() {
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => ExportScreen(path: path)),
      );
    });
  }

  // ------------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_exporting,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Editor'),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FilledButton(
                onPressed: (_ready && !_exporting) ? _export : null,
                child: const Text('Export'),
              ),
            ),
          ],
        ),
        body: SafeArea(
          child: Stack(
            children: [
              if (!_ready)
                const Center(child: CircularProgressIndicator())
              else
                Column(
                  children: [
                    Expanded(child: _buildPreview()),
                    _buildTransport(),
                    SizedBox(
                      height: 210,
                      child: Container(
                        width: double.infinity,
                        color: const Color(0xFF14141B),
                        padding: const EdgeInsets.all(14),
                        child: SingleChildScrollView(child: _buildPanel()),
                      ),
                    ),
                    _buildToolBar(),
                  ],
                ),
              if (_exporting) _buildExportOverlay(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPreview() {
    final alignment = switch (s.textPos) {
      TextPos.top => const Alignment(0, -0.84),
      TextPos.middle => Alignment.center,
      TextPos.bottom => const Alignment(0, 0.84),
    };

    return Center(
      child: GestureDetector(
        onTap: _togglePlay,
        child: AspectRatio(
          aspectRatio: _c.value.aspectRatio,
          child: LayoutBuilder(
            builder: (context, box) {
              final fontSize = box.maxHeight / kTextDivisors[s.textSizeIndex];
              return Stack(
                fit: StackFit.expand,
                children: [
                  ColorFiltered(
                    colorFilter: ColorFilter.matrix(s.filter.matrix),
                    child: VideoPlayer(_c),
                  ),
                  if (s.hasText)
                    Align(
                      alignment: alignment,
                      child: Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: fontSize * 0.4,
                          vertical: fontSize * 0.25,
                        ),
                        color: const Color(0x73000000),
                        child: Text(
                          s.text.trim(),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: fontSize,
                            fontWeight: FontWeight.bold,
                            color: kTextColors[s.textColorIndex].color,
                          ),
                        ),
                      ),
                    ),
                  if (!_c.value.isPlaying)
                    const Center(
                      child: Icon(
                        Icons.play_circle_fill,
                        size: 64,
                        color: Colors.white70,
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildTransport() {
    final pos = _c.value.position.inMilliseconds / 1000.0;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          IconButton(
            onPressed: _togglePlay,
            icon: Icon(_c.value.isPlaying ? Icons.pause : Icons.play_arrow),
          ),
          Text(
            '${_fmt(pos)} / ${_fmt(_duration)}',
            style: const TextStyle(color: Colors.white70),
          ),
          const Spacer(),
          Text(
            'Output ${_fmt(s.outputSeconds)}',
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildToolBar() {
    Widget item(Tool t, IconData icon, String label) {
      final active = _tool == t;
      final color = active
          ? Theme.of(context).colorScheme.primary
          : Colors.white60;
      return Expanded(
        child: InkWell(
          onTap: () => setState(() => _tool = t),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: color),
                const SizedBox(height: 2),
                Text(label, style: TextStyle(color: color, fontSize: 12)),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      color: const Color(0xFF0B0B0F),
      child: Row(
        children: [
          item(Tool.trim, Icons.content_cut, 'Trim'),
          item(Tool.speed, Icons.speed, 'Speed'),
          item(Tool.filters, Icons.auto_awesome, 'Filters'),
          item(Tool.text, Icons.title, 'Text'),
          item(Tool.music, Icons.music_note, 'Music'),
        ],
      ),
    );
  }

  Widget _buildPanel() {
    switch (_tool) {
      case Tool.trim:
        return _trimPanel();
      case Tool.speed:
        return _speedPanel();
      case Tool.filters:
        return _filterPanel();
      case Tool.text:
        return _textPanel();
      case Tool.music:
        return _musicPanel();
    }
  }

  Widget _trimPanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Trim', style: TextStyle(fontWeight: FontWeight.w700)),
        RangeSlider(
          values: RangeValues(s.start, s.end),
          min: 0,
          max: _duration <= 0 ? 1 : _duration,
          onChanged: (v) {
            if (v.end - v.start < 0.5) return;
            setState(() {
              s.start = v.start;
              s.end = v.end;
            });
          },
          onChangeEnd: (_) => _seekTo(s.start),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Start ${_fmt(s.start)}'),
            Text('End ${_fmt(s.end)}'),
          ],
        ),
      ],
    );
  }

  Widget _speedPanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Speed', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          children: [
            for (final v in kSpeeds)
              ChoiceChip(
                label: Text('${v}x'),
                selected: s.speed == v,
                onSelected: (_) {
                  setState(() => s.speed = v);
                  _c.setPlaybackSpeed(v);
                },
              ),
          ],
        ),
      ],
    );
  }

  Widget _filterPanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Filters', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          children: [
            for (final f in kFilters)
              ChoiceChip(
                label: Text(f.label),
                selected: s.filter.id == f.id,
                onSelected: (_) => setState(() => s.filter = f),
              ),
          ],
        ),
      ],
    );
  }

  Widget _textPanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Text', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        TextField(
          controller: _textCtrl,
          maxLines: 2,
          decoration: const InputDecoration(
            hintText: 'Type your caption',
            isDense: true,
            border: OutlineInputBorder(),
          ),
          onChanged: (v) => setState(() => s.text = v),
        ),
        const SizedBox(height: 10),
        SegmentedButton<TextPos>(
          segments: const [
            ButtonSegment(value: TextPos.top, label: Text('Top')),
            ButtonSegment(value: TextPos.middle, label: Text('Middle')),
            ButtonSegment(value: TextPos.bottom, label: Text('Bottom')),
          ],
          selected: {s.textPos},
          onSelectionChanged: (v) => setState(() => s.textPos = v.first),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            for (var i = 0; i < kTextColors.length; i++)
              GestureDetector(
                onTap: () => setState(() => s.textColorIndex = i),
                child: Container(
                  width: 30,
                  height: 30,
                  margin: const EdgeInsets.only(right: 10),
                  decoration: BoxDecoration(
                    color: kTextColors[i].color,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: s.textColorIndex == i
                          ? Colors.white
                          : Colors.transparent,
                      width: 3,
                    ),
                  ),
                ),
              ),
            const Spacer(),
            for (var i = 0; i < kTextSizeLabels.length; i++)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: ChoiceChip(
                  label: Text(kTextSizeLabels[i]),
                  selected: s.textSizeIndex == i,
                  onSelected: (_) => setState(() => s.textSizeIndex = i),
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _musicPanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Music', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 10),
        Row(
          children: [
            FilledButton.tonalIcon(
              onPressed: _pickMusic,
              icon: const Icon(Icons.library_music),
              label: Text(s.musicName == null ? 'Pick audio' : 'Change'),
            ),
            const SizedBox(width: 10),
            if (s.musicName != null)
              Expanded(
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        s.musicName!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      onPressed: () => setState(() {
                        s.musicPath = null;
                        s.musicName = null;
                      }),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
          ],
        ),
        if (s.musicName != null) ...[
          const SizedBox(height: 4),
          Row(
            children: [
              const Icon(Icons.volume_up, size: 20),
              Expanded(
                child: Slider(
                  value: s.musicVolume,
                  min: 0,
                  max: 1.5,
                  onChanged: (v) => setState(() => s.musicVolume = v),
                ),
              ),
            ],
          ),
          const Text(
            'Music replaces the original sound. It plays on export, not in the preview.',
            style: TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ],
      ],
    );
  }

  Widget _buildExportOverlay() {
    return Positioned.fill(
      child: AbsorbPointer(
        child: Container(
          color: const Color(0xCC000000),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 90,
                  height: 90,
                  child: CircularProgressIndicator(
                    value: _progress > 0 ? _progress : null,
                    strokeWidth: 6,
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  _progress > 0
                      ? 'Exporting ${(_progress * 100).round()}%'
                      : 'Exporting...',
                  style: const TextStyle(fontSize: 16),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Keep the app open',
                  style: TextStyle(color: Colors.white54),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
