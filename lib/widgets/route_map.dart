import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../config/app_config.dart';
import '../core/geo.dart';
import '../core/route_smoother.dart';
import '../theme/app_theme.dart';
import 'map_marker_helper.dart';

class RouteLine {
  final String id;
  final List<List<LatLng>> segments;
  final Color color;
  final int width;

  const RouteLine({
    required this.id,
    required this.segments,
    required this.color,
    this.width = 4,
  });

  int get pointCount => segments.fold(0, (s, e) => s + e.length);
}

/// 완료된 러닝 경로를 보여주는 지도.
/// 페이스별 히트맵 컬러, 1km 2km 분할 뱃지, 출발/도착 커스텀 마커 지원.
class RouteMap extends StatefulWidget {
  const RouteMap({
    super.key,
    this.lines = const [],
    this.coloredSegments = const [],
    this.kmPositions = const {},
    this.markers = const {},
    this.interactive = true,
    this.onSnapshot,
    this.padding = 48,
    this.showStartEnd = true,
    this.showKmMarkers = true,
  });

  final List<RouteLine> lines;
  final List<ColoredSegment> coloredSegments;
  final Map<int, LatLng> kmPositions;
  final Set<Marker> markers;
  final bool interactive;
  final FutureOr<void> Function(Uint8List png)? onSnapshot;
  final double padding;
  final bool showStartEnd;
  final bool showKmMarkers;

  @override
  State<RouteMap> createState() => RouteMapState();
}

class RouteMapState extends State<RouteMap> {
  GoogleMapController? _controller;
  bool _snapshotTaken = false;
  bool _mapReady = false;

  BitmapDescriptor? _startIcon;
  BitmapDescriptor? _endIcon;
  final Map<int, BitmapDescriptor> _kmIcons = {};

  List<LatLng> get _allPoints {
    if (widget.coloredSegments.isNotEmpty) {
      return widget.coloredSegments.expand((s) => s.points).toList();
    }
    return widget.lines.expand((l) => l.segments.expand((s) => s)).toList();
  }

  @override
  void initState() {
    super.initState();
    _loadCustomMarkers();
  }

  @override
  void didUpdateWidget(covariant RouteMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.kmPositions.keys.toSet() != widget.kmPositions.keys.toSet() ||
        oldWidget.showStartEnd != widget.showStartEnd) {
      _loadCustomMarkers();
    }
    final oldCount = oldWidget.lines.fold<int>(0, (s, l) => s + l.pointCount) +
        oldWidget.coloredSegments.fold<int>(0, (s, e) => s + e.points.length);
    final newCount = widget.lines.fold<int>(0, (s, l) => s + l.pointCount) +
        widget.coloredSegments.fold<int>(0, (s, e) => s + e.points.length);
    if (oldCount != newCount) _fit();
  }

  Future<void> _loadCustomMarkers() async {
    try {
      if (widget.showStartEnd) {
        final start = await MapMarkerHelper.getStartMarker();
        final end = await MapMarkerHelper.getEndMarker();
        if (mounted) {
          setState(() {
            _startIcon = start;
            _endIcon = end;
          });
        }
      }

      if (widget.showKmMarkers && widget.kmPositions.isNotEmpty) {
        for (final km in widget.kmPositions.keys) {
          if (!_kmIcons.containsKey(km)) {
            final icon = await MapMarkerHelper.getKmMarker(km);
            if (mounted) {
              setState(() {
                _kmIcons[km] = icon;
              });
            }
          }
        }
      }
    } catch (e) {
      debugPrint('Failed to load custom markers: $e');
    }
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
    Future.delayed(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _mapReady = true);
    });
    await Future.delayed(const Duration(milliseconds: 500));
    if (!mounted) return;
    await _fit();
    if (widget.onSnapshot != null && !_snapshotTaken) {
      // 마커 및 타일이 렌더링될 시간 대기
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

    // 1) 페이스별 히트맵 세그먼트가 있으면 우선 렌더링
    if (widget.coloredSegments.isNotEmpty) {
      for (var i = 0; i < widget.coloredSegments.length; i++) {
        final seg = widget.coloredSegments[i];
        if (seg.points.length < 2) continue;
        polylines.add(Polyline(
          polylineId: PolylineId('heat_$i'),
          points: seg.points,
          color: seg.color,
          width: 4,
          jointType: JointType.round,
          startCap: Cap.roundCap,
          endCap: Cap.roundCap,
          zIndex: 2,
        ));
      }
    } else {
      // 2) 기본 lines 렌더링
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
            zIndex: 2,
          ));
        }
      }
    }

    final markers = {...widget.markers};

    // 3) 1km, 2km 등 킬로미터 마커 뱃지 추가
    if (widget.showKmMarkers && widget.kmPositions.isNotEmpty) {
      widget.kmPositions.forEach((km, pos) {
        final icon = _kmIcons[km];
        if (icon != null) {
          markers.add(Marker(
            markerId: MarkerId('km_$km'),
            position: pos,
            icon: icon,
            anchor: const Offset(0.5, 0.5),
            zIndexInt: 5,
          ));
        }
      });
    }

    // 4) 출발 / 도착 커스텀 원형 마커
    if (widget.showStartEnd && pts.isNotEmpty) {
      if (pts.length == 1) {
        markers.add(Marker(
          markerId: const MarkerId('single'),
          position: pts.first,
          icon: _endIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
          anchor: const Offset(0.5, 0.5),
          zIndexInt: 10,
        ));
      } else {
        markers.add(Marker(
          markerId: const MarkerId('start'),
          position: pts.first,
          icon: _startIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
          anchor: const Offset(0.5, 0.5),
          infoWindow: const InfoWindow(title: '출발'),
          zIndexInt: 10,
        ));
        markers.add(Marker(
          markerId: const MarkerId('end'),
          position: pts.last,
          icon: _endIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
          anchor: const Offset(0.5, 0.5),
          infoWindow: const InfoWindow(title: '도착'),
          zIndexInt: 10,
        ));
      }
    }

    final initial = pts.isNotEmpty ? pts.first : const LatLng(37.5665, 126.9780);
    return Stack(
      children: [
        GoogleMap(
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
        ),
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: _mapReady ? 0.0 : 1.0,
              duration: const Duration(milliseconds: 600),
              curve: Curves.easeOut,
              child: Container(color: const Color(0xFF1D2026)),
            ),
          ),
        ),
      ],
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
