import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:path/path.dart' as p;

import '../data/local/local_db.dart';
import '../data/models/run_record.dart';
import '../theme/app_theme.dart';
import 'app_paths.dart';

/// 러닝 기록 섬네일 = 지도 위에 GPS 경로를 색칠한 이미지 (경로가 꽉 차게 확대).
///
/// 1순위: Google Map 스냅샷 (RouteMap 위젯이 fit 후 takeSnapshot)
/// 2순위: 지도 없이 경로만 그린 이미지 (오프라인/지도 키 미설정 대비)
class ThumbnailService {
  ThumbnailService._();
  static final ThumbnailService instance = ThumbnailService._();

  Future<String> saveSnapshot(String runId, Uint8List png) async {
    await AppPaths.ensureDir('thumbs');
    final rel = p.join('thumbs', '$runId.png');
    await AppPaths.resolve(rel).writeAsBytes(png, flush: true);
    await LocalDb.instance.setThumbnail(runId, rel);
    // 같은 경로의 이미지 캐시 무효화
    PaintingBinding.instance.imageCache.evict(FileImage(AppPaths.resolve(rel)));
    return rel;
  }

  File? fileFor(RunRecord run) {
    if (run.thumbnailPath == null) return null;
    final f = AppPaths.resolve(run.thumbnailPath!);
    return f.existsSync() ? f : null;
  }

  /// 지도 없이 경로만 그린 PNG
  Future<Uint8List?> renderRoutePng(List<List<LatLng>> segments, {int size = 600, Color? color}) async {
    final all = segments.expand((s) => s).toList();
    if (all.length < 2) return null;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final rect = Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble());
    canvas.drawRect(rect, Paint()..color = const Color(0xFF1D2026));
    RoutePainter(segments: segments, color: color ?? AppColors.route, strokeWidth: size / 80)
        .paint(canvas, rect.size);
    final img = await recorder.endRecording().toImage(size, size);
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    return data?.buffer.asUint8List();
  }

  Future<void> ensureFallback(RunRecord run, List<List<LatLng>> segments) async {
    if (fileFor(run) != null) return;
    final png = await renderRoutePng(segments);
    if (png != null) await saveSnapshot(run.id, png);
  }
}

/// 위경도 경로를 정사각 영역에 맞춰 그리는 Painter (지도 없는 섬네일/기록증 대체용)
class RoutePainter extends CustomPainter {
  RoutePainter({required this.segments, required this.color, this.strokeWidth = 4, this.padding = 0.1});

  final List<List<LatLng>> segments;
  final Color color;
  final double strokeWidth;
  final double padding;

  @override
  void paint(Canvas canvas, Size size) {
    final all = segments.expand((s) => s).toList();
    if (all.length < 2) return;
    var minLat = all.first.latitude, maxLat = minLat;
    var minLng = all.first.longitude, maxLng = minLng;
    for (final pt in all) {
      if (pt.latitude < minLat) minLat = pt.latitude;
      if (pt.latitude > maxLat) maxLat = pt.latitude;
      if (pt.longitude < minLng) minLng = pt.longitude;
      if (pt.longitude > maxLng) maxLng = pt.longitude;
    }
    // 위도에 따른 경도 축소 보정
    final midLat = (minLat + maxLat) / 2 * 3.141592653589793 / 180;
    final lngScale = _cos(midLat);
    final w = (maxLng - minLng) * lngScale;
    final h = maxLat - minLat;
    final span = (w > h ? w : h);
    if (span == 0) return;
    final avail = size.shortestSide * (1 - padding * 2);
    final scale = avail / span;
    final offX = (size.width - w * scale) / 2;
    final offY = (size.height - h * scale) / 2;

    Offset map(LatLng pt) => Offset(
          offX + (pt.longitude - minLng) * lngScale * scale,
          offY + (maxLat - pt.latitude) * scale,
        );

    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    for (final seg in segments) {
      if (seg.length < 2) continue;
      final path = Path()..moveTo(map(seg.first).dx, map(seg.first).dy);
      for (final pt in seg.skip(1)) {
        final o = map(pt);
        path.lineTo(o.dx, o.dy);
      }
      canvas.drawPath(path, paint);
    }
    final start = map(all.first);
    final end = map(all.last);
    canvas.drawCircle(start, strokeWidth * 1.4, Paint()..color = Colors.white);
    canvas.drawCircle(end, strokeWidth * 1.4, Paint()..color = AppColors.neon);
  }

  double _cos(double x) => math.cos(x);

  @override
  bool shouldRepaint(covariant RoutePainter old) => old.segments != segments || old.color != color;
}
