import 'dart:async';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import '../../config/app_config.dart';
import '../../core/format.dart';
import '../../core/party_ids.dart';
import '../../core/route_smoother.dart';
import '../../data/local/local_db.dart';
import '../../data/models/gps_point.dart';
import '../../data/models/run_record.dart';
import '../../services/party_service.dart';
import '../../services/photo_service.dart';
import '../../services/region_service.dart';
import '../../services/route_repository.dart';
import '../../services/sync_service.dart';
import '../../services/thumbnail_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/route_map.dart';
import '../group/group_result_screen.dart';
import 'certificate_sheet.dart';

/// 러닝 디테일: 지도, 참여인원, 페이스, 구간, 사진, 메모 + 메모하기/사진추가/공유하기
class RunDetailScreen extends StatefulWidget {
  const RunDetailScreen({super.key, required this.runId});
  final String runId;

  @override
  State<RunDetailScreen> createState() => _RunDetailScreenState();
}

class _RunDetailScreenState extends State<RunDetailScreen> {
  final _mapKey = GlobalKey<RouteMapState>();
  RunRecord? _run;
  List<List<LatLng>> _segments = [];
  List<ColoredSegment> _coloredSegments = [];
  Map<int, LatLng> _kmPositions = {};
  List<RunPhoto> _photos = [];
  List<RunMemo> _memos = [];
  bool _loaded = false;
  StreamSubscription? _partyResultsSub;
  List<Map<String, dynamic>> _partyResults = [];

  String get _myUid => AppConfig.useFirebase
      ? (FirebaseAuth.instance.currentUser?.uid ?? '')
      : 'dummy_uid';

  @override
  void initState() {
    super.initState();
    LocalDb.instance.changes.addListener(_reload);
    _load();
  }

  @override
  void dispose() {
    _partyResultsSub?.cancel();
    LocalDb.instance.changes.removeListener(_reload);
    super.dispose();
  }

  Future<void> _load() async {
    final run = await LocalDb.instance.getRun(widget.runId);
    if (run == null) {
      if (mounted) setState(() => _loaded = true);
      return;
    }
    final segs = await RouteRepository.segmentsFor(run);
    final colored = await RouteRepository.coloredSegmentsFor(run);
    final kms = await RouteRepository.extractKmPositions(run);
    await _reload(run: run);
    if (mounted) {
      setState(() {
        _segments = segs;
        _coloredSegments = colored;
        _kmPositions = kms;
      });
    }
    if (run.region == null && run.mode != RunMode.treadmill) {
      RegionService.instance.resolveAndSaveRegion(run).then((reg) {
        if (mounted && reg != null) setState(() => _run?.region = reg);
      });
    }
    if (run.isGroup && run.partyKey != null && run.partyKey!.isNotEmpty) {
      _partyResultsSub?.cancel();
      _partyResultsSub = PartyService.instance.results(run.partyKey!).listen(
        (res) {
          if (mounted) setState(() => _partyResults = res);
        },
        onError: (_) {},
      );
    }
  }

  Future<void> _reload({RunRecord? run}) async {
    final r = run ?? await LocalDb.instance.getRun(widget.runId);
    if (r == null) return;
    final photos = await LocalDb.instance.getPhotos(r.id);
    final memos = await LocalDb.instance.getMemos(r.id);
    if (!mounted) return;
    setState(() {
      _run = r;
      _photos = photos;
      _memos = memos;
      _loaded = true;
    });
  }

  // ------------------------------------------------------------ actions

  Future<void> _addMemo() async {
    final ctrl = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: AppColors.surfaceHigh,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: AppColors.neon, width: 1.0),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 30, 28, 26),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '메모하기',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: ctrl,
                autofocus: true,
                maxLines: 4,
                maxLength: 500,
                style: const TextStyle(fontSize: 14, height: 1.4),
                decoration: InputDecoration(
                  hintText: '오늘 러닝은 어땠나요?',
                  hintStyle: const TextStyle(color: AppColors.textSecondary),
                  filled: true,
                  fillColor: AppColors.bg,
                  counterStyle: const TextStyle(color: AppColors.textSecondary),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide: const BorderSide(color: AppColors.outline),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide: const BorderSide(color: AppColors.outline),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide: const BorderSide(color: AppColors.neon),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    flex: 1000,
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(4),
                        ),
                        side: const BorderSide(color: AppColors.outline),
                      ),
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text(
                        '취소',
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 1618,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.neon,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
                      child: const Text(
                        '저장하기',
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 15,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (text == null || text.isEmpty) return;
    await LocalDb.instance.insertMemo(
      RunMemo(
        id: const Uuid().v4(),
        runId: widget.runId,
        text: text,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    SyncService.instance.syncAll();
  }

  Future<void> _deleteMemo(RunMemo memo) async {
    if (!await _confirm('메모를 삭제할까요?', '삭제된 메모는 복구할 수 없어요')) return;
    await LocalDb.instance.deleteMemo(memo);
    SyncService.instance.syncAll();
  }

  Future<void> _addPhoto() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('사진 찍기'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('앨범에서 선택'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;
    try {
      await PhotoService.instance.add(widget.runId, source);
    } catch (e) {
      _toast('사진을 추가하지 못했어요: $e');
    }
  }

  Future<void> _deletePhoto(RunPhoto photo) async {
    if (!await _confirm('사진을 삭제할까요?', '이 기기에 저장된 사진이 삭제돼요')) return;
    await PhotoService.instance.delete(photo);
  }

  Future<void> _share() async {
    final run = _run;
    if (run == null) return;
    // 현재 지도에서 경로가 꽉 차게 맞춘 스냅샷을 찍어 기록증 배경으로 사용
    final png = await _mapKey.currentState?.takeSnapshot();
    if (!mounted) return;
    await showCertificateSheet(
      context,
      run: run,
      segments: _segments,
      mapImage: png,
    );
  }

  Future<bool> _confirm(String title, String body) async {
    final res = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: AppColors.surfaceHigh,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: AppColors.neon, width: 1.0),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 30, 28, 26),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                body,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 14,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 28),
              Row(
                children: [
                  Expanded(
                    flex: 1000,
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(4),
                        ),
                        side: const BorderSide(color: AppColors.outline),
                      ),
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text(
                        '취소',
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 1618,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.danger,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text(
                        '삭제하기',
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 15,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    return res ?? false;
  }

  void _toast(
    String msg, {
    IconData icon = Icons.info_outline_rounded,
    Color accentColor = AppColors.neon,
  }) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppColors.surfaceHigh,
          margin: const EdgeInsets.only(bottom: 24, left: 16, right: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: accentColor, width: 1.5),
          ),
          content: Row(
            children: [
              Icon(icon, color: accentColor),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  msg,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
  }

  void _openPhoto(RunPhoto photo) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(backgroundColor: Colors.black),
          body: Center(
            child: InteractiveViewer(
              child: Image.file(PhotoService.instance.file(photo)),
            ),
          ),
        ),
      ),
    );
  }

  void _openFile(File file) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(backgroundColor: Colors.black),
          body: Center(child: InteractiveViewer(child: Image.file(file))),
        ),
      ),
    );
  }

  // ------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    final run = _run;
    if (!_loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (run == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('기록을 찾을 수 없어요')),
      );
    }
    final hasRoute = _segments.expand((s) => s).isNotEmpty;
    // 러닝머신은 계기판 사진이 경로 정보를 대신함
    final treadmillPhoto = run.mode == RunMode.treadmill
        ? ThumbnailService.instance.fileFor(run)
        : null;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(Fmt.date(run.startedAt)),
            if (run.region != null && run.region!.isNotEmpty)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.location_on, size: 12, color: AppColors.neon),
                  const SizedBox(width: 3),
                  Text(
                    run.region!,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textSecondary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
          ],
        ),
        actions: [
          ValueListenableBuilder<bool>(
            valueListenable: SyncService.instance.syncing,
            builder: (context, syncing, _) {
              final isSynced = run.syncStatus == SyncStatus.synced;
              if (syncing) {
                return const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Center(
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.neon),
                    ),
                  ),
                );
              }
              return Container(
                margin: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () async {
                    if (isSynced) {
                      _toast(
                        '이 러닝 기록은 클라우드에 안전하게 저장되어 있어요. ☁️',
                        icon: Icons.cloud_done_rounded,
                        accentColor: AppColors.neon,
                      );
                    } else {
                      final res = await SyncService.instance.syncAllManual();
                      if (!mounted) return;
                      final updated = await LocalDb.instance.getRun(run.id);
                      if (updated != null && mounted) {
                        setState(() => _run = updated);
                      }
                      if (res == SyncResult.success || (updated?.syncStatus == SyncStatus.synced)) {
                        _toast(
                          '클라우드 동기화가 완료되었습니다! ☁️',
                          icon: Icons.cloud_done_rounded,
                          accentColor: AppColors.neon,
                        );
                      } else if (res == SyncResult.notLoggedIn) {
                        _toast(
                          '클라우드 동기화를 위해 로그인이 필요해요.',
                          icon: Icons.lock_outline_rounded,
                          accentColor: Colors.orange,
                        );
                      } else {
                        _toast(
                          '네트워크 연결을 확인해주세요. (스마트폰에 안전하게 보관돼요)',
                          icon: Icons.wifi_off_rounded,
                          accentColor: Colors.orange,
                        );
                      }
                    }
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: isSynced
                          ? AppColors.neon.withValues(alpha: 0.12)
                          : Colors.orange.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isSynced
                            ? AppColors.neon.withValues(alpha: 0.4)
                            : Colors.orange.withValues(alpha: 0.5),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          isSynced ? Icons.cloud_done_rounded : Icons.sync,
                          size: 16,
                          color: isSynced ? AppColors.neon : Colors.orange,
                        ),
                        const SizedBox(width: 5),
                        Text(
                          isSynced ? '저장 완료' : '동기화 대기',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            color: isSynced ? AppColors.neon : Colors.orange,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(width: 4),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: _ActionButton(
                  icon: Icons.edit_note_rounded,
                  tooltip: '메모하기',
                  onTap: _addMemo,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _ActionButton(
                  icon: Icons.add_a_photo_outlined,
                  tooltip: '사진추가',
                  onTap: _addPhoto,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _ActionButton(
                  icon: Icons.ios_share_rounded,
                  tooltip: '공유하기',
                  onTap: _share,
                  primary: true,
                ),
              ),
            ],
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: ClipRect(
              child: treadmillPhoto != null
                  ? GestureDetector(
                      onTap: () => _openFile(treadmillPhoto),
                      child: Container(
                        color: AppColors.surface,
                        child: Image.file(
                          treadmillPhoto,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => const Center(
                            child: Text(
                              '계기판 사진을 불러올 수 없어요',
                              style: TextStyle(color: AppColors.textSecondary),
                            ),
                          ),
                        ),
                      ),
                    )
                  : hasRoute
                  ? RouteMap(
                      key: _mapKey,
                      coloredSegments: _coloredSegments,
                      kmPositions: _kmPositions,
                      lines: [
                        RouteLine(
                          id: 'me',
                          segments: _segments,
                          color: AppColors.route,
                        ),
                      ],
                      // 섬네일이 지도 스냅샷이 아니면(복원된 기록 등) 여기서 생성
                      onSnapshot: ThumbnailService.instance.fileFor(run) == null
                          ? (png) => ThumbnailService.instance.saveSnapshot(
                              run.id,
                              png,
                            )
                          : null,
                    )
                  : Container(
                      color: AppColors.surface,
                      alignment: Alignment.center,
                      child: const Text(
                        '경로 정보가 없어요',
                        style: TextStyle(color: AppColors.textSecondary),
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 20),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                Fmt.km(run.distanceM),
                style: const TextStyle(
                  fontSize: 56,
                  fontWeight: FontWeight.w900,
                  color: AppColors.neon,
                  height: 1,
                ),
              ),
              const SizedBox(width: 6),
              const Text(
                'km',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${Fmt.dateTime(run.startedAt)} ~ ${run.endedAt != null ? Fmt.time(run.endedAt!) : ''}',
            style: const TextStyle(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 16),
          Builder(
            builder: (context) {
              final avgSpeedKmh = run.durationMs > 0 && run.distanceM > 0
                  ? (run.distanceM / (run.durationMs / 1000.0)) * 3.6
                  : 0.0;
              final recordedMaxSpeedKmh = (run.maxSpeedMps ?? 0) * 3.6;
              final maxSpeedKmh = recordedMaxSpeedKmh > 0
                  ? recordedMaxSpeedKmh
                  : avgSpeedKmh;
              final calories = (run.distanceM / 1000.0 * 68).round();

              return _Grid(
                children: [
                  _GridStat(label: '평균 페이스', value: Fmt.pace(run.avgPaceSecPerKm)),
                  _GridStat(
                    label: '최고 페이스',
                    value: () {
                      if (run.splits.isNotEmpty) {
                        final bestSplitPace = run.splits
                            .map((s) => s.paceSec)
                            .reduce((a, b) => a < b ? a : b);
                        return Fmt.pace(bestSplitPace);
                      }
                      if (run.avgPaceSecPerKm != null && run.avgPaceSecPerKm! > 0) {
                        return Fmt.pace(run.avgPaceSecPerKm);
                      }
                      return '-';
                    }(),
                  ),
                  _GridStat(label: '소모 칼로리', value: '$calories kcal'),
                  _GridStat(
                    label: '평균 속도',
                    value: '${avgSpeedKmh.toStringAsFixed(1)} km/h',
                  ),
                  _GridStat(
                    label: '최고 속도',
                    value: '${maxSpeedKmh.toStringAsFixed(1)} km/h',
                  ),
                  _GridStat(label: '러닝 시간', value: Fmt.duration(run.durationMs)),
                ],
              );
            },
          ),
          if (run.splits.isNotEmpty) ...[
            const SizedBox(height: 16),
            _Section(
              title: '구간 페이스 (1km)',
              child: _Splits(splits: run.splits),
            ),
          ],
          const SizedBox(height: 16),
          _Section(
            title: '사진',
            trailing: IconButton(
              onPressed: _addPhoto,
              icon: const Icon(Icons.add_a_photo, size: 20),
            ),
            child: _photos.isEmpty
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      '사진을 추가해 오늘을 남겨보세요 (기기에만 저장)',
                      style: TextStyle(color: AppColors.textSecondary),
                    ),
                  )
                : GridView.count(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    crossAxisCount: 3,
                    mainAxisSpacing: 6,
                    crossAxisSpacing: 6,
                    children: _photos
                        .map(
                          (ph) => Stack(
                            fit: StackFit.expand,
                            children: [
                              GestureDetector(
                                onTap: () => _openPhoto(ph),
                                child: ClipRect(
                                  child: Image.file(
                                    PhotoService.instance.file(ph),
                                    fit: BoxFit.cover,
                                    cacheWidth: 400,
                                    errorBuilder: (_, _, _) =>
                                        Container(color: AppColors.surfaceHigh),
                                  ),
                                ),
                              ),
                              Positioned(
                                right: 2,
                                top: 2,
                                child: GestureDetector(
                                  onTap: () => _deletePhoto(ph),
                                  child: const CircleAvatar(
                                    radius: 12,
                                    backgroundColor: Colors.black54,
                                    child: Icon(
                                      Icons.close,
                                      size: 14,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        )
                        .toList(),
                  ),
          ),
          const SizedBox(height: 16),
          _Section(
            title: '메모',
            trailing: IconButton(
              onPressed: _addMemo,
              icon: const Icon(Icons.edit_note, size: 22),
            ),
            child: _memos.isEmpty
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      '메모가 없어요',
                      style: TextStyle(color: AppColors.textSecondary),
                    ),
                  )
                : Column(
                    children: _memos
                        .map(
                          (m) => Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
                            decoration: BoxDecoration(
                              color: AppColors.surfaceHigh,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(m.text),
                                      const SizedBox(height: 4),
                                      Text(
                                        Fmt.dateTime(m.createdAt),
                                        style: const TextStyle(
                                          color: AppColors.textSecondary,
                                          fontSize: 11,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  onPressed: () => _deleteMemo(m),
                                  icon: const Icon(
                                    Icons.delete_outline,
                                    size: 20,
                                    color: AppColors.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                        .toList(),
                  ),
          ),
          const SizedBox(height: 20),
          _Section(
            title: '러닝 정보',
            child: Column(
              children: [
                _InfoRow(
                  label: '방식',
                  value: run.isGroup
                      ? (run.loyalty ? '같이 뛰기 · 의리게임' : '같이 뛰기')
                      : '혼자 뛰기',
                ),
                if (run.goalType != GoalType.none)
                  _InfoRow(
                    label: '목표',
                    value: Fmt.goal(run.goalType.name, run.goalValue),
                  ),
                if (run.isGroup) ...[
                  _InfoRow(
                    label: '파티 ID',
                    value:
                        run.partyId ?? PartyIds.toDisplay(run.partyKey ?? ''),
                    onCopy: () {
                      final pid =
                          run.partyId ?? PartyIds.toDisplay(run.partyKey ?? '');
                      Clipboard.setData(ClipboardData(text: pid));
                      _toast('파티 ID를 복사했어요');
                    },
                  ),
                  _InfoRow(
                    label: '참여 인원',
                    value: run.participants.isEmpty
                        ? '-'
                        : '${run.participants.length}명',
                  ),
                ],
              ],
            ),
          ),
          if (run.isGroup && run.participants.isNotEmpty) ...[
            const SizedBox(height: 16),
            _Section(
              title: '함께 달린 크루',
              trailing: run.partyKey != null
                  ? TextButton.icon(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => GroupResultScreen(
                            partyKey: run.partyKey!,
                            myRunId: run.id,
                          ),
                        ),
                      ),
                      icon: const Icon(Icons.leaderboard, size: 16),
                      label: const Text('순위 · 경로 보기'),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        foregroundColor: AppColors.neon,
                      ),
                    )
                  : null,
              child: Column(
                children: [
                  ...run.participants.map((p) {
                    final isMe = p.uid == _myUid || p.uid == run.ownerId;
                    final res = _partyResults
                        .where((r) => r['ownerId'] == p.uid)
                        .firstOrNull;
                    final distM = isMe
                        ? run.distanceM
                        : ((res?['distanceM'] as num?)?.toDouble() ?? 0.0);
                    final durMs = isMe
                        ? run.durationMs
                        : ((res?['durationMs'] as num?)?.toInt() ?? 0);
                    final pace = isMe
                        ? run.avgPaceSecPerKm
                        : ((res?['avgPaceSecPerKm'] as num?)?.toDouble());

                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: isMe
                            ? AppColors.surfaceHigh.withValues(alpha: 0.9)
                            : AppColors.surfaceHigh.withValues(alpha: 0.4),
                        borderRadius: BorderRadius.circular(12),
                        border: isMe
                            ? Border.all(
                                color: AppColors.neon.withValues(alpha: 0.5),
                                width: 1.2,
                              )
                            : null,
                      ),
                      child: Row(
                        children: [
                          CircleAvatar(
                            radius: 16,
                            backgroundColor: MemberColors.of(p.colorIndex),
                            child: Text(
                              p.name.isNotEmpty
                                  ? p.name.characters.first
                                  : '?',
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w900,
                                fontSize: 13,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Text(
                                      p.name,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w800,
                                        fontSize: 14,
                                      ),
                                    ),
                                    if (isMe) ...[
                                      const SizedBox(width: 6),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                          vertical: 1,
                                        ),
                                        decoration: BoxDecoration(
                                          color: AppColors.neon,
                                          borderRadius:
                                              BorderRadius.circular(6),
                                        ),
                                        child: const Text(
                                          '나',
                                          style: TextStyle(
                                            color: Colors.black,
                                            fontWeight: FontWeight.w900,
                                            fontSize: 10,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                                if (distM > 0)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: Text(
                                      '${Fmt.km(distM)} km · ${Fmt.duration(durMs)}${pace != null && pace > 0 ? " · ${Fmt.pace(pace)}" : ""}',
                                      style: const TextStyle(
                                        color: AppColors.textSecondary,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  )
                                else
                                  const Padding(
                                    padding: EdgeInsets.only(top: 2),
                                    child: Text(
                                      '참여 완료',
                                      style: TextStyle(
                                        color: AppColors.textSecondary,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          Icon(
                            Icons.check_circle_rounded,
                            size: 18,
                            color: isMe ? AppColors.neon : AppColors.outline,
                          ),
                        ],
                      ),
                    );
                  }),
                  if (run.partyKey != null) ...[
                    const SizedBox(height: 4),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.textPrimary,
                        side: BorderSide(
                          color: AppColors.outline.withValues(alpha: 0.6),
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        minimumSize: const Size.fromHeight(42),
                      ),
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => GroupResultScreen(
                            partyKey: run.partyKey!,
                            myRunId: run.id,
                          ),
                        ),
                      ),
                      icon: const Icon(
                        Icons.leaderboard,
                        size: 18,
                        color: AppColors.neon,
                      ),
                      label: const Text('파티원 전체 경로 · 순위 변동 보기'),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    this.tooltip,
    required this.onTap,
    this.primary = false,
  });
  final IconData icon;
  final String? tooltip;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final btn = Material(
      color: primary ? AppColors.neon : AppColors.surfaceHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: primary
            ? BorderSide.none
            : BorderSide(
                color: AppColors.outline.withValues(alpha: 0.25),
                width: 1,
              ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: SizedBox(
          height: 48,
          child: Center(
            child: Icon(
              icon,
              size: 22,
              color: primary ? Colors.black : AppColors.textPrimary,
            ),
          ),
        ),
      ),
    );

    if (tooltip != null) {
      return Tooltip(message: tooltip!, child: btn);
    }
    return btn;
  }
}


class _Grid extends StatelessWidget {
  const _Grid({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => GridView.count(
    crossAxisCount: 3,
    shrinkWrap: true,
    physics: const NeverScrollableScrollPhysics(),
    mainAxisSpacing: 8,
    crossAxisSpacing: 8,
    childAspectRatio: 1.35,
    children: children,
  );
}

class _GridStat extends StatelessWidget {
  const _GridStat({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(14),
    ),
    padding: const EdgeInsets.all(10),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        FittedBox(
          child: Text(
            value,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: const TextStyle(color: AppColors.textSecondary, fontSize: 11),
        ),
      ],
    ),
  );
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child, this.trailing});
  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(16, 8, 8, 14),
    decoration: BoxDecoration(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(18),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 16,
                ),
              ),
            ),
            trailing ?? const SizedBox(height: 40),
          ],
        ),
        Padding(padding: const EdgeInsets.only(right: 8), child: child),
      ],
    ),
  );
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value, this.onCopy});
  final String label;
  final String value;
  final VoidCallback? onCopy;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 80,
          child: Text(
            label,
            style: const TextStyle(color: AppColors.textSecondary),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        if (onCopy != null)
          GestureDetector(
            onTap: onCopy,
            child: const Icon(
              Icons.copy,
              size: 16,
              color: AppColors.textSecondary,
            ),
          ),
      ],
    ),
  );
}

class _Splits extends StatelessWidget {
  const _Splits({required this.splits});
  final List<KmSplit> splits;

  @override
  Widget build(BuildContext context) {
    final fastest = splits
        .map((s) => s.paceSec)
        .reduce((a, b) => a < b ? a : b);
    final slowest = splits
        .map((s) => s.paceSec)
        .reduce((a, b) => a > b ? a : b);
    return Column(
      children: splits.map((s) {
        final ratio = slowest == fastest
            ? 1.0
            : 1 - (s.paceSec - fastest) / (slowest - fastest) * 0.6;
        final best = s.paceSec == fastest;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              SizedBox(
                width: 44,
                child: Text(
                  '${s.km}km',
                  style: const TextStyle(color: AppColors.textSecondary),
                ),
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (_, c) => Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      height: 18,
                      width: c.maxWidth * ratio,
                      decoration: BoxDecoration(
                        color: best
                            ? AppColors.neon
                            : AppColors.neon.withValues(alpha: 0.35),
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 56,
                child: Text(
                  Fmt.pace(s.paceSec),
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontWeight: best ? FontWeight.w900 : FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}
