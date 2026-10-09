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

enum TextPos { top, middle, bottom }

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

/// Font size = video height / divisor. Smaller divisor = bigger text.
const List<double> kTextDivisors = [24, 16, 10];
const List<String> kTextSizeLabels = ['S', 'M', 'L'];

const List<double> kSpeeds = [0.5, 1.0, 1.5, 2.0];

/// Everything the user has chosen in the editor.
class EditSettings {
  double start = 0; // seconds
  double end = 0; // seconds
  double speed = 1.0;
  FilterPreset filter = kFilters.first;

  String text = '';
  TextPos textPos = TextPos.bottom;
  int textColorIndex = 0;
  int textSizeIndex = 1;

  String? musicPath;
  String? musicName;
  double musicVolume = 1.0;

  bool get hasText => text.trim().isNotEmpty;
  double get outputSeconds => (end - start) / speed;
}
