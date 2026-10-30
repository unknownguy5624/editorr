import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';

import '../services/ad_service.dart';
import '../services/cutout_service.dart';
import '../services/edit_settings.dart';
import '../services/export_service.dart';
import '../services/project_store.dart';
import 'export_screen.dart';
import 'trim_bar.dart';

enum Tool { clip, trim, speed, cutout, filters, text, overlay, music }

class EditorScreen extends StatefulWidget {
  final String videoPath;
  const EditorScreen({super.key, required this.videoPath});

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  final EditSettings s = EditSettings();
  final TextEditingController _textCtrl = TextEditingController();

  VideoPlayerController? _c;
  bool _ready = false; // current clip is loaded in the player
  int _sel = 0; // selected clip index
  int _loadToken = 0;
  Tool _tool = Tool.clip;
  bool _exporting = false;
  double _progress = 0;
  double _baseSize = 0.3; // size at the start of a pinch gesture
  bool _failedToLoad = false;

  // background removal
  CutoutBackground _cutBg = CutoutBackground.blur;
  String? _cutBgImage;
  bool _cutting = false;
  double _cutProgress = 0;
  String _cutLabel = '';

  bool get _busy => _exporting || _cutting;

  ClipItem get _clip => s.clips[_sel];

  @override
  void initState() {
    super.initState();
    AdService.loadInterstitial();
    _boot();
  }

  Future<void> _boot() async {
    final clip = await _makeClip(widget.videoPath);
    if (!mounted) return;
    if (clip == null) {
      setState(() => _failedToLoad = true);
      return;
    }
    s.clips.add(clip);
    _loadThumbs(clip);
    await _openClip(0);
  }

  @override
  void dispose() {
    _loadToken++;
    _c?.removeListener(_onTick);
    _c?.dispose();
    _textCtrl.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------ clips

  Future<ClipItem?> _makeClip(String path) async {
    final tmp = VideoPlayerController.file(File(path));
    try {
      await tmp.initialize();
      final d = tmp.value.duration.inMilliseconds / 1000.0;
      final size = tmp.value.size;
      if (d <= 0) return null;
      return ClipItem(
        path: path,
        duration: d,
        width: size.width,
        height: size.height,
      );
    } catch (_) {
      return null;
    } finally {
      await tmp.dispose();
    }
  }

  void _loadThumbs(ClipItem c) {
    ExportService.thumbnails(c.path, c.duration).then((t) {
      c.thumbs = t;
      if (mounted) setState(() {});
    });
  }

  /// Loads clip [i] into the preview player.
  Future<void> _openClip(int i) async {
    final token = ++_loadToken;
    final old = _c;
    old?.removeListener(_onTick);
    _c = null;
    if (mounted) {
      setState(() {
        _sel = i;
        _ready = false;
      });
    }
    await old?.dispose();

    final clip = s.clips[i];
    final c = VideoPlayerController.file(File(clip.path));
    try {
      await c.initialize();
    } catch (_) {
      await c.dispose();
      return;
    }
    if (token != _loadToken || !mounted) {
      await c.dispose();
      return;
    }
    await c.setPlaybackSpeed(clip.speed);
    await c.seekTo(Duration(milliseconds: (clip.start * 1000).round()));
    c.addListener(_onTick);
    _c = c;
    setState(() => _ready = true);
  }

  Future<void> _addClip() async {
    final picked = await ImagePicker().pickVideo(source: ImageSource.gallery);
    if (picked == null || !mounted) return;
    final clip = await _makeClip(picked.path);
    if (!mounted) return;
    if (clip == null) {
      _toast('Could not open that video');
      return;
    }
    s.clips.add(clip);
    _loadThumbs(clip);
    await _openClip(s.clips.length - 1);
  }

  void _splitClip() {
    final c = _clip;
    final p = _pos;
    if (p <= c.start + 0.3 || p >= c.end - 0.3) {
      _toast('Move the playhead into the middle of the clip first');
      return;
    }
    final second = c.copy();
    second.start = p;
    second.end = c.end;
    setState(() {
      c.end = p;
      s.clips.insert(_sel + 1, second);
    });
    _toast('Split done');
  }

  Future<void> _deleteClip() async {
    if (s.clips.length <= 1) {
      _toast('A project needs at least one clip');
      return;
    }
    final removeAt = _sel;
    final newSel = removeAt > 0 ? removeAt - 1 : 0;
    s.clips.removeAt(removeAt);
    await _openClip(newSel);
  }

  void _moveClip(int dir) {
    final to = _sel + dir;
    if (to < 0 || to >= s.clips.length) return;
    setState(() {
      final c = s.clips.removeAt(_sel);
      s.clips.insert(to, c);
      _sel = to;
    });
  }

  // --------------------------------------------------------- playback

  double get _pos {
    final c = _c;
    if (c == null || !c.value.isInitialized) {
      return s.clips.isEmpty ? 0 : _clip.start;
    }
    return c.value.position.inMilliseconds / 1000.0;
  }

  // Keep playback inside the trimmed range of the selected clip.
  void _onTick() {
    final c = _c;
    if (c == null || !c.value.isInitialized || _exporting) return;
    final pos = c.value.position.inMilliseconds / 1000.0;
    if (c.value.isPlaying && pos >= _clip.end) {
      _seekTo(_clip.start);
    }
    if (mounted) setState(() {});
  }

  void _seekTo(double seconds) {
    _c?.seekTo(Duration(milliseconds: (seconds * 1000).round()));
  }

  void _togglePlay() {
    final c = _c;
    if (c == null) return;
    if (c.value.isPlaying) {
      c.pause();
    } else {
      final pos = _pos;
      if (pos < _clip.start || pos >= _clip.end) _seekTo(_clip.start);
      c.play();
    }
    setState(() {});
  }

  String _fmt(double seconds) {
    final total = seconds.round();
    final m = total ~/ 60;
    final sec = total % 60;
    return '${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  // ------------------------------------------------------- pickers

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

  Future<void> _pickOverlay() async {
    if (s.overlays.length >= 3) return;
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null) return;
    setState(() {
      final item = OverlayItem(picked.path);
      item.fx = 0.5 + 0.08 * s.overlays.length;
      item.fy = 0.35 + 0.08 * s.overlays.length;
      s.overlays.add(item);
    });
  }

  // ------------------------------------------------------ background removal

  Future<void> _pickCutBgImage() async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null) return;
    setState(() {
      _cutBgImage = picked.path;
      _cutBg = CutoutBackground.image;
    });
  }

  Future<void> _runCutout() async {
    if (!_ready || _busy) return;
    await _c?.pause();
    if (!mounted) return;
    setState(() {
      _cutting = true;
      _cutProgress = 0;
      _cutLabel = 'Starting';
    });

    final r = await CutoutService.removeBackground(
      clip: _clip,
      bg: _cutBg,
      bgImagePath: _cutBgImage,
      onProgress: (label, p) {
        if (mounted) {
          setState(() {
            _cutLabel = label;
            _cutProgress = p;
          });
        }
      },
    );

    if (!mounted) return;
    setState(() => _cutting = false);

    final newClip = r.clip;
    if (newClip == null) {
      showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Background removal failed'),
          content: SingleChildScrollView(
            child: Text(r.error ?? 'Unknown error'),
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

    s.clips[_sel] = newClip;
    _loadThumbs(newClip);
    await _openClip(_sel);
    _toast('Background removed');
  }

  // --------------------------------------------------------- export

  Future<void> _export() async {
    await _c?.pause();
    if (!mounted) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _exporting = true;
      _progress = 0;
    });

    final result = await ExportService.export(
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
    final loaded = s.clips.isNotEmpty;
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Editor'),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FilledButton(
                onPressed: (loaded && _ready && !_busy) ? _export : null,
                child: const Text('Export'),
              ),
            ),
          ],
        ),
        body: SafeArea(
          child: Stack(
            children: [
              if (_failedToLoad)
                const Center(child: Text('Could not open this video'))
              else if (!loaded)
                const Center(child: CircularProgressIndicator())
              else
                Column(
                  children: [
                    Expanded(
                      child: _ready
                          ? _buildPreview()
                          : const Center(child: CircularProgressIndicator()),
                    ),
                    _buildTransport(),
                    _buildTimeline(),
                    SizedBox(
                      height: 190,
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
              if (_busy) _buildBusyOverlay(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPreview() {
    final c = _c!;
    return Center(
      child: AspectRatio(
        aspectRatio: c.value.aspectRatio,
        child: LayoutBuilder(
          builder: (context, box) {
            final w = box.maxWidth;
            final h = box.maxHeight;
            final fontSize = h * s.textSize;

            return ClipRect(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  GestureDetector(
                    onTap: _togglePlay,
                    child: ColorFiltered(
                      colorFilter: ColorFilter.matrix(s.filter.matrix),
                      child: VideoPlayer(c),
                    ),
                  ),
                  if (!c.value.isPlaying)
                    const IgnorePointer(
                      child: Center(
                        child: Icon(
                          Icons.play_circle_fill,
                          size: 64,
                          color: Colors.white70,
                        ),
                      ),
                    ),

                  // ---- image overlays (drag to move, pinch to resize) ----
                  for (final o in s.overlays)
                    Positioned(
                      left: o.fx * w,
                      top: o.fy * h,
                      child: FractionalTranslation(
                        translation: const Offset(-0.5, -0.5),
                        child: GestureDetector(
                          onScaleStart: (_) => _baseSize = o.widthFrac,
                          onScaleUpdate: (d) {
                            setState(() {
                              o.fx = (o.fx + d.focalPointDelta.dx / w)
                                  .clamp(0.0, 1.0);
                              o.fy = (o.fy + d.focalPointDelta.dy / h)
                                  .clamp(0.0, 1.0);
                              if (d.scale != 1.0) {
                                o.widthFrac =
                                    (_baseSize * d.scale).clamp(0.08, 1.0);
                              }
                            });
                          },
                          child: Image.file(
                            File(o.path),
                            width: w * o.widthFrac,
                            fit: BoxFit.contain,
                          ),
                        ),
                      ),
                    ),

                  // ---- text (drag to move, pinch to resize) ----
                  if (s.hasText)
                    Positioned(
                      left: s.textX * w,
                      top: s.textY * h,
                      child: FractionalTranslation(
                        translation: const Offset(-0.5, -0.5),
                        child: GestureDetector(
                          onScaleStart: (_) => _baseSize = s.textSize,
                          onScaleUpdate: (d) {
                            setState(() {
                              s.textX = (s.textX + d.focalPointDelta.dx / w)
                                  .clamp(0.0, 1.0);
                              s.textY = (s.textY + d.focalPointDelta.dy / h)
                                  .clamp(0.0, 1.0);
                              if (d.scale != 1.0) {
                                s.textSize =
                                    (_baseSize * d.scale).clamp(0.02, 0.2);
                              }
                            });
                          },
                          child: Container(
                            padding: EdgeInsets.symmetric(
                              horizontal: fontSize * 0.3,
                              vertical: fontSize * 0.15,
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
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildTransport() {
    final playing = _c?.value.isPlaying ?? false;
    final inClip = (_pos - _clip.start).clamp(0.0, _clip.duration);
    final clipLen = _clip.end - _clip.start;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          IconButton(
            onPressed: _ready ? _togglePlay : null,
            icon: Icon(playing ? Icons.pause : Icons.play_arrow),
          ),
          Text(
            '${_fmt(inClip)} / ${_fmt(clipLen)}',
            style: const TextStyle(color: Colors.white70),
          ),
          const Spacer(),
          Text(
            'Total ${_fmt(s.outputSeconds)}  |  Preview plays one clip',
            style: const TextStyle(color: Colors.white54, fontSize: 11),
          ),
        ],
      ),
    );
  }

  /// The clip strip: tap a clip to select it, "+" adds another.
  Widget _buildTimeline() {
    return SizedBox(
      height: 76,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        children: [
          for (var i = 0; i < s.clips.length; i++) _clipBlock(i),
          InkWell(
            onTap: _busy ? null : _addClip,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              width: 56,
              margin: const EdgeInsets.only(left: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E28),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.add, color: Colors.white70),
            ),
          ),
        ],
      ),
    );
  }

  Widget _clipBlock(int i) {
    final c = s.clips[i];
    final selected = i == _sel;
    final width = (c.outSeconds * 22).clamp(70.0, 260.0);
    return GestureDetector(
      onTap: () {
        if (i != _sel && !_busy) _openClip(i);
      },
      child: Container(
        width: width,
        margin: const EdgeInsets.only(right: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? Colors.amber : Colors.transparent,
            width: 3,
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(5),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (c.thumbs.isNotEmpty)
                Image.file(File(c.thumbs.first), fit: BoxFit.cover)
              else
                const ColoredBox(color: Color(0xFF1E1E28)),
              Positioned(
                left: 4,
                bottom: 2,
                child: Text(
                  '${i + 1}  ${_fmt(c.outSeconds)}'
                  '${c.speed != 1.0 ? '  ${c.speed}x' : ''}',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    shadows: [Shadow(blurRadius: 4, color: Colors.black)],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildToolBar() {
    Widget item(Tool t, IconData icon, String label) {
      final active = _tool == t;
      final color =
          active ? Theme.of(context).colorScheme.primary : Colors.white60;
      return InkWell(
        onTap: () => setState(() => _tool = t),
        child: SizedBox(
          width: 68,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: color),
                const SizedBox(height: 2),
                Text(label, style: TextStyle(color: color, fontSize: 11)),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      color: const Color(0xFF0B0B0F),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            item(Tool.clip, Icons.video_library_outlined, 'Clip'),
            item(Tool.trim, Icons.content_cut, 'Trim'),
            item(Tool.speed, Icons.speed, 'Speed'),
            item(Tool.cutout, Icons.person_outline, 'Cutout'),
            item(Tool.filters, Icons.auto_awesome, 'Filters'),
            item(Tool.text, Icons.title, 'Text'),
            item(Tool.overlay, Icons.layers, 'Overlay'),
            item(Tool.music, Icons.music_note, 'Music'),
          ],
        ),
      ),
    );
  }

  Widget _buildPanel() {
    switch (_tool) {
      case Tool.clip:
        return _clipPanel();
      case Tool.trim:
        return _trimPanel();
      case Tool.speed:
        return _speedPanel();
      case Tool.cutout:
        return _cutoutPanel();
      case Tool.filters:
        return _filterPanel();
      case Tool.text:
        return _textPanel();
      case Tool.overlay:
        return _overlayPanel();
      case Tool.music:
        return _musicPanel();
    }
  }

  Widget _clipPanel() {
    final c = _clip;
    final pos = _pos.clamp(c.start, c.end);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Clip ${_sel + 1} of ${s.clips.length}',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        Row(
          children: [
            const Icon(Icons.linear_scale, size: 20),
            Expanded(
              child: Slider(
                value: pos,
                min: c.start,
                max: c.end,
                onChangeStart: (_) => _c?.pause(),
                onChanged: _ready ? (v) => _seekTo(v) : null,
              ),
            ),
          ],
        ),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            FilledButton.tonalIcon(
              onPressed: _ready ? _splitClip : null,
              icon: const Icon(Icons.call_split),
              label: const Text('Split'),
            ),
            FilledButton.tonalIcon(
              onPressed: _busy ? null : _deleteClip,
              icon: const Icon(Icons.delete_outline),
              label: const Text('Delete'),
            ),
            IconButton.filledTonal(
              onPressed: _sel > 0 ? () => _moveClip(-1) : null,
              icon: const Icon(Icons.arrow_back),
            ),
            IconButton.filledTonal(
              onPressed: _sel < s.clips.length - 1 ? () => _moveClip(1) : null,
              icon: const Icon(Icons.arrow_forward),
            ),
          ],
        ),
      ],
    );
  }

  Widget _cutoutPanel() {
    final c = _clip;
    final len = c.end - c.start;
    final tooLong = len > CutoutService.maxSeconds + 0.01;
    const labels = {
      CutoutBackground.blur: 'Blur',
      CutoutBackground.black: 'Black',
      CutoutBackground.white: 'White',
      CutoutBackground.green: 'Green',
      CutoutBackground.image: 'Image',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Remove background of clip ${_sel + 1}',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final e in labels.entries)
              ChoiceChip(
                label: Text(e.value),
                selected: _cutBg == e.key,
                onSelected: (_) {
                  if (e.key == CutoutBackground.image && _cutBgImage == null) {
                    _pickCutBgImage();
                  } else {
                    setState(() => _cutBg = e.key);
                  }
                },
              ),
          ],
        ),
        if (_cutBg == CutoutBackground.image)
          TextButton.icon(
            onPressed: _pickCutBgImage,
            icon: const Icon(Icons.image_outlined),
            label: Text(
              _cutBgImage == null ? 'Pick background image' : 'Change image',
            ),
          ),
        const SizedBox(height: 4),
        FilledButton.icon(
          onPressed: (_ready && !_busy && !tooLong) ? _runCutout : null,
          icon: const Icon(Icons.person_outline),
          label: const Text('Remove background'),
        ),
        const SizedBox(height: 6),
        Text(
          tooLong
              ? 'This clip is ${len.toStringAsFixed(0)}s. Trim it to '
                  '${CutoutService.maxSeconds.toInt()}s or less first.'
              : 'Works on people. Takes a little while. Replaces this clip '
                  'with the cut-out version.',
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
      ],
    );
  }

  Widget _trimPanel() {
    final c = _clip;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Trim clip ${_sel + 1}',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 10),
        TrimBar(
          thumbs: c.thumbs,
          duration: c.duration,
          start: c.start,
          end: c.end,
          position: _pos,
          onChanged: (a, b) => setState(() {
            c.start = a;
            c.end = b;
          }),
          onChangeEnd: () => _seekTo(c.start),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Start ${_fmt(c.start)}'),
            Text('End ${_fmt(c.end)}'),
          ],
        ),
      ],
    );
  }

  Widget _speedPanel() {
    final c = _clip;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Speed of clip ${_sel + 1}',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          children: [
            for (final v in kSpeeds)
              ChoiceChip(
                label: Text('${v}x'),
                selected: c.speed == v,
                onSelected: (_) {
                  setState(() => c.speed = v);
                  _c?.setPlaybackSpeed(v);
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
        const Text(
          'Filters (whole video)',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
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
        const SizedBox(height: 6),
        const Text(
          'Drag the text on the video to move it. Pinch to resize. '
          'It shows for the whole video.',
          style: TextStyle(color: Colors.white54, fontSize: 12),
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
                  selected: (s.textSize - kTextSizes[i]).abs() < 0.011,
                  onSelected: (_) => setState(() => s.textSize = kTextSizes[i]),
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _overlayPanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Overlay', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Row(
          children: [
            FilledButton.tonalIcon(
              onPressed: s.overlays.length >= 3 ? null : _pickOverlay,
              icon: const Icon(Icons.add_photo_alternate_outlined),
              label: const Text('Add image'),
            ),
            const SizedBox(width: 10),
            Text(
              '${s.overlays.length}/3',
              style: const TextStyle(color: Colors.white54),
            ),
          ],
        ),
        const SizedBox(height: 6),
        const Text(
          'Drag an image on the video to move it. Pinch to resize. '
          'PNG images with a transparent background work best.',
          style: TextStyle(color: Colors.white54, fontSize: 12),
        ),
        const SizedBox(height: 8),
        for (var i = 0; i < s.overlays.length; i++)
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: Image.file(
                  File(s.overlays[i].path),
                  width: 36,
                  height: 36,
                  fit: BoxFit.cover,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(child: Text('Image ${i + 1}')),
              IconButton(
                onPressed: () => setState(() => s.overlays.removeAt(i)),
                icon: const Icon(Icons.delete_outline),
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

  Widget _buildBusyOverlay() {
    final title = _exporting ? 'Exporting' : _cutLabel;
    final p = _exporting ? _progress : _cutProgress;
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
                    value: p > 0 ? p : null,
                    strokeWidth: 6,
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  p > 0 ? '$title ${(p * 100).round()}%' : '$title...',
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
