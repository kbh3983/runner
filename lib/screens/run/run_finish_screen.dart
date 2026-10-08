import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/format.dart';
import '../../core/route_smoother.dart';
import '../../data/local/local_db.dart';
import '../../data/models/gps_point.dart';
import '../../data/models/run_record.dart';
import '../../services/photo_service.dart';
import '../../services/point_service.dart';
import '../../services/region_service.dart';
import '../../services/route_repository.dart';
import '../../services/run_tracker.dart';
import '../../services/thumbnail_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/route_map.dart';
import '../group/group_result_screen.dart';
import '../history/run_detail_screen.dart';
import '../points/points_screen.dart';

/// 러닝 종료 화면: 기록 요약 + "사진찍기" + 섬네일(지도 스냅샷) 생성
class RunFinishScreen extends StatefulWidget {
  const RunFinishScreen({super.key, required this.runId});
  final String runId;

  @override
  State<RunFinishScreen> createState() => _RunFinishScreenState();
}

class _RunFinishScreenState extends State<RunFinishScreen> {
  RunRecord? _run;
  List<List<LatLng>> _segments = [];
  List<ColoredSegment> _coloredSegments = [];
  Map<int, LatLng> _kmPositions = {};
  List<RunPhoto> _photos = [];
  FinishReason? _reason;
  RunPointRewardResult? _pointResult;

  @override
  void initState() {
    super.initState();
    _reason = RunTracker.instance.finishReason;
    RunTracker.instance.reset();
    _load();
  }

  Future<void> _load() async {
    final run = await LocalDb.instance.getRun(widget.runId);
    if (run == null) return;
    final segs = await RouteRepository.segmentsFor(run);
    final colored = await RouteRepository.coloredSegmentsFor(run);
    final kms = await RouteRepository.extractKmPositions(run);
    final photos = await LocalDb.instance.getPhotos(run.id);
    if (!mounted) return;
    setState(() {
      _run = run;
      _segments = segs;
      _coloredSegments = colored;
      _kmPositions = kms;
      _photos = photos;
    });
    // 포인트 및 미션 처리
    PointService.instance.processRunPoints(run).then((res) {
      if (mounted) setState(() => _pointResult = res);
    });
    if (run.region == null && run.mode != RunMode.treadmill) {
      RegionService.instance.resolveAndSaveRegion(run).then((reg) {
        if (mounted && reg != null) setState(() => _run?.region = reg);
      });
    }
    // 지도 스냅샷이 실패해도 섬네일이 남도록 경로 이미지를 먼저 만들어 둔다
    ThumbnailService.instance.ensureFallback(run, segs);
  }

  Future<void> _takePhoto() async {
    try {
      final photo = await PhotoService.instance.add(widget.runId, ImageSource.camera);
      if (photo != null && mounted) setState(() => _photos.add(photo));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('사진을 찍지 못했어요: $e')));
    }
  }

  String? get _banner => switch (_reason) {
        FinishReason.goalDistance || FinishReason.goalTime => '🎯 목표 달성!',
        FinishReason.loyaltySuccess => '🤝 의리게임 성공!',
        FinishReason.loyaltyFailed => '⏰ 의리게임 시간 초과',
        _ => null,
      };

  @override
  Widget build(BuildContext context) {
    final run = _run;
    return Scaffold(
      appBar: AppBar(
        title: const Text('러닝 완료'),
        automaticallyImplyLeading: false,
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('완료')),
        ],
      ),
      body: run == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
              children: [
                if (_banner != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(_banner!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: AppColors.neon)),
                  ),
                Row(
                  children: [
                    Text(Fmt.dateTime(run.startedAt), style: const TextStyle(color: AppColors.textSecondary)),
                    if (run.region != null && run.region!.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      const Text('·', style: TextStyle(color: AppColors.textSecondary)),
                      const SizedBox(width: 8),
                      const Icon(Icons.location_on, size: 13, color: AppColors.neon),
                      const SizedBox(width: 2),
                      Text(run.region!, style: const TextStyle(color: AppColors.textSecondary, fontSize: 13, fontWeight: FontWeight.w600)),
                    ],
                  ],
                ),
                const SizedBox(height: 12),
                AspectRatio(
                  aspectRatio: 1,
                  child: ClipRect(
                    child: run.mode == RunMode.treadmill && ThumbnailService.instance.fileFor(run) != null
                        ? Image.file(ThumbnailService.instance.fileFor(run)!, fit: BoxFit.cover)
                        : _segments.expand((s) => s).isEmpty
                            ? Container(
                                color: AppColors.surface,
                                alignment: Alignment.center,
                                child: const Text('기록된 경로가 없어요', style: TextStyle(color: AppColors.textSecondary)),
                              )
                            : RouteMap(
                                coloredSegments: _coloredSegments,
                                kmPositions: _kmPositions,
                                lines: [RouteLine(id: 'me', segments: _segments, color: AppColors.route)],
                                onSnapshot: (png) => ThumbnailService.instance.saveSnapshot(run.id, png),
                              ),
                  ),
                ),
                const SizedBox(height: 20),
                StatTile(value: Fmt.km(run.distanceM), label: '거리 (km)', big: true, color: AppColors.neon),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(child: StatTile(value: Fmt.pace(run.avgPaceSecPerKm), label: '평균 페이스')),
                    Expanded(child: StatTile(value: Fmt.duration(run.durationMs), label: '시간')),
                    Expanded(child: StatTile(value: '${run.splits.length}', label: '완주 km')),
                  ],
                ),
                if (_pointResult != null && _pointResult!.totalEarned > 0) ...[
                  const SizedBox(height: 18),
                  _buildPointRewardCard(_pointResult!),
                ],
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _takePhoto,
                  icon: const Icon(Icons.camera_alt_rounded),
                  label: const Text('사진찍기'),
                ),
                const SizedBox(height: 6),
                const Text('사진은 이 기기에만 저장돼요',
                    textAlign: TextAlign.center, style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                if (_photos.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 96,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: _photos.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 8),
                      itemBuilder: (_, i) => ClipRect(
                        child: Image.file(PhotoService.instance.file(_photos[i]),
                            width: 96, height: 96, fit: BoxFit.cover, cacheWidth: 300),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                if (run.isGroup && run.partyKey != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => GroupResultScreen(partyKey: run.partyKey!, myRunId: run.id))),
                      icon: const Icon(Icons.leaderboard),
                      label: const Text('파티원 기록 / 순위 보기'),
                    ),
                  ),
                OutlinedButton.icon(
                  onPressed: () => Navigator.of(context)
                      .pushReplacement(MaterialPageRoute(builder: (_) => RunDetailScreen(runId: run.id))),
                  icon: const Icon(Icons.insights),
                  label: const Text('상세 기록 보기'),
                ),
              ],
            ),
    );
  }

  Widget _buildPointRewardCard(RunPointRewardResult res) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            const Color(0xFFFFD700).withValues(alpha: 0.16),
            AppColors.surfaceHigh,
          ],
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFFFD700).withValues(alpha: 0.45), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('🪙', style: TextStyle(fontSize: 20)),
              const SizedBox(width: 8),
              Text(
                '+${res.totalEarned} P 획득!',
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFFFFD700),
                ),
              ),
              const Spacer(),
              InkWell(
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const PointsScreen()),
                ),
                child: const Row(
                  children: [
                    Text('포인트 현황', style: TextStyle(color: AppColors.neon, fontSize: 12, fontWeight: FontWeight.w700)),
                    Icon(Icons.chevron_right, size: 16, color: AppColors.neon),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (res.mileagePoints > 0)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  const Icon(Icons.directions_run_rounded, size: 16, color: AppColors.neon),
                  const SizedBox(width: 6),
                  const Expanded(
                    child: Text('거리 마일리지 (1km당 1P)', style: TextStyle(fontSize: 13, color: AppColors.textPrimary)),
                  ),
                  Text('+${res.mileagePoints} P',
                      style: const TextStyle(fontWeight: FontWeight.w800, color: Color(0xFFFFD700), fontSize: 13)),
                ],
              ),
            ),
          ...res.missionAwards.map((m) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    const Icon(Icons.check_circle_rounded, size: 16, color: Color(0xFF00E676)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(m.title, style: const TextStyle(fontSize: 13, color: AppColors.textPrimary)),
                    ),
                    Text('+${m.points} P',
                        style: const TextStyle(fontWeight: FontWeight.w800, color: Color(0xFFFFD700), fontSize: 13)),
                  ],
                ),
              )),
        ],
      ),
    );
  }
}
