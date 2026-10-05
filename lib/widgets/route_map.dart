import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../config/app_config.dart';
import '../core/geo.dart';
import '../theme/app_theme.dart';

class RouteLine {
  final String id;
  final List<List<LatLng>> segments;
  final Color color;
  final int width;

  const RouteLine({required this.id, required this.segments, required this.color, this.width = 6});

  int get pointCount => segments.fold(0, (s, e) => s + e.length);
}

/// 완료된 러닝 경로를 보여주는 지도.
/// 경로가 화면에 꽉 차도록 맞춘 뒤, 필요하면 스냅샷(섬네일/기록증)을 찍는다.
class RouteMap extends StatefulWidget {
  const RouteMap({
    super.key,
    required this.lines,
    this.markers = const {},
    this.interactive = true,
    this.onSnapshot,
    this.padding = 48,
    this.showStartEnd = true,
  });

  final List<RouteLine> lines;
  final Set<Marker> markers;
  final bool interactive;
  final FutureOr<void> Function(Uint8List png)? onSnapshot;
  final double padding;
  final bool showStartEnd;

  @override
  State<RouteMap> createState() => RouteMapState();
}

class RouteMapState extends State<RouteMap> {
  GoogleMapController? _controller;
  bool _snapshotTaken = false;

  List<LatLng> get _allPoints => widget.lines.expand((l) => l.segments.expand((s) => s)).toList();

  @override
  void didUpdateWidget(covariant RouteMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldCount = oldWidget.lines.fold<int>(0, (s, l) => s + l.pointCount);
    final newCount = widget.lines.fold<int>(0, (s, l) => s + l.pointCount);
    if (oldCount != newCount) _fit();
  }

  Future<void> _fit() async {
    final b = Geo.bounds(_allPoints);
    if (b == null || _controller == null) return;
    try {
      await _controller!.moveCamera(CameraUpdate.newLatLngBounds(b, widget.padding));
    } catch (_) {
      // 레이아웃 전이면 잠시 후 재시도
      await Future.delayed(const Duration(milliseconds: 400));
      try {
        await _controller?.moveCamera(CameraUpdate.newLatLngBounds(b, widget.padding));
      } catch (_) {}
    }
  }

  Future<void> _onCreated(GoogleMapController c) async {
    _controller = c;
    await Future.delayed(const Duration(milliseconds: 500));
    if (!mounted) return;
    await _fit();
    if (widget.onSnapshot != null && !_snapshotTaken) {
      // 타일이 로드될 시간을 준다
      await Future.delayed(const Duration(milliseconds: 1800));
      await takeSnapshot();
    }
  }

  Future<Uint8List?> takeSnapshot() async {
    if (_controller == null || !mounted) return null;
    try {
      final png = await _controller!.takeSnapshot();
      if (png != null) {
        _snapshotTaken = true;
        await widget.onSnapshot?.call(png);
      }
      return png;
    } catch (e) {
      debugPrint('map snapshot failed: $e');
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!AppConfig.useMaps) {
      return Container(
        color: const Color(0xFF1E1E1E),
        child: const Center(
          child: Text('지도가 비활성화되어 있습니다.', style: TextStyle(color: Colors.white54)),
        ),
      );
    }
    final pts = _allPoints;
    final polylines = <Polyline>{};
    for (final line in widget.lines) {
      for (var i = 0; i < line.segments.length; i++) {
        if (line.segments[i].length < 2) continue;
        polylines.add(Polyline(
          polylineId: PolylineId('${line.id}_$i'),
          points: line.segments[i],
          color: line.color,
          width: line.width,
          jointType: JointType.round,
          startCap: Cap.roundCap,
          endCap: Cap.roundCap,
        ));
      }
    }
    final markers = {...widget.markers};
    if (widget.showStartEnd && pts.length >= 2 && widget.lines.length == 1) {
      markers.add(Marker(
        markerId: const MarkerId('start'),
        position: pts.first,
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
        infoWindow: const InfoWindow(title: '출발'),
      ));
      markers.add(Marker(
        markerId: const MarkerId('end'),
        position: pts.last,
        icon: BitmapDescriptor.defaultMarkerWithHue(75),
        infoWindow: const InfoWindow(title: '도착'),
      ));
    }
    final initial = pts.isNotEmpty ? pts.first : const LatLng(37.5665, 126.9780);
    return GoogleMap(
      initialCameraPosition: CameraPosition(target: initial, zoom: 15),
      onMapCreated: _onCreated,
      polylines: polylines,
      markers: markers,
      style: kDarkMapStyle,
      myLocationButtonEnabled: false,
      zoomControlsEnabled: false,
      mapToolbarEnabled: false,
      compassEnabled: false,
      scrollGesturesEnabled: widget.interactive,
      zoomGesturesEnabled: widget.interactive,
      rotateGesturesEnabled: widget.interactive,
      tiltGesturesEnabled: false,
    );
  }
}

/// 숫자 + 라벨 통계 타일
class StatTile extends StatelessWidget {
  const StatTile({super.key, required this.value, required this.label, this.big = false, this.color});

  final String value;
  final String label;
  final bool big;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            value,
            style: TextStyle(
              fontSize: big ? 44 : 24,
              fontWeight: FontWeight.w900,
              color: color ?? AppColors.textPrimary,
              fontFeatures: const [FontFeature.tabularFigures()],
              height: 1.1,
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(label, style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
      ],
    );
  }
}
