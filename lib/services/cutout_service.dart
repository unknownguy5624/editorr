import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:google_mlkit_commons/google_mlkit_commons.dart';
import 'package:google_mlkit_selfie_segmentation/google_mlkit_selfie_segmentation.dart';
import 'package:path_provider/path_provider.dart';

import 'edit_settings.dart';

enum CutoutBackground { blur, black, white, green, image }

class CutoutResult {
  final ClipItem? clip;
  final String? error;
  const CutoutResult.ok(this.clip) : error = null;
  const CutoutResult.fail(this.error) : clip = null;
}

class _RunResult {
  final bool ok;
  final String logs;
  const _RunResult(this.ok, this.logs);
}

/// Removes the background from a clip (people only) using Google's free,
/// on-device selfie segmentation, then bakes the result into a NEW clip.
///
/// Steps: 1) pull small frames out of the clip  2) ML Kit finds the person
/// in every frame  3) the masks are glued back onto the video with ffmpeg
/// and put on top of the chosen background.
class CutoutService {
  static const double maxSeconds = 15;
  static const int _procFps = 12;

  static Future<_RunResult> _run(
    List<String> args, {
    void Function(double ms)? onTime,
  }) async {
    final done = Completer<_RunResult>();
    await FFmpegKit.executeWithArgumentsAsync(
      args,
      (session) async {
        final rc = await session.getReturnCode();
        final ok = rc != null && rc.getValue() == 0;
        final logs = ok ? '' : (await session.getAllLogsAsString() ?? '');
        if (!done.isCompleted) done.complete(_RunResult(ok, logs));
      },
      null,
      (stats) {
        if (onTime != null) {
          onTime((stats.getTime() as num).toDouble());
        }
      },
    );
    return done.future;
  }

  static String _tail(String s) =>
      s.length > 600 ? s.substring(s.length - 600) : s;

  /// Confidence (0..1 per pixel) -> grayscale PGM image ffmpeg can read.
  static Uint8List _toPgm(SegmentationMask m) {
    final header = 'P5\n${m.width} ${m.height}\n255\n'.codeUnits;
    final n = m.width * m.height;
    final data = Uint8List(header.length + n);
    data.setRange(0, header.length, header);
    final c = m.confidences;
    for (var j = 0; j < n && j < c.length; j++) {
      // Sharpen the edge a little: 0.3 -> 0, 0.7 -> 1
      var v = (c[j] - 0.3) / 0.4;
      if (v < 0) v = 0;
      if (v > 1) v = 1;
      data[header.length + j] = (v * 255).round();
    }
    return data;
  }

  static Future<CutoutResult> removeBackground({
    required ClipItem clip,
    required CutoutBackground bg,
    String? bgImagePath,
    required void Function(String label, double progress) onProgress,
  }) async {
    final len = clip.end - clip.start;
    if (len > maxSeconds + 0.01) {
      return CutoutResult.fail(
        'This clip is ${len.toStringAsFixed(0)} seconds long. '
        'Trim it to ${maxSeconds.toInt()} seconds or less first.',
      );
    }
    if (bg == CutoutBackground.image && bgImagePath == null) {
      return const CutoutResult.fail('Pick a background image first.');
    }

    final tmp = await getTemporaryDirectory();
    final docs = await getApplicationDocumentsDirectory();
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final work = Directory('${tmp.path}/cutout_$stamp');
    final framesDir = Directory('${work.path}/frames');
    final masksDir = Directory('${work.path}/masks');
    final outDir = Directory('${docs.path}/cutouts');
    await framesDir.create(recursive: true);
    await masksDir.create(recursive: true);
    await outDir.create(recursive: true);
    final outPath = '${outDir.path}/cutout_$stamp.mp4';

    SelfieSegmenter? segmenter;
    try {
      // ---- 1) small frames ----
      onProgress('Reading frames', 0.02);
      final r1 = await _run([
        '-y',
        '-ss', clip.start.toStringAsFixed(3),
        '-t', len.toStringAsFixed(3),
        '-i', clip.path,
        '-vf', 'fps=$_procFps,scale=-2:256',
        '-q:v', '3',
        '${framesDir.path}/f%04d.jpg',
      ]);
      if (!r1.ok) {
        return CutoutResult.fail('Could not read frames.\n${_tail(r1.logs)}');
      }
      final frames = framesDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.jpg'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      if (frames.isEmpty) {
        return const CutoutResult.fail('No frames could be read.');
      }

      // ---- 2) find the person in every frame ----
      segmenter = SelfieSegmenter(
        mode: SegmenterMode.single,
        enableRawSizeMask: false,
      );
      Uint8List? previous;
      for (var i = 0; i < frames.length; i++) {
        final mask = await segmenter.processImage(
          InputImage.fromFilePath(frames[i].path),
        );
        Uint8List bytes;
        if (mask == null || mask.width <= 0 || mask.height <= 0) {
          if (previous == null) {
            return const CutoutResult.fail(
              'Could not find a person in this clip. '
              'Background removal works on people.',
            );
          }
          bytes = previous;
        } else {
          bytes = _toPgm(mask);
          previous = bytes;
        }
        final name = (i + 1).toString().padLeft(4, '0');
        await File('${masksDir.path}/m$name.pgm').writeAsBytes(bytes);
        onProgress('Finding the person', 0.05 + 0.75 * (i + 1) / frames.length);
      }

      // ---- 3) put the person on the new background ----
      onProgress('Building the video', 0.82);

      var cw = clip.width;
      var ch = clip.height;
      final longSide = cw > ch ? cw : ch;
      if (longSide > 1280) {
        final f = 1280 / longSide;
        cw *= f;
        ch *= f;
      }
      var W = cw.round();
      var H = ch.round();
      W = W - (W % 2);
      H = H - (H % 2);
      if (W < 2) W = 2;
      if (H < 2) H = 2;

      final args = <String>[
        '-y',
        '-hide_banner',
        '-ss', clip.start.toStringAsFixed(3),
        '-t', len.toStringAsFixed(3),
        '-i', clip.path,
        '-framerate', '$_procFps',
        '-i', '${masksDir.path}/m%04d.pgm',
      ];
      if (bg == CutoutBackground.image) {
        args.addAll(['-loop', '1', '-i', bgImagePath!]);
      }

      final g = <String>[];
      if (bg == CutoutBackground.blur) {
        g.add('[0:v]scale=$W:$H,setsar=1,fps=30,split=2[fg0][bg0]');
        g.add('[bg0]boxblur=20:2[bg]');
      } else {
        g.add('[0:v]scale=$W:$H,setsar=1,fps=30[fg0]');
        switch (bg) {
          case CutoutBackground.black:
            g.add('color=c=black:s=${W}x$H:r=30[bg]');
            break;
          case CutoutBackground.white:
            g.add('color=c=white:s=${W}x$H:r=30[bg]');
            break;
          case CutoutBackground.green:
            g.add('color=c=0x00FF00:s=${W}x$H:r=30[bg]');
            break;
          case CutoutBackground.image:
            g.add(
              '[2:v]scale=$W:$H:force_original_aspect_ratio=increase,'
              'crop=$W:$H,setsar=1,fps=30[bg]',
            );
            break;
          case CutoutBackground.blur:
            break;
        }
      }
      g.add(
        '[1:v]scale=$W:$H:flags=bicubic,fps=30,format=gray,boxblur=2:1,'
        'tpad=stop_mode=clone:stop_duration=1[m]',
      );
      g.add('[fg0][m]alphamerge[fg]');
      g.add('[bg][fg]overlay=shortest=1:format=auto,format=yuv420p[vout]');

      args.addAll(['-filter_complex', g.join(';')]);
      args.addAll(['-map', '[vout]', '-map', '0:a?']);
      args.addAll([
        '-c:v', 'libx264',
        '-preset', 'veryfast',
        '-crf', '23',
        '-pix_fmt', 'yuv420p',
        '-c:a', 'aac',
        '-b:a', '128k',
        '-movflags', '+faststart',
        '-t', len.toStringAsFixed(3),
        outPath,
      ]);

      final totalMs = len * 1000;
      final r3 = await _run(
        args,
        onTime: (ms) {
          if (totalMs > 0) {
            final p = (ms / totalMs).clamp(0.0, 1.0);
            onProgress('Building the video', 0.82 + 0.17 * p);
          }
        },
      );
      final out = File(outPath);
      if (!r3.ok || !await out.exists() || await out.length() == 0) {
        return CutoutResult.fail(
          'Could not build the video.\n${_tail(r3.logs)}',
        );
      }

      final result = ClipItem(
        path: outPath,
        duration: len,
        width: W.toDouble(),
        height: H.toDouble(),
      );
      result.speed = clip.speed;
      return CutoutResult.ok(result);
    } catch (e) {
      return CutoutResult.fail(e.toString());
    } finally {
      try {
        await segmenter?.close();
      } catch (_) {}
      try {
        if (await work.exists()) await work.delete(recursive: true);
      } catch (_) {}
    }
  }
}
