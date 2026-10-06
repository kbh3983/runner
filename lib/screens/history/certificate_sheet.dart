import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import '../../config/app_config.dart';
import '../../core/format.dart';
import '../../data/models/run_record.dart';
import '../../services/app_paths.dart';
import '../../services/thumbnail_service.dart';
import '../../theme/app_theme.dart';

/// 러닝 기록증: 지도(내가 뛴 경로) 위에 기록을 출력한 이미지. 공유용.
Future<void> showCertificateSheet(
  BuildContext context, {
  required RunRecord run,
  required List<List<LatLng>> segments,
  Uint8List? mapImage,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (_) =>
        _CertificateSheet(run: run, segments: segments, mapImage: mapImage),
  );
}

class _CertificateSheet extends StatefulWidget {
  const _CertificateSheet({
    required this.run,
    required this.segments,
    this.mapImage,
  });
  final RunRecord run;
  final List<List<LatLng>> segments;
  final Uint8List? mapImage;

  @override
  State<_CertificateSheet> createState() => _CertificateSheetState();
}

class _CertificateSheetState extends State<_CertificateSheet> {
  final _boundary = GlobalKey();
  bool _busy = false;

  Future<void> _share() async {
    setState(() => _busy = true);
    try {
      final ro =
          _boundary.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final img = await ro.toImage(pixelRatio: 3);
      final data = await img.toByteData(format: ui.ImageByteFormat.png);
      final dir = await AppPaths.ensureDir('share');
      final file = File(p.join(dir.path, 'certificate_${widget.run.id}.png'));
      await file.writeAsBytes(data!.buffer.asUint8List(), flush: true);
      if (!mounted) return;
      final box = context.findRenderObject() as RenderBox?;
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'image/png')],
          text:
              '${Fmt.date(widget.run.startedAt)} ${Fmt.km(widget.run.distanceM)}km 러닝 완료! #${AppConfig.appName}',
          sharePositionOrigin: box == null
              ? null
              : box.localToGlobal(Offset.zero) & box.size,
        ),
      );
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('공유하지 못했어요: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final run = widget.run;
    final thumb = ThumbnailService.instance.fileFor(run);
    Widget background;
    if (widget.mapImage != null) {
      background = Image.memory(widget.mapImage!, fit: BoxFit.cover);
    } else if (thumb != null) {
      background = Image.file(thumb, fit: BoxFit.cover);
    } else {
      background = Container(
        color: const Color(0xFF1D2026),
        child: CustomPaint(
          painter: RoutePainter(
            segments: widget.segments,
            color: AppColors.route,
            strokeWidth: 5,
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '기록증',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 14),
          RepaintBoundary(
            key: _boundary,
            child: AspectRatio(
              aspectRatio: 1,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    background,
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          stops: [0, 0.45, 1],
                          colors: [
                            Color(0x99000000),
                            Colors.transparent,
                            Color(0xEE000000),
                          ],
                        ),
                      ),
                    ),
                    Positioned(
                      left: 18,
                      top: 16,
                      right: 18,
                      child: Row(
                        children: [
                          const Icon(
                            Icons.directions_run_rounded,
                            color: AppColors.neon,
                            size: 20,
                          ),
                          const SizedBox(width: 6),
                          const Text(
                            AppConfig.appName,
                            style: TextStyle(
                              fontWeight: FontWeight.w900,
                              color: AppColors.neon,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            Fmt.date(run.startedAt),
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Positioned(
                      left: 18,
                      right: 18,
                      bottom: 16,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.baseline,
                            textBaseline: TextBaseline.alphabetic,
                            children: [
                              Text(
                                Fmt.km(run.distanceM),
                                style: const TextStyle(
                                  fontSize: 52,
                                  fontWeight: FontWeight.w900,
                                  color: Colors.white,
                                  height: 1,
                                ),
                              ),
                              const SizedBox(width: 6),
                              const Text(
                                'km',
                                style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w800,
                                  color: AppColors.neon,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              _CertStat(
                                label: '평균 페이스',
                                value: Fmt.pace(run.avgPaceSecPerKm),
                              ),
                              _CertStat(
                                label: '시간',
                                value: Fmt.duration(run.durationMs),
                              ),
                              _CertStat(
                                label: run.isGroup ? '같이 뛴 인원' : '시작',
                                value: run.isGroup
                                    ? '${run.participants.isEmpty ? '-' : run.participants.length}명'
                                    : Fmt.time(run.startedAt),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _busy ? null : _share,
            icon: const Icon(Icons.ios_share),
            label: const Text('기록증 공유하기'),
          ),
        ],
      ),
    );
  }
}

class _CertStat extends StatelessWidget {
  const _CertStat({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w900,
            color: Colors.white,
          ),
        ),
        Text(
          label,
          style: const TextStyle(fontSize: 11, color: Colors.white70),
        ),
      ],
    ),
  );
}
