import 'dart:async';
import 'dart:math' as math;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../config/app_config.dart';
import '../../core/format.dart';
import '../../core/geo.dart';
import '../../core/party_ids.dart';
import '../../data/models/party.dart';
import '../../data/models/run_record.dart';
import '../../services/live_session_service.dart';
import '../../services/party_service.dart';
import '../../services/server_clock.dart';
import '../../theme/app_theme.dart';
import '../../widgets/route_map.dart';

/// 파티원 1명의 결과 (서버 검증된 results 문서 기반)
class _MemberResult {
  final String uid;
  final String name;
  final int colorIndex;
  final List<Map<String, dynamic>> runs; // 완료 기록 (의리게임은 여러 개 가능)
  final LiveMember? live;

  _MemberResult(this.uid, this.name, this.colorIndex, this.runs, this.live);

  Map<String, dynamic>? get primary => runs.isEmpty ? null : runs.first;
  double get totalDistanceM => runs.fold(0.0, (s, r) => s + ((r['distanceM'] as num?)?.toDouble() ?? 0));
  int? get durationMs => (primary?['durationMs'] as num?)?.toInt();
  double? get avgPace => (primary?['avgPaceSecPerKm'] as num?)?.toDouble();

  List<KmSplit> get splits =>
      ((primary?['splits'] as List?) ?? []).map((e) => KmSplit.fromMap(e as Map)).toList();

  List<TimelineSample> get timeline =>
      ((primary?['timeline'] as List?) ?? []).map((e) => TimelineSample.fromMap(e as Map)).toList();

  bool get stillRunning => live != null && (live!.status == 'RUNNING' || live!.status == 'PAUSED');

  List<List<LatLng>> get segments {
    final out = <List<LatLng>>[];
    for (final r in runs) {
      final path = (r['path'] as String?) ?? '';
      if (path.isEmpty) continue;
      final breaks = ((r['pathBreaks'] as List?) ?? []).map((e) => (e as num).toInt()).toList();
      out.addAll(Geo.splitByBreaks(Geo.decodePolyline(path), breaks));
    }
    return out;
  }

  String get statusLabel {
    if (stillRunning) return live!.status == 'PAUSED' ? '러닝중 (일시정지)' : '러닝중';
    if (runs.isNotEmpty) return '완료';
    return '기록 없음';
  }
}

/// 같이 뛰기 결과: 파티원 경로, 기록, km별 순위 변동, 구간/시간별 페이스
class GroupResultScreen extends StatefulWidget {
  const GroupResultScreen({super.key, required this.partyKey, this.myRunId});
  final String partyKey;
  final String? myRunId;

  @override
  State<GroupResultScreen> createState() => _GroupResultScreenState();
}

class _GroupResultScreenState extends State<GroupResultScreen> {
  final uid = AppConfig.useFirebase ? FirebaseAuth.instance.currentUser!.uid : 'dummy_uid';
  late final LiveSessionService _live = LiveSessionService(widget.partyKey);
  StreamSubscription? _partySub, _resultsSub, _liveSub;
  Party? _party;
  List<Map<String, dynamic>> _results = [];
  Map<String, LiveMember> _liveMembers = {};
  String? _error;
  String? _focus;

  @override
  void initState() {
    super.initState();
    _partySub = PartyService.instance.watch(widget.partyKey).listen(
          (p) => setState(() => _party = p),
          onError: (_) => setState(() => _error = '파티 정보를 볼 수 없어요'),
        );
    _resultsSub = PartyService.instance.results(widget.partyKey).listen(
          (r) => setState(() => _results = r),
          onError: (_) {},
        );
    _liveSub = _live.members().listen((m) => setState(() => _liveMembers = m), onError: (_) {});
  }

  @override
  void dispose() {
    _partySub?.cancel();
    _resultsSub?.cancel();
    _liveSub?.cancel();
    super.dispose();
  }

  List<_MemberResult> _members(Party party) {
    final byUid = <String, List<Map<String, dynamic>>>{};
    for (final r in _results) {
      byUid.putIfAbsent(r['ownerId'] as String, () => []).add(r);
    }
    for (final list in byUid.values) {
      list.sort((a, b) => ((a['startedAt'] as num?) ?? 0).compareTo((b['startedAt'] as num?) ?? 0));
    }
    return party.sortedMembers
        .map((m) => _MemberResult(m.uid, m.name, m.colorIndex, byUid[m.uid] ?? [], _liveMembers[m.uid]))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final party = _party;
    return Scaffold(
      appBar: AppBar(title: Text(party?.displayName ?? '파티 기록')),
      body: _error != null
          ? Center(child: Text(_error!))
          : party == null
              ? const Center(child: CircularProgressIndicator())
              : _buildBody(party),
    );
  }

  Widget _buildBody(Party party) {
    final members = _members(party);
    final lines = [
      for (final m in members)
        if (_focus == null || _focus == m.uid)
          RouteLine(id: m.uid, segments: m.segments, color: MemberColors.of(m.colorIndex), width: m.uid == uid ? 6 : 4),
    ].where((l) => l.pointCount > 1).toList();
    final markers = {
      for (final m in members)
        if (m.stillRunning && m.live?.latitude != null)
          Marker(
            markerId: MarkerId('live_${m.uid}'),
            position: LatLng(m.live!.latitude!, m.live!.longitude!),
            icon: BitmapDescriptor.defaultMarkerWithHue(MemberColors.hueOf(m.colorIndex)),
            infoWindow: InfoWindow(title: '${m.name} · 러닝중', snippet: '${m.live!.distanceKm.toStringAsFixed(2)} km'),
          ),
    };

    final ranking = _finalRanking(party, members);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
      children: [
        _Header(party: party),
        const SizedBox(height: 12),
        AspectRatio(
          aspectRatio: 1.1,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: lines.isEmpty && markers.isEmpty
                ? Container(
                    color: AppColors.surface,
                    alignment: Alignment.center,
                    child: const Text('아직 완료된 경로가 없어요', style: TextStyle(color: AppColors.textSecondary)),
                  )
                : RouteMap(lines: lines, markers: markers, showStartEnd: false),
          ),
        ),
        const SizedBox(height: 6),
        const Text('파티원을 누르면 해당 파티원의 경로만 보여요',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
        const SizedBox(height: 14),
        if (party.loyalty) ...[
          _LoyaltyCard(party: party, members: members),
          const SizedBox(height: 14),
        ],
        _Card(
          title: party.loyalty ? '기여 순위' : '최종 순위',
          child: Column(
            children: [
              for (var i = 0; i < ranking.length; i++)
                _MemberRow(
                  rank: i + 1,
                  m: ranking[i],
                  isMe: ranking[i].uid == uid,
                  selected: _focus == ranking[i].uid,
                  onTap: () => setState(() => _focus = _focus == ranking[i].uid ? null : ranking[i].uid),
                ),
            ],
          ),
        ),
        if (!party.loyalty) ...[
          const SizedBox(height: 14),
          _Card(title: 'km별 순위 변동', child: _RankChangeChart(members: members)),
          const SizedBox(height: 14),
          _Card(title: '구간별 페이스 (1km)', child: _SplitTable(members: members, myUid: uid)),
        ],
        const SizedBox(height: 14),
        _Card(title: '시간별 페이스 (5분 단위)', child: _TimePaceChart(members: members)),
      ],
    );
  }

  List<_MemberResult> _finalRanking(Party party, List<_MemberResult> members) {
    final list = [...members];
    double liveDist(_MemberResult m) =>
        m.stillRunning ? m.totalDistanceM + (m.live!.distanceKm * 1000) : m.totalDistanceM;
    if (party.goalType == GoalType.distance && !party.loyalty) {
      // 목표 거리 완주자는 기록(시간) 순, 나머지는 거리 순
      final goal = (party.goalValue ?? 0) * 0.99;
      list.sort((a, b) {
        final aDone = a.totalDistanceM >= goal && a.durationMs != null;
        final bDone = b.totalDistanceM >= goal && b.durationMs != null;
        if (aDone && bDone) return a.durationMs!.compareTo(b.durationMs!);
        if (aDone != bDone) return aDone ? -1 : 1;
        return liveDist(b).compareTo(liveDist(a));
      });
    } else {
      list.sort((a, b) => liveDist(b).compareTo(liveDist(a)));
    }
    return list;
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.party});
  final Party party;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (party.status) {
      PartyStatus.waiting => ('대기중', AppColors.textSecondary),
      PartyStatus.running => ('진행중', AppColors.neon),
      PartyStatus.finished => ('종료', AppColors.textSecondary),
      PartyStatus.success => ('의리게임 성공 🎉', AppColors.neon),
      PartyStatus.failed => ('의리게임 실패', AppColors.danger),
    };
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${party.memberIds.length}명 · ${Fmt.goal(party.goalType.name, party.goalValue)}'
                  '${party.loyalty ? ' · 의리게임' : ''}'),
              if (party.startAt != null)
                Text('출발 ${Fmt.dateTime(party.startAt!)}',
                    style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
              Text('ID ${PartyIds.toDisplay(party.key)}',
                  style: const TextStyle(color: AppColors.textSecondary, fontSize: 11)),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(10)),
          child: Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w800)),
        ),
      ],
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(18)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
            const SizedBox(height: 12),
            child,
          ],
        ),
      );
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({required this.rank, required this.m, required this.isMe, required this.selected, required this.onTap});
  final int rank;
  final _MemberResult m;
  final bool isMe;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final running = m.stillRunning;
    final dist = running ? m.totalDistanceM + m.live!.distanceKm * 1000 : m.totalDistanceM;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? MemberColors.of(m.colorIndex).withValues(alpha: 0.12) : AppColors.surfaceHigh,
          borderRadius: BorderRadius.circular(12),
          border: Border(left: BorderSide(color: MemberColors.of(m.colorIndex), width: 4)),
        ),
        child: Row(
          children: [
            SizedBox(width: 36, child: Text(Fmt.rankLabel(rank), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900))),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(isMe ? '${m.name} (나)' : m.name, style: const TextStyle(fontWeight: FontWeight.w800)),
                  Text(
                    running
                        ? m.statusLabel
                        : (m.runs.isEmpty
                            ? m.statusLabel
                            : '${Fmt.pace(m.avgPace)} /km · ${Fmt.duration(m.durationMs ?? 0)}'
                                '${m.runs.length > 1 ? ' · ${m.runs.length}회' : ''}'),
                    style: TextStyle(color: running ? AppColors.neon : AppColors.textSecondary, fontSize: 12),
                  ),
                ],
              ),
            ),
            Text('${Fmt.km(dist)} km', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
          ],
        ),
      ),
    );
  }
}

class _LoyaltyCard extends StatelessWidget {
  const _LoyaltyCard({required this.party, required this.members});
  final Party party;
  final List<_MemberResult> members;

  @override
  Widget build(BuildContext context) {
    final goal = party.goalValue ?? 1;
    // 서버 검증 합계 + 아직 달리는 중인 파티원의 실시간 거리
    final liveExtra = members.where((m) => m.stillRunning).fold<double>(0, (s, m) => s + m.live!.distanceKm * 1000);
    final total = party.loyaltyTotalM + liveExtra;
    final left = party.loyaltyDeadline == null ? null : party.loyaltyDeadline! - ServerClock.nowMs();
    return _Card(
      title: '🤝 의리게임',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${Fmt.km(total)} / ${Fmt.km(goal)} km',
              style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: AppColors.neon)),
          const SizedBox(height: 8),
          // 기여도 누적 막대
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              height: 14,
              child: LayoutBuilder(builder: (_, c) {
                final children = <Widget>[];
                for (final m in members) {
                  final contrib = (party.loyaltyContributions[m.uid] ?? 0) +
                      (m.stillRunning ? m.live!.distanceKm * 1000 : 0);
                  final w = c.maxWidth * (contrib / goal).clamp(0.0, 1.0);
                  if (w > 0) children.add(Container(width: w, color: MemberColors.of(m.colorIndex)));
                }
                return Container(color: AppColors.outline, child: Row(children: children));
              }),
            ),
          ),
          const SizedBox(height: 8),
          if (party.status == PartyStatus.running && left != null)
            Text(left > 0 ? '남은 시간 ${Fmt.duration(left)} — 24시간 안에 합계를 채워야 성공!' : '제한 시간 종료',
                style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
        ],
      ),
    );
  }
}

/// km 지점마다 누가 먼저 통과했는지 → 순위 변동 (공통 출발 시각 기준 raceMs)
class _RankChangeChart extends StatelessWidget {
  const _RankChangeChart({required this.members});
  final List<_MemberResult> members;

  @override
  Widget build(BuildContext context) {
    final withSplits = members.where((m) => m.splits.isNotEmpty).toList();
    final maxKm = withSplits.fold<int>(0, (s, m) => math.max(s, m.splits.length));
    if (withSplits.length < 2 || maxKm < 1) {
      return const Text('2명 이상이 1km 이상 완주하면 순위 변동을 볼 수 있어요',
          style: TextStyle(color: AppColors.textSecondary));
    }
    final ranks = <String, List<FlSpot>>{};
    for (var k = 1; k <= maxKm; k++) {
      final passed = <(String, int)>[];
      for (final m in withSplits) {
        final s = m.splits.where((e) => e.km == k).firstOrNull;
        if (s != null) passed.add((m.uid, s.raceMs ?? s.movingMs));
      }
      passed.sort((a, b) => a.$2.compareTo(b.$2));
      for (var i = 0; i < passed.length; i++) {
        ranks.putIfAbsent(passed[i].$1, () => []).add(FlSpot(k.toDouble(), -(i + 1).toDouble()));
      }
    }
    final n = withSplits.length;
    return Column(
      children: [
        SizedBox(
          height: 200,
          child: LineChart(LineChartData(
            minX: 1,
            maxX: math.max(2, maxKm).toDouble(),
            minY: -n - 0.3,
            maxY: -0.7,
            gridData: FlGridData(
              drawVerticalLine: true,
              horizontalInterval: 1,
              verticalInterval: 1,
              getDrawingHorizontalLine: (_) => const FlLine(color: AppColors.outline, strokeWidth: 0.5),
              getDrawingVerticalLine: (_) => const FlLine(color: AppColors.outline, strokeWidth: 0.5),
            ),
            borderData: FlBorderData(show: false),
            titlesData: FlTitlesData(
              topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              leftTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 32,
                  interval: 1,
                  getTitlesWidget: (v, meta) => SideTitleWidget(
                    meta: meta,
                    child: Text('${(-v).round()}위', style: const TextStyle(fontSize: 10, color: AppColors.textSecondary)),
                  ),
                ),
              ),
              bottomTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  interval: 1,
                  getTitlesWidget: (v, meta) => SideTitleWidget(
                    meta: meta,
                    child: Text('${v.round()}km', style: const TextStyle(fontSize: 10, color: AppColors.textSecondary)),
                  ),
                ),
              ),
            ),
            lineTouchData: const LineTouchData(enabled: false),
            lineBarsData: [
              for (final m in withSplits)
                if (ranks[m.uid] != null)
                  LineChartBarData(
                    spots: ranks[m.uid]!,
                    color: MemberColors.of(m.colorIndex),
                    barWidth: 3,
                    dotData: const FlDotData(show: true),
                  ),
            ],
          )),
        ),
        const SizedBox(height: 8),
        _Legend(members: withSplits),
      ],
    );
  }
}

class _SplitTable extends StatelessWidget {
  const _SplitTable({required this.members, required this.myUid});
  final List<_MemberResult> members;
  final String myUid;

  @override
  Widget build(BuildContext context) {
    final withSplits = members.where((m) => m.splits.isNotEmpty).toList();
    final maxKm = withSplits.fold<int>(0, (s, m) => math.max(s, m.splits.length));
    if (maxKm == 0) {
      return const Text('완주한 구간이 없어요', style: TextStyle(color: AppColors.textSecondary));
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columnSpacing: 18,
        horizontalMargin: 0,
        headingRowHeight: 36,
        dataRowMinHeight: 32,
        dataRowMaxHeight: 36,
        columns: [
          const DataColumn(label: Text('구간')),
          for (final m in withSplits)
            DataColumn(
              label: Row(children: [
                CircleAvatar(radius: 5, backgroundColor: MemberColors.of(m.colorIndex)),
                const SizedBox(width: 4),
                Text(m.uid == myUid ? '나' : m.name, style: const TextStyle(fontWeight: FontWeight.w800)),
              ]),
            ),
        ],
        rows: [
          for (var k = 1; k <= maxKm; k++)
            () {
              final paces = withSplits.map((m) => m.splits.where((s) => s.km == k).firstOrNull?.paceSec).toList();
              final valid = paces.whereType<double>();
              final best = valid.isEmpty ? null : valid.reduce(math.min);
              return DataRow(cells: [
                DataCell(Text('${k}km', style: const TextStyle(color: AppColors.textSecondary))),
                for (final p in paces)
                  DataCell(Text(
                    p == null ? '-' : Fmt.pace(p),
                    style: TextStyle(
                      fontWeight: p == best ? FontWeight.w900 : FontWeight.w500,
                      color: p == best ? AppColors.neon : AppColors.textPrimary,
                    ),
                  )),
              ]);
            }(),
        ],
      ),
    );
  }
}

/// 5분 단위 페이스 변화
class _TimePaceChart extends StatelessWidget {
  const _TimePaceChart({required this.members});
  final List<_MemberResult> members;

  static const bucketSec = 300;

  List<FlSpot> _spots(List<TimelineSample> tl) {
    if (tl.length < 2) return [];
    double distAt(int t) {
      // 선형 보간
      if (t <= tl.first.t) return tl.first.t == 0 ? tl.first.d : tl.first.d * t / tl.first.t;
      for (var i = 1; i < tl.length; i++) {
        if (tl[i].t >= t) {
          final a = tl[i - 1], b = tl[i];
          final f = (t - a.t) / math.max(1, b.t - a.t);
          return a.d + (b.d - a.d) * f;
        }
      }
      return tl.last.d;
    }

    final spots = <FlSpot>[];
    final end = tl.last.t;
    for (var t = bucketSec; t <= end + bucketSec ~/ 2; t += bucketSec) {
      final tt = math.min(t, end);
      final from = t - bucketSec;
      final dd = distAt(tt) - distAt(from);
      if (dd < 50) continue;
      final pace = (tt - from) / (dd / 1000);
      if (pace > 1200) continue;
      spots.add(FlSpot(tt / 60, -pace));
    }
    return spots;
  }

  @override
  Widget build(BuildContext context) {
    final data = <_MemberResult, List<FlSpot>>{};
    for (final m in members) {
      final s = _spots(m.timeline);
      if (s.isNotEmpty) data[m] = s;
    }
    if (data.isEmpty) {
      return const Text('5분 이상 달린 기록이 있으면 페이스 변화를 볼 수 있어요',
          style: TextStyle(color: AppColors.textSecondary));
    }
    final all = data.values.expand((e) => e).toList();
    final minY = all.map((e) => e.y).reduce(math.min) - 15;
    final maxY = all.map((e) => e.y).reduce(math.max) + 15;
    return Column(
      children: [
        SizedBox(
          height: 200,
          child: LineChart(LineChartData(
            minY: minY,
            maxY: maxY,
            gridData: FlGridData(
              drawVerticalLine: false,
              getDrawingHorizontalLine: (_) => const FlLine(color: AppColors.outline, strokeWidth: 0.5),
            ),
            borderData: FlBorderData(show: false),
            titlesData: FlTitlesData(
              topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              leftTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 44,
                  interval: math.max(10, ((maxY - minY) / 3).roundToDouble()),
                  getTitlesWidget: (v, meta) => SideTitleWidget(
                    meta: meta,
                    child: Text(Fmt.pace(-v), style: const TextStyle(fontSize: 10, color: AppColors.textSecondary)),
                  ),
                ),
              ),
              bottomTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  interval: 5,
                  getTitlesWidget: (v, meta) => SideTitleWidget(
                    meta: meta,
                    child: Text('${v.round()}분', style: const TextStyle(fontSize: 10, color: AppColors.textSecondary)),
                  ),
                ),
              ),
            ),
            lineTouchData: LineTouchData(
              touchTooltipData: LineTouchTooltipData(
                getTooltipItems: (spots) => spots
                    .map((s) => LineTooltipItem(
                        '${s.x.round()}분 ${Fmt.pace(-s.y)}', TextStyle(color: s.bar.color, fontWeight: FontWeight.w800)))
                    .toList(),
              ),
            ),
            lineBarsData: [
              for (final e in data.entries)
                LineChartBarData(
                  spots: e.value,
                  color: MemberColors.of(e.key.colorIndex),
                  isCurved: true,
                  barWidth: 3,
                  dotData: const FlDotData(show: false),
                ),
            ],
          )),
        ),
        const SizedBox(height: 8),
        _Legend(members: data.keys.toList()),
      ],
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.members});
  final List<_MemberResult> members;

  @override
  Widget build(BuildContext context) => Wrap(
        spacing: 12,
        runSpacing: 4,
        children: members
            .map((m) => Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(width: 12, height: 4, color: MemberColors.of(m.colorIndex)),
                  const SizedBox(width: 4),
                  Text(m.name, style: const TextStyle(fontSize: 12)),
                ]))
            .toList(),
      );
}
