import 'dart:async';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import 'edit_settings.dart';

class ExportResult {
  final String? path;
  final String? error;
  const ExportResult.ok(this.path) : error = null;
  const ExportResult.fail(this.error) : path = null;
}

class ExportService {
  static Future<String> _fontPath() async {
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/text_font.ttf');
    if (!await f.exists()) {
      final data = await rootBundle.load('assets/fonts/text_font.ttf');
      await f.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
    }
    return f.path;
  }

  static String _yExpr(TextPos p) {
    switch (p) {
      case TextPos.top:
        return 'h*0.08';
      case TextPos.middle:
        return '(h-text_h)/2';
      case TextPos.bottom:
        return 'h*0.82-text_h';
    }
  }

  /// Renders the edited video to an MP4 and returns its path.
  static Future<ExportResult> export({
    required String inputPath,
    required EditSettings s,
    required void Function(double progress) onProgress,
  }) async {
    try {
      final tmp = await getTemporaryDirectory();
      final docs = await getApplicationDocumentsDirectory();
      final outDir = Directory('${docs.path}/exports');
      if (!await outDir.exists()) await outDir.create(recursive: true);

      final stamp = DateTime.now().millisecondsSinceEpoch;
      final outPath = '${outDir.path}/quickcut_$stamp.mp4';

      // ---- video filter chain ----
      final vf = <String>[];
      if (s.speed != 1.0) vf.add('setpts=PTS/${s.speed}');
      if (s.filter.ffmpeg != null) vf.add(s.filter.ffmpeg!);
      if (s.hasText) {
        final font = await _fontPath();
        final textFile = File('${tmp.path}/text_$stamp.txt');
        await textFile.writeAsString(s.text.trim());
        final color = kTextColors[s.textColorIndex].hex;
        final div = kTextDivisors[s.textSizeIndex].toInt();
        vf.add(
          'drawtext=fontfile=${font}:textfile=${textFile.path}:expansion=none'
          ':fontcolor=0x$color:fontsize=h/$div'
          ':x=(w-text_w)/2:y=${_yExpr(s.textPos)}'
          ':box=1:boxcolor=0x000000@0.45:boxborderw=14',
        );
      }
      // H.264 needs even dimensions.
      vf.add('scale=trunc(iw/2)*2:trunc(ih/2)*2');

      final hasMusic = s.musicPath != null;
      final duration = s.end - s.start;

      // ---- arguments ----
      final args = <String>[
        '-y',
        '-hide_banner',
        '-ss', s.start.toStringAsFixed(3),
        '-t', duration.toStringAsFixed(3),
        '-i', inputPath,
      ];

      if (hasMusic) {
        args.addAll(['-stream_loop', '-1', '-i', s.musicPath!]);
        args.addAll(['-map', '0:v:0', '-map', '1:a:0']);
        args.addAll(['-af', 'volume=${s.musicVolume.toStringAsFixed(2)}']);
      } else {
        args.addAll(['-map', '0:v:0', '-map', '0:a?']);
        if (s.speed != 1.0) args.addAll(['-af', 'atempo=${s.speed}']);
      }

      args.addAll([
        '-vf', vf.join(','),
        '-c:v', 'libx264',
        '-preset', 'veryfast',
        '-crf', '23',
        '-pix_fmt', 'yuv420p',
        '-c:a', 'aac',
        '-b:a', '128k',
        '-movflags', '+faststart',
      ]);
      if (hasMusic) args.add('-shortest');
      args.add(outPath);

      // ---- run ----
      final outMs = s.outputSeconds * 1000;
      final done = Completer<ExportResult>();

      await FFmpegKit.executeWithArgumentsAsync(
        args,
        (session) async {
          final rc = await session.getReturnCode();
          final ok = rc != null && rc.getValue() == 0;
          final file = File(outPath);
          if (ok && await file.exists() && await file.length() > 0) {
            done.complete(ExportResult.ok(outPath));
          } else {
            final logs = await session.getAllLogsAsString() ?? '';
            final tail =
                logs.length > 600 ? logs.substring(logs.length - 600) : logs;
            done.complete(ExportResult.fail(tail.isEmpty ? 'Export failed' : tail));
          }
        },
        null,
        (stats) {
          final t = (stats.getTime() as num).toDouble();
          if (t > 0 && outMs > 0) {
            onProgress((t / outMs).clamp(0.0, 1.0));
          }
        },
      );

      return await done.future;
    } catch (e) {
      return ExportResult.fail(e.toString());
    }
  }
}
