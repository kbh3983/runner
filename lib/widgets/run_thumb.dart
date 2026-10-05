import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../data/models/gps_point.dart';
import '../data/models/run_record.dart';
import '../services/app_paths.dart';
import '../services/route_repository.dart';
import '../services/thumbnail_service.dart';
import '../theme/app_theme.dart';

/// 러닝 섬네일: 사진 > 지도 스냅샷 > 경로 그림 순으로 표시
class RunThumb extends StatefulWidget {
  const RunThumb({super.key, required this.run, this.photo, this.radius = 12, this.preferPhoto = true});

  final RunRecord run;
  final RunPhoto? photo;
  final double radius;
  final bool preferPhoto;

  @override
  State<RunThumb> createState() => _RunThumbState();
}

class _RunThumbState extends State<RunThumb> {
  List<List<LatLng>>? _segments;

  @override
  void initState() {
    super.initState();
    _maybeLoad();
  }

  @override
  void didUpdateWidget(covariant RunThumb old) {
    super.didUpdateWidget(old);
    if (old.run.id != widget.run.id || old.run.thumbnailPath != widget.run.thumbnailPath) {
      _segments = null;
      _maybeLoad();
    }
  }

  void _maybeLoad() {
    final hasPhoto = widget.preferPhoto && widget.photo != null;
    if (hasPhoto || ThumbnailService.instance.fileFor(widget.run) != null) return;
    RouteRepository.segmentsFor(widget.run).then((s) {
      if (mounted) setState(() => _segments = s);
      // 다음부터는 바로 보이도록 경로 이미지를 만들어 둔다
      ThumbnailService.instance.ensureFallback(widget.run, s);
    });
  }

  @override
  Widget build(BuildContext context) {
    Widget child;
    final photo = widget.preferPhoto ? widget.photo : null;
    final thumb = ThumbnailService.instance.fileFor(widget.run);
    if (photo != null && AppPaths.resolve(photo.relPath).existsSync()) {
      child = Image.file(AppPaths.resolve(photo.relPath), fit: BoxFit.cover, cacheWidth: 300);
    } else if (thumb != null) {
      child = Image.file(thumb, fit: BoxFit.cover, cacheWidth: 300);
    } else if (_segments != null && _segments!.isNotEmpty) {
      child = Container(
        color: const Color(0xFF1D2026),
        child: CustomPaint(painter: RoutePainter(segments: _segments!, color: AppColors.route, strokeWidth: 2.5)),
      );
    } else {
      child = Container(
        color: AppColors.surfaceHigh,
        child: const Icon(Icons.directions_run, color: AppColors.neon),
      );
    }
    return ClipRRect(borderRadius: BorderRadius.circular(widget.radius), child: child);
  }
}
