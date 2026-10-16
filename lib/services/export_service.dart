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

  /// Grabs [count] evenly spaced frames for the trim bar / timeline.
  static Future<List<String>> thumbnails(
    String input,
    double duration, {
    int count = 8,
  }) async {
    try {
      if (duration <= 0) return [];
      final tmp = await getTemporaryDirectory();
      final dir = Directory(
        '${tmp.path}/thumbs_${DateTime.now().microsecondsSinceEpoch}',
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

  /// True if the file has an audio track (read from ffmpeg's own report).
  static Future<bool> hasAudio(String path) async {
    try {
      final done = Completer<String>();
      await FFmpegKit.executeWithArgumentsAsync(
        ['-hide_banner', '-i', path],
        (session) async {
          final logs = await session.getAllLogsAsString() ?? '';
          if (!done.isCompleted) done.complete(logs);
        },
      );
      final logs = await done.future;
      if (!logs.contains('Input #0')) return true; // could not tell
      return RegExp(r'Stream #\d+:\d+.*Audio:').hasMatch(logs);
    } catch (_) {
      return true;
    }
  }

  /// Joins all clips, applies filter/overlays/text/music, and renders an MP4.
  static Future<ExportResult> export({
    required EditSettings s,
    required void Function(double progress) onProgress,
  }) async {
    try {
      final clips = s.clips;
      if (clips.isEmpty) return const ExportResult.fail('No clips to export');

      final tmp = await getTemporaryDirectory();
      final docs = await getApplicationDocumentsDirectory();
      final outDir = Directory('${docs.path}/exports');
      if (!await outDir.exists()) await outDir.create(recursive: true);

      final stamp = DateTime.now().millisecondsSinceEpoch;
      final outPath = '${outDir.path}/quickcut_$stamp.mp4';

      final hasMusic = s.musicPath != null;
      final overlays = s.overlays;
      final n = clips.length;
      final outSeconds = s.outputSeconds;

      // ---- canvas size: taken from the first clip, capped at 1920 ----
      var cw = clips.first.width;
      var ch = clips.first.height;
      final longSide = cw > ch ? cw : ch;
      if (longSide > 1920) {
        final f = 1920 / longSide;
        cw *= f;
        ch *= f;
      }
      var W = cw.round();
      var H = ch.round();
      W = W - (W % 2);
      H = H - (H % 2);
      if (W < 2) W = 2;
      if (H < 2) H = 2;

      // ---- does each clip have sound? ----
      final audioFlags = <bool>[];
      if (!hasMusic) {
        final cache = <String, bool>{};
        for (final c in clips) {
          audioFlags.add(cache[c.path] ??= await hasAudio(c.path));
        }
      }

      // ---- inputs ----
      final args = <String>['-y', '-hide_banner'];
      for (final c in clips) {
        args.addAll([
          '-ss', c.start.toStringAsFixed(3),
          '-t', (c.end - c.start).toStringAsFixed(3),
          '-i', c.path,
        ]);
      }
      for (final o in overlays) {
        args.addAll(['-loop', '1', '-i', o.path]);
      }
      final musicIndex = n + overlays.length;
      if (hasMusic) {
        args.addAll(['-stream_loop', '-1', '-i', s.musicPath!]);
      }

      // ---- filter graph ----
      final g = <String>[];

      // 1) every clip -> same size, same frame rate (+ matching audio)
      for (var i = 0; i < n; i++) {
        final c = clips[i];
        g.add(
          '[$i:v]setpts=PTS/${c.speed},'
          'scale=$W:$H:force_original_aspect_ratio=decrease,'
          'pad=$W:$H:(ow-iw)/2:(oh-ih)/2:black,setsar=1,fps=30[v$i]',
        );
        if (!hasMusic) {
          final d = c.outSeconds.toStringAsFixed(3);
          if (audioFlags[i]) {
            final tempo = c.speed != 1.0 ? 'atempo=${c.speed},' : '';
            g.add(
              '[$i:a]${tempo}aresample=44100,'
              'aformat=sample_fmts=fltp:channel_layouts=stereo,'
              'apad=whole_dur=$d,atrim=duration=$d[a$i]',
            );
          } else {
            g.add(
              'anullsrc=channel_layout=stereo:sample_rate=44100,'
              'atrim=duration=$d,asetpts=PTS-STARTPTS,'
              'aformat=sample_fmts=fltp:channel_layouts=stereo[a$i]',
            );
          }
        }
      }

      // 2) join them
      final labels = StringBuffer();
      for (var i = 0; i < n; i++) {
        labels.write(hasMusic ? '[v$i]' : '[v$i][a$i]');
      }
      g.add(
        hasMusic
            ? '${labels}concat=n=$n:v=1:a=0[vc]'
            : '${labels}concat=n=$n:v=1:a=1[vc][ac]',
      );

      // 3) look (filter) on the whole video
      g.add('[vc]${s.filter.ffmpeg ?? 'null'}[b0]');
      var last = 'b0';

      // 4) image overlays
      for (var k = 0; k < overlays.length; k++) {
        final o = overlays[k];
        final idx = n + k;
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

      // 5) text
      if (s.hasText) {
        final font = await _fontPath();
        final textFile = File('${tmp.path}/text_$stamp.txt');
        await textFile.writeAsString(s.text.trim());
        final color = kTextColors[s.textColorIndex].hex;
        final size = s.textSize.toStringAsFixed(4);
        final tx = s.textX.toStringAsFixed(4);
        final ty = s.textY.toStringAsFixed(4);
        var border = (H * 0.012).round();
        if (border < 6) border = 6;
        g.add(
          '[$last]drawtext=fontfile=$font:textfile=${textFile.path}'
          ':expansion=none:fontcolor=0x$color:fontsize=h*$size'
          ':x=w*$tx-text_w/2:y=h*$ty-text_h/2'
          ':box=1:boxcolor=0x000000@0.45:boxborderw=$border[bt]',
        );
        last = 'bt';
      }

      // 6) H.264 needs even dimensions
      g.add('[$last]scale=trunc(iw/2)*2:trunc(ih/2)*2[vout]');

      // 7) music volume
      if (hasMusic) {
        g.add('[$musicIndex:a]volume=${s.musicVolume.toStringAsFixed(2)}[am]');
      }

      args.addAll(['-filter_complex', g.join(';')]);
      args.addAll(['-map', '[vout]']);
      args.addAll(['-map', hasMusic ? '[am]' : '[ac]']);

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
