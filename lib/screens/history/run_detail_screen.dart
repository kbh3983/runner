import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import '../../core/format.dart';
import '../../core/party_ids.dart';
import '../../data/local/local_db.dart';
import '../../data/models/gps_point.dart';
import '../../data/models/run_record.dart';
import '../../services/photo_service.dart';
import '../../services/route_repository.dart';
import '../../services/sync_service.dart';
import '../../services/thumbnail_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/route_map.dart';
import '../group/group_result_screen.dart';
import 'certificate_sheet.dart';

/// 러닝 디테일: 지도, 러닝 ID, 참여인원, 페이스, 구간, 사진, 메모 + 메모하기/사진추가/공유하기
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
  List<RunPhoto> _photos = [];
  List<RunMemo> _memos = [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    LocalDb.instance.changes.addListener(_reload);
    _load();
  }

  @override
  void dispose() {
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
    await _reload(run: run);
    if (mounted) setState(() => _segments = segs);
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
      builder: (ctx) => AlertDialog(
        title: const Text('메모하기'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLines: 4,
          maxLength: 500,
          decoration: const InputDecoration(hintText: '오늘 러닝은 어땠나요?'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('취소')),
          TextButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('저장')),
        ],
      ),
    );
    if (text == null || text.isEmpty) return;
    await LocalDb.instance.insertMemo(RunMemo(
      id: const Uuid().v4(),
      runId: widget.runId,
      text: text,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    ));
    SyncService.instance.syncAll();
  }

  Future<void> _deleteMemo(RunMemo memo) async {
    if (!await _confirm('메모 삭제', '이 메모를 삭제할까요?')) return;
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
    if (!await _confirm('사진 삭제', '이 사진을 삭제할까요? (기기에서 삭제돼요)')) return;
    await PhotoService.instance.delete(photo);
  }

  Future<void> _share() async {
    final run = _run;
    if (run == null) return;
    // 현재 지도에서 경로가 꽉 차게 맞춘 스냅샷을 찍어 기록증 배경으로 사용
    final png = await _mapKey.currentState?.takeSnapshot();
    if (!mounted) return;
    await showCertificateSheet(context, run: run, segments: _segments, mapImage: png);
  }

  Future<bool> _confirm(String title, String body) async {
    final res = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('삭제', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    return res ?? false;
  }

  void _toast(String msg) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _openPhoto(RunPhoto photo) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(backgroundColor: Colors.black),
        body: Center(child: InteractiveViewer(child: Image.file(PhotoService.instance.file(photo)))),
      ),
    ));
  }

  // ------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    final run = _run;
    if (!_loaded) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (run == null) return Scaffold(appBar: AppBar(), body: const Center(child: Text('기록을 찾을 수 없어요')));
    final hasRoute = _segments.expand((s) => s).length >= 2;

    return Scaffold(
      appBar: AppBar(
        title: Text(Fmt.date(run.startedAt)),
        actions: [
          IconButton(tooltip: '공유하기', onPressed: _share, icon: const Icon(Icons.ios_share)),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Row(
            children: [
              Expanded(child: _ActionButton(icon: Icons.edit_note, label: '메모하기', onTap: _addMemo)),
              const SizedBox(width: 8),
              Expanded(child: _ActionButton(icon: Icons.add_a_photo, label: '사진추가', onTap: _addPhoto)),
              const SizedBox(width: 8),
              Expanded(child: _ActionButton(icon: Icons.ios_share, label: '공유하기', onTap: _share, primary: true)),
            ],
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: hasRoute
                  ? RouteMap(
                      key: _mapKey,
                      lines: [RouteLine(id: 'me', segments: _segments, color: AppColors.route)],
                      // 섬네일이 지도 스냅샷이 아니면(복원된 기록 등) 여기서 생성
                      onSnapshot: ThumbnailService.instance.fileFor(run) == null
                          ? (png) => ThumbnailService.instance.saveSnapshot(run.id, png)
                          : null,
                    )
                  : Container(
                      color: AppColors.surface,
                      alignment: Alignment.center,
                      child: const Text('경로 정보가 없어요', style: TextStyle(color: AppColors.textSecondary)),
                    ),
            ),
          ),
          const SizedBox(height: 20),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(Fmt.km(run.distanceM),
                  style: const TextStyle(fontSize: 56, fontWeight: FontWeight.w900, color: AppColors.neon, height: 1)),
              const SizedBox(width: 6),
              const Text('km', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
              const Spacer(),
              _SyncBadge(status: run.syncStatus),
            ],
          ),
          const SizedBox(height: 4),
          Text('${Fmt.dateTime(run.startedAt)} ~ ${run.endedAt != null ? Fmt.time(run.endedAt!) : ''}',
              style: const TextStyle(color: AppColors.textSecondary)),
          const SizedBox(height: 16),
          _Grid(children: [
            _GridStat(label: '평균 페이스', value: Fmt.pace(run.avgPaceSecPerKm)),
            _GridStat(label: '이동 시간', value: Fmt.duration(run.durationMs)),
            _GridStat(
              label: '최고 구간',
              value: run.splits.isEmpty
                  ? '-'
                  : Fmt.pace(run.splits.map((s) => s.paceSec).reduce((a, b) => a < b ? a : b)),
            ),
            _GridStat(label: '상승 고도', value: '${(run.elevationGainM ?? 0).round()} m'),
            _GridStat(label: '최고 속도', value: '${((run.maxSpeedMps ?? 0) * 3.6).toStringAsFixed(1)} km/h'),
            _GridStat(label: '목표', value: Fmt.goal(run.goalType.name, run.goalValue)),
          ]),
          if (run.splits.isNotEmpty) ...[
            const SizedBox(height: 16),
            _Section(title: '구간 페이스 (1km)', child: _Splits(splits: run.splits)),
          ],
          const SizedBox(height: 16),
          _Section(
            title: '사진 ${_photos.length}',
            trailing: IconButton(onPressed: _addPhoto, icon: const Icon(Icons.add_a_photo, size: 20)),
            child: _photos.isEmpty
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('사진을 추가해 오늘을 남겨보세요 (기기에만 저장)', style: TextStyle(color: AppColors.textSecondary)),
                  )
                : GridView.count(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    crossAxisCount: 3,
                    mainAxisSpacing: 6,
                    crossAxisSpacing: 6,
                    children: _photos
                        .map((ph) => Stack(
                              fit: StackFit.expand,
                              children: [
                                GestureDetector(
                                  onTap: () => _openPhoto(ph),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(10),
                                    child: Image.file(PhotoService.instance.file(ph),
                                        fit: BoxFit.cover,
                                        cacheWidth: 400,
                                        errorBuilder: (_, _, _) => Container(color: AppColors.surfaceHigh)),
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
                                      child: Icon(Icons.close, size: 14, color: Colors.white),
                                    ),
                                  ),
                                ),
                              ],
                            ))
                        .toList(),
                  ),
          ),
          const SizedBox(height: 16),
          _Section(
            title: '메모 ${_memos.length}',
            trailing: IconButton(onPressed: _addMemo, icon: const Icon(Icons.edit_note, size: 22)),
            child: _memos.isEmpty
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('메모가 없어요', style: TextStyle(color: AppColors.textSecondary)),
                  )
                : Column(
                    children: _memos
                        .map((m) => Container(
                              margin: const EdgeInsets.only(bottom: 8),
                              padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
                              decoration: BoxDecoration(
                                  color: AppColors.surfaceHigh, borderRadius: BorderRadius.circular(12)),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(m.text),
                                        const SizedBox(height: 4),
                                        Text(Fmt.dateTime(m.createdAt),
                                            style: const TextStyle(color: AppColors.textSecondary, fontSize: 11)),
                                      ],
                                    ),
                                  ),
                                  IconButton(
                                    onPressed: () => _deleteMemo(m),
                                    icon: const Icon(Icons.delete_outline, size: 20, color: AppColors.textSecondary),
                                  ),
                                ],
                              ),
                            ))
                        .toList(),
                  ),
          ),
          const SizedBox(height: 20),
          _Section(
            title: '러닝 정보',
            child: Column(
              children: [
                _InfoRow(
                  label: '러닝 ID',
                  value: run.id,
                  onCopy: () {
                    Clipboard.setData(ClipboardData(text: run.id));
                    _toast('러닝 ID를 복사했어요');
                  },
                ),
                _InfoRow(label: '방식', value: run.isGroup ? (run.loyalty ? '같이 뛰기 · 의리게임' : '같이 뛰기') : '혼자 뛰기'),
                if (run.isGroup) ...[
                  _InfoRow(label: '파티 ID', value: run.partyId ?? PartyIds.toDisplay(run.partyKey ?? '')),
                  _InfoRow(label: '참여 인원', value: run.participants.isEmpty ? '-' : '${run.participants.length}명'),
                  if (run.participants.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: run.participants
                            .map((p) => Chip(
                                  avatar: CircleAvatar(backgroundColor: MemberColors.of(p.colorIndex), radius: 6),
                                  label: Text(p.name),
                                  visualDensity: VisualDensity.compact,
                                ))
                            .toList(),
                      ),
                    ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => GroupResultScreen(partyKey: run.partyKey!, myRunId: run.id))),
                    icon: const Icon(Icons.leaderboard),
                    label: const Text('파티원 경로 · 순위 변동 보기'),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({required this.icon, required this.label, required this.onTap, this.primary = false});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) => Material(
        color: primary ? AppColors.neon : AppColors.surfaceHigh,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: SizedBox(
            height: 56,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 20, color: primary ? Colors.black : AppColors.textPrimary),
                const SizedBox(height: 2),
                Text(label,
                    style: TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w800, color: primary ? Colors.black : AppColors.textPrimary)),
              ],
            ),
          ),
        ),
      );
}

class _SyncBadge extends StatelessWidget {
  const _SyncBadge({required this.status});
  final SyncStatus status;

  @override
  Widget build(BuildContext context) {
    final synced = status == SyncStatus.synced;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(synced ? Icons.cloud_done : Icons.cloud_upload_outlined,
            size: 16, color: synced ? AppColors.route : AppColors.textSecondary),
        const SizedBox(width: 4),
        Text(synced ? '저장 완료' : '동기화 대기',
            style: TextStyle(fontSize: 12, color: synced ? AppColors.route : AppColors.textSecondary)),
      ],
    );
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
        decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(14)),
        padding: const EdgeInsets.all(10),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            FittedBox(child: Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900))),
            const SizedBox(height: 4),
            Text(label, style: const TextStyle(color: AppColors.textSecondary, fontSize: 11)),
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
        decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(18)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16))),
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
            SizedBox(width: 80, child: Text(label, style: const TextStyle(color: AppColors.textSecondary))),
            Expanded(child: Text(value, style: const TextStyle(fontWeight: FontWeight.w600))),
            if (onCopy != null)
              GestureDetector(onTap: onCopy, child: const Icon(Icons.copy, size: 16, color: AppColors.textSecondary)),
          ],
        ),
      );
}

class _Splits extends StatelessWidget {
  const _Splits({required this.splits});
  final List<KmSplit> splits;

  @override
  Widget build(BuildContext context) {
    final fastest = splits.map((s) => s.paceSec).reduce((a, b) => a < b ? a : b);
    final slowest = splits.map((s) => s.paceSec).reduce((a, b) => a > b ? a : b);
    return Column(
      children: splits.map((s) {
        final ratio = slowest == fastest ? 1.0 : 1 - (s.paceSec - fastest) / (slowest - fastest) * 0.6;
        final best = s.paceSec == fastest;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              SizedBox(width: 44, child: Text('${s.km}km', style: const TextStyle(color: AppColors.textSecondary))),
              Expanded(
                child: LayoutBuilder(
                  builder: (_, c) => Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      height: 18,
                      width: c.maxWidth * ratio,
                      decoration: BoxDecoration(
                        color: best ? AppColors.neon : AppColors.neon.withValues(alpha: 0.35),
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 56,
                child: Text(Fmt.pace(s.paceSec),
                    textAlign: TextAlign.right, style: TextStyle(fontWeight: best ? FontWeight.w900 : FontWeight.w600)),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}
