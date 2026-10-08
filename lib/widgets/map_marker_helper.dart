import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// 지도에 표시할 커스텀 마커(출발/도착 원형 도트, 1km 2km 알약 뱃지) 생성 유틸
class MapMarkerHelper {
  MapMarkerHelper._();

  static final Map<int, BitmapDescriptor> _kmCache = {};
  static BitmapDescriptor? _startIcon;
  static BitmapDescriptor? _endIcon;

  /// 캐시 초기화
  static void clearCache() {
    _kmCache.clear();
    _startIcon = null;
    _endIcon = null;
  }

  // ------------------------------------------------------------ 킬로미터 마커 (1 km, 2 km...)

  /// "1 km", "2 km" 등의 둥근 흰색 알약(Pill) 뱃지 마커
  static Future<BitmapDescriptor> getKmMarker(int km) async {
    if (_kmCache.containsKey(km)) return _kmCache[km]!;

    final text = '$km km';
    final icon = await _drawPillMarker(text);
    _kmCache[km] = icon;
    return icon;
  }

  static Future<BitmapDescriptor> _drawPillMarker(String text) async {
    const double pixelRatio = 3.0; // 고해상도 선명도 확보
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    final textPainter = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          color: Color(0xFF1F2937),
          fontSize: 10.5 * pixelRatio,
          fontWeight: FontWeight.w800,
          fontFamily: 'Roboto',
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final paddingH = 7.0 * pixelRatio;
    final paddingV = 3.0 * pixelRatio;
    final contentW = textPainter.width + paddingH * 2;
    final contentH = textPainter.height + paddingV * 2;
    final shadowBlur = 1.8 * pixelRatio;

    final totalW = contentW + shadowBlur * 2;
    final totalH = contentH + shadowBlur * 2;

    final pillRect = Rect.fromCenter(
      center: Offset(totalW / 2, totalH / 2),
      width: contentW,
      height: contentH,
    );
    final rrect = RRect.fromRectAndRadius(pillRect, Radius.circular(contentH / 2));

    // 그림자
    final shadowPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.22)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, shadowBlur);
    canvas.drawRRect(rrect.shift(Offset(0, 1.0 * pixelRatio)), shadowPaint);

    // 흰색 배경
    final bgPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;
    canvas.drawRRect(rrect, bgPaint);

    // 미세 테두리
    final borderPaint = Paint()
      ..color = const Color(0xFFE5E7EB)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8 * pixelRatio;
    canvas.drawRRect(rrect, borderPaint);

    // 텍스트 그리기
    textPainter.paint(
      canvas,
      Offset(
        (totalW - textPainter.width) / 2,
        (totalH - textPainter.height) / 2,
      ),
    );

    final picture = recorder.endRecording();
    final img = await picture.toImage(totalW.toInt(), totalH.toInt());
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    return BitmapDescriptor.bytes(byteData!.buffer.asUint8List(), imagePixelRatio: pixelRatio);
  }

  // ------------------------------------------------------------ 출발 마커 (초록 원형 도트)

  static Future<BitmapDescriptor> getStartMarker() async {
    if (_startIcon != null) return _startIcon!;
    _startIcon = await _drawDotMarker(
      innerColor: const Color(0xFF00E676), // 비비드 형광 그린
    );
    return _startIcon!;
  }

  // ------------------------------------------------------------ 도착 마커 (빨간 원형 도트)

  static Future<BitmapDescriptor> getEndMarker() async {
    if (_endIcon != null) return _endIcon!;
    _endIcon = await _drawDotMarker(
      innerColor: const Color(0xFFFF2D55), // 선명한 레드
    );
    return _endIcon!;
  }

  /// 출발/도착 지점용 컴팩트한 원형 도트 마커 (지도 내 위치 파란 동그라미보다 살짝 작은 미니멀 크기)
  static Future<BitmapDescriptor> _drawDotMarker({required Color innerColor}) async {
    const double pixelRatio = 3.0; // 고해상도 선명도
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    // 내 위치 동그라미(지름 약 12~14dp)보다 조금 작게: 반지름 4.5dp (전체 지름 9dp)
    const double logicalRadius = 4.5;
    const double logicalShadowBlur = 1.0;

    const radius = logicalRadius * pixelRatio;
    const shadowBlur = logicalShadowBlur * pixelRatio;
    const totalSize = (radius + shadowBlur) * 2;
    final center = Offset(totalSize / 2, totalSize / 2);

    // 은은한 미세 그림자
    final shadowPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.28)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, shadowBlur);
    canvas.drawCircle(center + const Offset(0, 0.8 * pixelRatio), radius, shadowPaint);

    // 바깥쪽 흰색 테두리 (두께 약 1.3dp)
    final whitePaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, radius, whitePaint);

    // 안쪽 색상 원 (초록 또는 빨강, 반지름 3.2dp)
    final innerPaint = Paint()
      ..color = innerColor
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, radius - (1.3 * pixelRatio), innerPaint);

    final picture = recorder.endRecording();
    final img = await picture.toImage(totalSize.toInt(), totalSize.toInt());
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    return BitmapDescriptor.bytes(byteData!.buffer.asUint8List(), imagePixelRatio: pixelRatio);
  }
}
