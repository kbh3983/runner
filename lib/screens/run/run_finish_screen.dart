import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/format.dart';
import '../../data/local/local_db.dart';
import '../../data/models/gps_point.dart';
import '../../data/models/run_record.dart';
import '../../services/photo_service.dart';
import '../../services/route_repository.dart';
import '../../services/run_tracker.dart';
import '../../services/thumbnail_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/route_map.dart';
import '../group/group_result_screen.dart';
import '../history/run_detail_screen.dart';

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
  List<RunPhoto> _photos = [];
  FinishReason? _reason;

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
    final photos = await LocalDb.instance.getPhotos(run.id);
    if (!mounted) return;
    setState(() {
      _run = run;
      _segments = segs;
      _photos = photos;
    });
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
                Text(Fmt.dateTime(run.startedAt), style: const TextStyle(color: AppColors.textSecondary)),
                const SizedBox(height: 12),
                AspectRatio(
                  aspectRatio: 1,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: run.mode == RunMode.treadmill && ThumbnailService.instance.fileFor(run) != null
                        ? Image.file(ThumbnailService.instance.fileFor(run)!, fit: BoxFit.cover)
                        : _segments.expand((s) => s).length < 2
                            ? Container(
                                color: AppColors.surface,
                                alignment: Alignment.center,
                                child: const Text('기록된 경로가 없어요', style: TextStyle(color: AppColors.textSecondary)),
                              )
                            : RouteMap(
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
                      itemBuilder: (_, i) => ClipRRect(
                        borderRadius: BorderRadius.circular(12),
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
}
