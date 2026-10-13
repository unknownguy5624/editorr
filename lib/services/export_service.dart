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

  /// Grabs [count] evenly spaced frames for the trim bar.
  static Future<List<String>> thumbnails(
    String input,
    double duration, {
    int count = 8,
  }) async {
    try {
      if (duration <= 0) return [];
      final tmp = await getTemporaryDirectory();
      final dir = Directory(
        '${tmp.path}/thumbs_${DateTime.now().millisecondsSinceEpoch}',
      );
      await dir.create(recursive: true);

      final rate = (count / duration).toStringAsFixed(5);
      final done = Completer<void>();
      await FFmpegKit.executeWithArgumentsAsync(
        [
          '-y',
          '-i', input,
          '-vf', 'fps=$rate,scale=-2:120',
          '-frames:v', '$count',
          '-q:v', '5',
          '${dir.path}/t%02d.jpg',
        ],
        (session) async {
          if (!done.isCompleted) done.complete();
        },
      );
      await done.future;

      final files = dir
          .listSync()
          .whereType<File>()
          .map((f) => f.path)
          .where((p) => p.endsWith('.jpg'))
          .toList()
        ..sort();
      return files;
    } catch (_) {
      return [];
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

      final hasMusic = s.musicPath != null;
      final overlays = s.overlays;
      final duration = s.end - s.start;
      final outSeconds = s.outputSeconds;

      // ---- inputs ----
      final args = <String>[
        '-y',
        '-hide_banner',
        '-ss', s.start.toStringAsFixed(3),
        '-t', duration.toStringAsFixed(3),
        '-i', inputPath,
      ];
      for (final o in overlays) {
        args.addAll(['-loop', '1', '-i', o.path]);
      }
      final musicIndex = 1 + overlays.length;
      if (hasMusic) {
        args.addAll(['-stream_loop', '-1', '-i', s.musicPath!]);
      }

      // ---- video graph ----
      final pre = <String>[];
      if (s.speed != 1.0) pre.add('setpts=PTS/${s.speed}');
      if (s.filter.ffmpeg != null) pre.add(s.filter.ffmpeg!);

      final g = <String>[];
      g.add('[0:v]${pre.isEmpty ? 'null' : pre.join(',')}[b0]');
      var last = 'b0';

      for (var k = 0; k < overlays.length; k++) {
        final o = overlays[k];
        final idx = k + 1;
        final wf = o.widthFrac.toStringAsFixed(4);
        final fx = o.fx.toStringAsFixed(4);
        final fy = o.fy.toStringAsFixed(4);
        g.add('[$idx:v]format=rgba[o$k]');
        g.add(
          '[o$k][$last]scale2ref=w=trunc(main_w*$wf/2)*2:h=trunc(ow/a/2)*2'
          '[os$k][r$k]',
        );
        g.add(
          '[r$k][os$k]overlay=x=W*$fx-w/2:y=H*$fy-h/2:shortest=1[b${k + 1}]',
        );
        last = 'b${k + 1}';
      }

      if (s.hasText) {
        final font = await _fontPath();
        final textFile = File('${tmp.path}/text_$stamp.txt');
        await textFile.writeAsString(s.text.trim());
        final color = kTextColors[s.textColorIndex].hex;
        final size = s.textSize.toStringAsFixed(4);
        final tx = s.textX.toStringAsFixed(4);
        final ty = s.textY.toStringAsFixed(4);
        var border = (s.videoHeight * 0.012).round();
        if (border < 6) border = 6;
        g.add(
          '[$last]drawtext=fontfile=$font:textfile=${textFile.path}'
          ':expansion=none:fontcolor=0x$color:fontsize=h*$size'
          ':x=w*$tx-text_w/2:y=h*$ty-text_h/2'
          ':box=1:boxcolor=0x000000@0.45:boxborderw=$border[bt]',
        );
        last = 'bt';
      }

      // H.264 needs even dimensions.
      g.add('[$last]scale=trunc(iw/2)*2:trunc(ih/2)*2[vout]');

      args.addAll(['-filter_complex', g.join(';')]);
      args.addAll(['-map', '[vout]']);

      // ---- audio ----
      if (hasMusic) {
        args.addAll(['-map', '$musicIndex:a:0']);
        args.addAll(['-af', 'volume=${s.musicVolume.toStringAsFixed(2)}']);
      } else {
        args.addAll(['-map', '0:a?']);
        if (s.speed != 1.0) args.addAll(['-af', 'atempo=${s.speed}']);
      }

      args.addAll([
        '-c:v', 'libx264',
        '-preset', 'veryfast',
        '-crf', '23',
        '-pix_fmt', 'yuv420p',
        '-c:a', 'aac',
        '-b:a', '128k',
        '-movflags', '+faststart',
        '-t', outSeconds.toStringAsFixed(3),
        outPath,
      ]);

      // ---- run ----
      final outMs = outSeconds * 1000;
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
                logs.length > 700 ? logs.substring(logs.length - 700) : logs;
            done.complete(
              ExportResult.fail(tail.isEmpty ? 'Export failed' : tail),
            );
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
