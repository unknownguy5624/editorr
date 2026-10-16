import 'package:flutter/material.dart';

/// A look the user can apply. [ffmpeg] is the real filter used on export,
/// [matrix] is a close approximation used for the live preview.
class FilterPreset {
  final String id;
  final String label;
  final String? ffmpeg;
  final List<double> matrix;

  const FilterPreset(this.id, this.label, this.ffmpeg, this.matrix);
}

const List<double> _identity = [
  1, 0, 0, 0, 0, //
  0, 1, 0, 0, 0,
  0, 0, 1, 0, 0,
  0, 0, 0, 1, 0,
];

const List<FilterPreset> kFilters = [
  FilterPreset('none', 'Original', null, _identity),
  FilterPreset(
    'bright',
    'Bright',
    'eq=brightness=0.06:contrast=1.1:saturation=1.15',
    [
      1.1, 0, 0, 0, 15, //
      0, 1.1, 0, 0, 15,
      0, 0, 1.1, 0, 15,
      0, 0, 0, 1, 0,
    ],
  ),
  FilterPreset(
    'vivid',
    'Vivid',
    'eq=contrast=1.1:saturation=1.5',
    [
      1.3937, -0.3576, -0.0361, 0, 0, //
      -0.1063, 1.1424, -0.0361, 0, 0,
      -0.1063, -0.3576, 1.4639, 0, 0,
      0, 0, 0, 1, 0,
    ],
  ),
  FilterPreset(
    'bw',
    'B&W',
    'hue=s=0',
    [
      0.2126, 0.7152, 0.0722, 0, 0, //
      0.2126, 0.7152, 0.0722, 0, 0,
      0.2126, 0.7152, 0.0722, 0, 0,
      0, 0, 0, 1, 0,
    ],
  ),
  FilterPreset(
    'sepia',
    'Sepia',
    'colorchannelmixer=.393:.769:.189:0:.349:.686:.168:0:.272:.534:.131',
    [
      0.393, 0.769, 0.189, 0, 0, //
      0.349, 0.686, 0.168, 0, 0,
      0.272, 0.534, 0.131, 0, 0,
      0, 0, 0, 1, 0,
    ],
  ),
  FilterPreset(
    'cool',
    'Cool',
    'colorbalance=bs=0.25:ms=0.1',
    [
      0.9, 0, 0, 0, 0, //
      0, 1, 0, 0, 0,
      0, 0, 1.15, 0, 10,
      0, 0, 0, 1, 0,
    ],
  ),
  FilterPreset(
    'warm',
    'Warm',
    'colorbalance=rs=0.25:ms=0.1',
    [
      1.1, 0, 0, 0, 10, //
      0, 1, 0, 0, 0,
      0, 0, 0.88, 0, 0,
      0, 0, 0, 1, 0,
    ],
  ),
];

class TextColorOption {
  final Color color;
  final String hex; // RRGGBB, used by ffmpeg
  const TextColorOption(this.color, this.hex);
}

const List<TextColorOption> kTextColors = [
  TextColorOption(Color(0xFFFFFFFF), 'FFFFFF'),
  TextColorOption(Color(0xFFFFEB3B), 'FFEB3B'),
  TextColorOption(Color(0xFFFF5252), 'FF5252'),
  TextColorOption(Color(0xFF40C4FF), '40C4FF'),
  TextColorOption(Color(0xFF69F0AE), '69F0AE'),
];

/// Text size presets, as a fraction of the video height.
const List<double> kTextSizes = [0.04, 0.06, 0.10];
const List<String> kTextSizeLabels = ['S', 'M', 'L'];

const List<double> kSpeeds = [0.5, 1.0, 1.5, 2.0];

/// One piece of video on the timeline.
class ClipItem {
  final String path;
  final double duration; // full source length, seconds
  final double width;
  final double height;
  double start; // trim start inside the source, seconds
  double end; // trim end inside the source, seconds
  double speed = 1.0;
  List<String> thumbs = [];

  ClipItem({
    required this.path,
    required this.duration,
    required this.width,
    required this.height,
  })  : start = 0,
        end = duration;

  ClipItem copy() {
    final c = ClipItem(
      path: path,
      duration: duration,
      width: width,
      height: height,
    );
    c.start = start;
    c.end = end;
    c.speed = speed;
    c.thumbs = thumbs;
    return c;
  }

  /// Length of this clip in the finished video.
  double get outSeconds => (end - start) / speed;
}

/// An image placed on top of the video. Position is the CENTRE of the
/// image as a fraction of the video (0..1); width is a fraction of video width.
class OverlayItem {
  final String path;
  double fx = 0.5;
  double fy = 0.5;
  double widthFrac = 0.3;
  OverlayItem(this.path);
}

/// Everything the user has chosen in the editor.
class EditSettings {
  final List<ClipItem> clips = [];
  FilterPreset filter = kFilters.first;

  String text = '';
  double textX = 0.5; // centre, fraction of video width
  double textY = 0.82; // centre, fraction of video height
  double textSize = 0.06; // fraction of video height
  int textColorIndex = 0;

  final List<OverlayItem> overlays = [];

  String? musicPath;
  String? musicName;
  double musicVolume = 1.0;

  bool get hasText => text.trim().isNotEmpty;
  double get outputSeconds => clips.fold(0.0, (a, c) => a + c.outSeconds);
}
