import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../widgets/camera_filters.dart';

/// "Quema" en los píxeles el mismo filtro que `CameraFilterOverlay` pinta
/// sobre el video en vivo (matriz de color + viñeta + scanlines + esquinas
/// HUD), para que las fotos y videos guardados en Multimedia queden tal
/// cual se veían en pantalla — también si el archivo se abre fuera de la
/// app.
///
/// Corre en un isolate aparte ([processFrameAsync]) porque decodificar y
/// re-codificar JPEG en Dart bloquearía la UI.
class FrameJob {
  /// JPEG (ESP32-CAM) o píxeles crudos BGRA/BGR0 de mpv `screenshot-raw`
  /// (Tapo C110) según [raw].
  final Uint8List data;
  final bool raw;
  final int width;
  final int height;
  final int stride;

  final CameraFilterMode filter;

  /// Igual que `RotatedBox.quarterTurns` (horario). El ESP32-CAM va montado
  /// de lado, ver `kCamRotationQuarterTurns`.
  final int quarterTurns;

  /// Lado mayor máximo de la salida (0 = sin reescalar). Los videos de la
  /// Tapo se bajan a ~960 px para que la codificación aguante varios fps.
  final int maxSide;
  final int quality;

  /// Si son > 0, la salida se escala (agrandando o achicando) para caber
  /// en [fitW]×[fitH] sin deformarse — lo usa el video de las 2 cámaras.
  final int fitW;
  final int fitH;

  const FrameJob.jpeg(
    this.data, {
    required this.filter,
    this.quarterTurns = 0,
    this.maxSide = 0,
    this.quality = 85,
    this.fitW = 0,
    this.fitH = 0,
  })  : raw = false,
        width = 0,
        height = 0,
        stride = 0;

  const FrameJob.raw(
    this.data, {
    required this.width,
    required this.height,
    required this.stride,
    required this.filter,
    this.quarterTurns = 0,
    this.maxSide = 0,
    this.quality = 85,
    this.fitW = 0,
    this.fitH = 0,
  }) : raw = true;
}

class FrameResult {
  final Uint8List jpeg;
  final int width;
  final int height;
  const FrameResult(this.jpeg, this.width, this.height);
}

Future<FrameResult?> processFrameAsync(FrameJob job) => compute(processFrame, job);

FrameResult? processFrame(FrameJob job) {
  if (!job.raw) {
    final noChange = job.filter == CameraFilterMode.none && job.quarterTurns % 4 == 0 && job.maxSide == 0 && job.fitW == 0;
    if (noChange) {
      final size = jpegSize(job.data);
      if (size != null) return FrameResult(job.data, size.$1, size.$2);
    }
  }
  final r = _render(job);
  if (r == null) return null;
  final (out, outW, outH) = r;
  final image = img.Image.fromBytes(width: outW, height: outH, bytes: out.buffer, numChannels: 3);
  return FrameResult(img.encodeJpg(image, quality: job.quality), outW, outH);
}

/// Filtro + rotación + escala de un frame, en RGB crudo (sin codificar).
(Uint8List, int, int)? _render(FrameJob job) {
  late Uint8List px;
  late int srcW, srcH, stride, bpp, ro, go, bo;

  if (job.raw) {
    px = job.data;
    srcW = job.width;
    srcH = job.height;
    stride = job.stride;
    bpp = 4; // mpv screenshot-raw: bgr0
    ro = 2;
    go = 1;
    bo = 0;
    if (srcW <= 0 || srcH <= 0 || px.length < stride * srcH) return null;
  } else {
    var decoded = img.decodeJpg(job.data);
    if (decoded == null) return null;
    if (decoded.numChannels != 3) decoded = decoded.convert(numChannels: 3);
    px = decoded.getBytes(order: img.ChannelOrder.rgb);
    srcW = decoded.width;
    srcH = decoded.height;
    stride = srcW * 3;
    bpp = 3;
    ro = 0;
    go = 1;
    bo = 2;
  }

  final q = job.quarterTurns % 4;
  final rotW = q.isOdd ? srcH : srcW;
  final rotH = q.isOdd ? srcW : srcH;
  final longSide = math.max(rotW, rotH);
  final scale = job.fitW > 0 && job.fitH > 0
      ? math.min(job.fitW / rotW, job.fitH / rotH)
      : (job.maxSide > 0 && longSide > job.maxSide ? job.maxSide / longSide : 1.0);
  final outW = math.max(1, (rotW * scale).round());
  final outH = math.max(1, (rotH * scale).round());
  final inv = 1 / scale;

  final m = CameraFilterOverlay.matrixFor(job.filter);
  final out = Uint8List(outW * outH * 3);

  // Viñeta: mismo RadialGradient que `_Vignette` (radio 0.95 del lado
  // corto, transparente hasta 0.55 y 55 % de opacidad en el borde).
  final hasVignette = m != null;
  const vr = 0x00;
  final vg = job.filter == CameraFilterMode.nightVision ? 0x1A : 0x00;
  final vb = job.filter == CameraFilterMode.nightVision ? 0x05 : 0x00;
  final radius = 0.95 * math.min(outW, outH);
  final cx = outW / 2, cy = outH / 2;

  // Scanlines: el overlay las pinta en px lógicos sobre un recuadro de
  // ~300 px de alto; se escalan a la resolución de salida.
  final k = outH / 300;
  final scanSpacing = switch (job.filter) {
    CameraFilterMode.nightVision => math.max(2, (3 * k).round()),
    CameraFilterMode.military => math.max(2, (4 * k).round()),
    _ => 0,
  };
  final scanAlpha = switch (job.filter) {
    CameraFilterMode.nightVision => 0.10,
    CameraFilterMode.military => 0.14,
    _ => 0.0,
  };

  var o = 0;
  for (var oy = 0; oy < outH; oy++) {
    final ry = math.min(rotH - 1, (oy * inv).floor());
    final dark = scanSpacing > 0 && (oy % scanSpacing) < scanSpacing / 2;
    for (var ox = 0; ox < outW; ox++) {
      final rx = math.min(rotW - 1, (ox * inv).floor());
      int sx, sy;
      switch (q) {
        case 1:
          sx = ry;
          sy = srcH - 1 - rx;
        case 2:
          sx = srcW - 1 - rx;
          sy = srcH - 1 - ry;
        case 3:
          sx = srcW - 1 - ry;
          sy = rx;
        default:
          sx = rx;
          sy = ry;
      }
      final i = sy * stride + sx * bpp;
      double r = px[i + ro].toDouble();
      double g = px[i + go].toDouble();
      double b = px[i + bo].toDouble();

      if (m != null) {
        final nr = m[0] * r + m[1] * g + m[2] * b + m[4];
        final ng = m[5] * r + m[6] * g + m[7] * b + m[9];
        final nb = m[10] * r + m[11] * g + m[12] * b + m[14];
        r = nr;
        g = ng;
        b = nb;
      }
      if (hasVignette) {
        final dx = ox - cx, dy = oy - cy;
        final d = math.sqrt(dx * dx + dy * dy) / radius;
        if (d > 0.55) {
          final a = (d >= 1 ? 1.0 : (d - 0.55) / 0.45) * 0.55;
          r = r * (1 - a) + vr * a;
          g = g * (1 - a) + vg * a;
          b = b * (1 - a) + vb * a;
        }
      }
      if (dark) {
        r *= 1 - scanAlpha;
        g *= 1 - scanAlpha;
        b *= 1 - scanAlpha;
      }
      out[o++] = r.clamp(0, 255).toInt();
      out[o++] = g.clamp(0, 255).toInt();
      out[o++] = b.clamp(0, 255).toInt();
    }
  }

  if (job.filter == CameraFilterMode.military) _drawHudCorners(out, outW, outH, k);
  return (out, outW, outH);
}

/// Un frame del video de las 2 cámaras: CAM 1 a la izquierda y CAM 2 a la
/// derecha, cada una en un recuadro fijo de [panelW]×[panelH] (el AVI exige
/// el mismo tamaño en todos los frames). Una cámara sin frame sale como
/// "SIN SEÑAL".
class DualFrameJob {
  final FrameJob? cam1;
  final FrameJob? cam2;
  final int panelW;
  final int panelH;
  final int quality;
  const DualFrameJob({this.cam1, this.cam2, this.panelW = 640, this.panelH = 480, this.quality = 75});
}

Future<FrameResult?> composeDualAsync(DualFrameJob job) => compute(composeDual, job);

FrameResult? composeDual(DualFrameJob job) {
  const gap = 4;
  final pw = job.panelW, ph = job.panelH;
  final w = pw * 2 + gap, h = ph;
  final out = Uint8List(w * h * 3);
  // Fondo negro tinta de la app.
  for (var i = 0; i < out.length; i += 3) {
    out[i] = 5;
    out[i + 1] = 6;
    out[i + 2] = 8;
  }
  bool panel(FrameJob? src, int x0) {
    (Uint8List, int, int)? r;
    if (src != null) {
      try {
        r = _render(src);
      } catch (_) {}
    }
    if (r == null) return false;
    final (px, fw, fh) = r;
    final ox = x0 + (pw - fw) ~/ 2, oy = (ph - fh) ~/ 2;
    for (var y = 0; y < fh; y++) {
      final dst = ((oy + y) * w + ox) * 3;
      out.setRange(dst, dst + fw * 3, px, y * fw * 3);
    }
    return true;
  }

  final ok1 = panel(job.cam1, 0);
  final ok2 = panel(job.cam2, pw + gap);

  // Etiquetas encima (después de copiar los píxeles: `fromBytes` puede copiar el búfer).
  final canvas = img.Image.fromBytes(width: w, height: h, bytes: out.buffer, numChannels: 3);
  final labelColor = img.ColorRgb8(228, 230, 234);
  final dimColor = img.ColorRgb8(134, 140, 153);
  for (final (x0, ok, label) in [(0, ok1, 'CAM 1'), (pw + gap, ok2, 'CAM 2')]) {
    if (!ok) img.drawString(canvas, 'SIN SENAL', font: img.arial24, x: x0 + pw ~/ 2 - 60, y: ph ~/ 2 - 12, color: dimColor);
    img.drawString(canvas, label, font: img.arial14, x: x0 + 10, y: 8, color: labelColor);
  }
  return FrameResult(img.encodeJpg(canvas, quality: job.quality), w, h);
}

/// Esquinas tipo visor del modo militar (`_HudCorners`): L de 16 px,
/// 2 px de grosor, a 10 px del borde, color 0x9993A1C6.
void _drawHudCorners(Uint8List out, int w, int h, double k) {
  final pad = (10 * k).round();
  final len = math.max(4, (16 * k).round());
  final t = math.max(1, (2 * k).round());
  const a = 0x99 / 255;
  void rect(int x0, int y0, int rw, int rh) {
    for (var y = math.max(0, y0); y < math.min(h, y0 + rh); y++) {
      for (var x = math.max(0, x0); x < math.min(w, x0 + rw); x++) {
        final i = (y * w + x) * 3;
        out[i] = (out[i] * (1 - a) + 0x93 * a).round();
        out[i + 1] = (out[i + 1] * (1 - a) + 0xA1 * a).round();
        out[i + 2] = (out[i + 2] * (1 - a) + 0xC6 * a).round();
      }
    }
  }

  final r = w - pad, btm = h - pad;
  rect(pad, pad, len, t); // arriba-izq
  rect(pad, pad, t, len);
  rect(r - len, pad, len, t); // arriba-der
  rect(r - t, pad, t, len);
  rect(pad, btm - t, len, t); // abajo-izq
  rect(pad, btm - len, t, len);
  rect(r - len, btm - t, len, t); // abajo-der
  rect(r - t, btm - len, t, len);
}

/// Ancho y alto de un JPEG leyendo su marcador SOF, sin decodificarlo.
(int, int)? jpegSize(Uint8List b) {
  var i = 2;
  while (i + 9 < b.length) {
    if (b[i] != 0xFF) {
      i++;
      continue;
    }
    final marker = b[i + 1];
    if (marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
      i += 2;
      continue;
    }
    final len = (b[i + 2] << 8) | b[i + 3];
    final isSof = marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC;
    if (isSof) {
      final h = (b[i + 5] << 8) | b[i + 6];
      final w = (b[i + 7] << 8) | b[i + 8];
      return (w, h);
    }
    i += 2 + len;
  }
  return null;
}
