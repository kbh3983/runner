import 'package:firebase_auth/firebase_auth.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:table_calendar/table_calendar.dart';

import '../../config/app_config.dart';
import '../../core/format.dart';
import '../../data/local/local_db.dart';
import '../../data/models/gps_point.dart';
import '../../data/models/run_record.dart';
import '../../theme/app_theme.dart';
import '../../widgets/run_thumb.dart';
import 'run_detail_screen.dart';

/// 홈 = 지난 러닝 기록 (월별 달력 / 리스트). 목표는 "꾸준함" 유도.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final uid = AppConfig.useFirebase ? FirebaseAuth.instance.currentUser!.uid : 'dummy_uid';
  List<RunRecord> _runs = [];
  Map<String, RunPhoto> _photos = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    LocalDb.instance.changes.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    LocalDb.instance.changes.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final runs = await LocalDb.instance.getFinishedRuns(uid);
    final photos = await LocalDb.instance.getFirstPhotos(runs.map((r) => r.id).toList());
    if (!mounted) return;
    setState(() {
      _runs = runs;
      _photos = photos;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('홈 · 러닝 기록'),
          bottom: const TabBar(
            indicatorColor: AppColors.neon,
            labelColor: AppColors.neon,
            unselectedLabelColor: AppColors.textSecondary,
            tabs: [
              Tab(icon: Icon(Icons.calendar_month), text: '월별'),
              Tab(icon: Icon(Icons.view_list), text: '리스트'),
            ],
          ),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : TabBarView(
                children: [
                  _MonthView(runs: _runs, photos: _photos),
                  _ListView(runs: _runs, photos: _photos),
                ],
              ),
      ),
    );
  }
}

void openRunDetail(BuildContext context, RunRecord run) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => RunDetailScreen(runId: run.id)));

// ====================================================================== 월별 뷰

class _MonthView extends StatefulWidget {
  const _MonthView({required this.runs, required this.photos});
  final List<RunRecord> runs;
  final Map<String, RunPhoto> photos;

  @override
  State<_MonthView> createState() => _MonthViewState();
}

class _MonthViewState extends State<_MonthView> with AutomaticKeepAliveClientMixin {
  DateTime _focused = DateTime.now();
  DateTime? _selected = DateTime.now();

  @override
  bool get wantKeepAlive => true;

  Map<DateTime, List<RunRecord>> get _byDay {
    final map = <DateTime, List<RunRecord>>{};
    for (final r in widget.runs) {
      final d = DateTime.fromMillisecondsSinceEpoch(r.startedAt);
      map.putIfAbsent(DateTime(d.year, d.month, d.day), () => []).add(r);
    }
    return map;
  }

  List<RunRecord> _runsOn(DateTime day) => _byDay[DateTime(day.year, day.month, day.day)] ?? [];

  Widget _dayCell(DateTime day, {bool selected = false, bool today = false}) {
    final runs = _runsOn(day);
    final number = Text(
      '${day.day}',
      style: TextStyle(
        fontWeight: FontWeight.w800,
        fontSize: 12,
        color: runs.isNotEmpty ? Colors.white : (today ? AppColors.neon : AppColors.textPrimary),
        shadows: runs.isNotEmpty ? const [Shadow(blurRadius: 4, color: Colors.black)] : null,
      ),
    );
    RunPhoto? photo;
    for (final r in runs) {
      photo ??= widget.photos[r.id];
    }
    return Container(
      margin: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: selected
            ? Border.all(color: AppColors.neon, width: 2)
            : today
                ? Border.all(color: AppColors.outline)
                : null,
      ),
      child: runs.isEmpty
          ? Center(child: number)
          : Stack(
              fit: StackFit.expand,
              children: [
                // 사진이 있으면 사진, 없으면 러닝 경로 섬네일
                RunThumb(run: runs.first, photo: photo, radius: 8),
                Positioned(left: 4, top: 2, child: number),
                if (runs.length > 1)
                  Positioned(
                    right: 3,
                    bottom: 3,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      decoration: BoxDecoration(color: AppColors.neon, borderRadius: BorderRadius.circular(6)),
                      child: Text('${runs.length}',
                          style: const TextStyle(color: Colors.black, fontSize: 10, fontWeight: FontWeight.w900)),
                    ),
                  ),
              ],
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final monthRuns = widget.runs.where((r) {
      final d = DateTime.fromMillisecondsSinceEpoch(r.startedAt);
      return d.year == _focused.year && d.month == _focused.month;
    }).toList();
    final monthDist = monthRuns.fold<double>(0, (s, r) => s + r.distanceM);
    final monthDays = monthRuns.map((r) => DateTime.fromMillisecondsSinceEpoch(r.startedAt).day).toSet().length;
    final monthTime = monthRuns.fold<int>(0, (s, r) => s + r.durationMs);
    final selectedRuns = _selected == null ? <RunRecord>[] : _runsOn(_selected!);

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
      children: [
        Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(16)),
          child: Row(
            children: [
              _MiniStat(value: Fmt.km(monthDist, digits: 1), label: 'km'),
              _MiniStat(value: '${monthRuns.length}', label: '러닝'),
              _MiniStat(value: '$monthDays', label: '달린 날'),
              _MiniStat(value: Fmt.durationKo(monthTime), label: '총 시간'),
            ],
          ),
        ),
        const SizedBox(height: 8),
        TableCalendar<RunRecord>(
          locale: 'ko_KR',
          firstDay: DateTime(2020),
          lastDay: DateTime.now().add(const Duration(days: 365)),
          focusedDay: _focused,
          selectedDayPredicate: (d) => _selected != null && isSameDay(d, _selected),
          eventLoader: _runsOn,
          rowHeight: 58,
          daysOfWeekHeight: 22,
          startingDayOfWeek: StartingDayOfWeek.sunday,
          availableCalendarFormats: const {CalendarFormat.month: '월'},
          headerStyle: const HeaderStyle(
            titleCentered: true,
            formatButtonVisible: false,
            titleTextStyle: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
          ),
          onDaySelected: (sel, foc) => setState(() {
            _selected = sel;
            _focused = foc;
          }),
          onPageChanged: (foc) => setState(() => _focused = foc),
          calendarBuilders: CalendarBuilders(
            defaultBuilder: (_, day, _) => _dayCell(day),
            todayBuilder: (_, day, _) => _dayCell(day, today: true),
            selectedBuilder: (_, day, _) => _dayCell(day, selected: true, today: isSameDay(day, DateTime.now())),
            outsideBuilder: (_, day, _) => Center(
              child: Text('${day.day}', style: const TextStyle(color: AppColors.outline, fontSize: 12)),
            ),
            markerBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
        ),
        const SizedBox(height: 12),
        if (_selected != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Text(Fmt.date(_selected!.millisecondsSinceEpoch),
                style: const TextStyle(fontWeight: FontWeight.w800, color: AppColors.textSecondary)),
          ),
        if (selectedRuns.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text('이 날은 기록이 없어요. 오늘 한 번 달려볼까요? 🏃',
                textAlign: TextAlign.center, style: TextStyle(color: AppColors.textSecondary)),
          ),
        ...selectedRuns.map((r) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: RunListTile(run: r, photo: widget.photos[r.id], onTap: () => openRunDetail(context, r)),
            )),
      ],
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({required this.value, required this.label});
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) => Expanded(
        child: Column(
          children: [
            FittedBox(
              child: Text(value,
                  style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 18, color: AppColors.neon)),
            ),
            const SizedBox(height: 2),
            Text(label, style: const TextStyle(color: AppColors.textSecondary, fontSize: 11)),
          ],
        ),
      );
}

// ====================================================================== 리스트 뷰

class _ListView extends StatelessWidget {
  const _ListView({required this.runs, required this.photos});
  final List<RunRecord> runs;
  final Map<String, RunPhoto> photos;

  @override
  Widget build(BuildContext context) {
    if (runs.isEmpty) {
      return const Center(
        child: Text('아직 러닝 기록이 없어요', style: TextStyle(color: AppColors.textSecondary)),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      itemCount: runs.length + 1,
      itemBuilder: (_, i) {
        if (i == 0) return _PaceTrend(runs: runs);
        final run = runs[i - 1];
        // 바로 이전(더 과거) 기록과 페이스 비교 → 나아지고 있는지
        final older = i < runs.length ? runs[i] : null;
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: RunListTile(
            run: run,
            photo: photos[run.id],
            previous: older,
            onTap: () => openRunDetail(context, run),
          ),
        );
      },
    );
  }
}

/// 최근 러닝 페이스 추이 (위로 갈수록 빠름)
class _PaceTrend extends StatelessWidget {
  const _PaceTrend({required this.runs});
  final List<RunRecord> runs;

  @override
  Widget build(BuildContext context) {
    final valid = runs.where((r) => r.avgPaceSecPerKm != null && r.distanceM >= 500).take(20).toList().reversed.toList();
    if (valid.length < 2) return const SizedBox(height: 4);
    final spots = [
      for (var i = 0; i < valid.length; i++) FlSpot(i.toDouble(), -valid[i].avgPaceSecPerKm!),
    ];
    final paces = valid.map((r) => r.avgPaceSecPerKm!).toList();
    final minP = paces.reduce((a, b) => a < b ? a : b);
    final maxP = paces.reduce((a, b) => a > b ? a : b);
    final improving = paces.last < paces.first;
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.fromLTRB(16, 16, 20, 8),
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(18)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('페이스 추이', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
              const SizedBox(width: 8),
              Text(
                improving ? '▲ 좋아지고 있어요' : '꾸준함이 실력이에요',
                style: TextStyle(color: improving ? AppColors.neon : AppColors.textSecondary, fontSize: 12),
              ),
            ],
          ),
          Text('최근 ${valid.length}회 · 최고 ${Fmt.pace(minP)}',
              style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
          const SizedBox(height: 12),
          SizedBox(
            height: 140,
            child: LineChart(
              LineChartData(
                minY: -(maxP + 15),
                maxY: -(minP - 15),
                gridData: const FlGridData(show: false),
                borderData: FlBorderData(show: false),
                titlesData: FlTitlesData(
                  topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  bottomTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 44,
                      interval: ((maxP - minP) / 2).clamp(5, 600).toDouble(),
                      getTitlesWidget: (v, meta) => SideTitleWidget(
                        meta: meta,
                        child: Text(Fmt.pace(-v), style: const TextStyle(fontSize: 10, color: AppColors.textSecondary)),
                      ),
                    ),
                  ),
                ),
                lineTouchData: LineTouchData(
                  touchTooltipData: LineTouchTooltipData(
                    getTooltipItems: (spots) => spots
                        .map((s) => LineTooltipItem(Fmt.pace(-s.y), const TextStyle(fontWeight: FontWeight.w800)))
                        .toList(),
                  ),
                ),
                lineBarsData: [
                  LineChartBarData(
                    spots: spots,
                    isCurved: true,
                    color: AppColors.neon,
                    barWidth: 3,
                    dotData: const FlDotData(show: true),
                    belowBarData: BarAreaData(show: true, color: AppColors.neon.withValues(alpha: 0.08)),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 러닝 기록 한 줄 요약 (평균 페이스 / km / 시간)
class RunListTile extends StatelessWidget {
  const RunListTile({super.key, required this.run, this.photo, this.previous, required this.onTap});
  final RunRecord run;
  final RunPhoto? photo;
  final RunRecord? previous;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    double? delta;
    if (previous?.avgPaceSecPerKm != null && run.avgPaceSecPerKm != null) {
      delta = run.avgPaceSecPerKm! - previous!.avgPaceSecPerKm!;
    }
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              SizedBox(width: 64, height: 64, child: RunThumb(run: run, photo: photo)),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(Fmt.dateTime(run.startedAt),
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                        ),
                        if (run.isGroup) ...[
                          const SizedBox(width: 6),
                          const Icon(Icons.groups, size: 14, color: AppColors.neon),
                        ],
                        if (run.syncStatus != SyncStatus.synced) ...[
                          const SizedBox(width: 6),
                          const Icon(Icons.cloud_off, size: 13, color: AppColors.textSecondary),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text('${Fmt.km(run.distanceM)} km',
                        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
                    const SizedBox(height: 2),
                    Text('${Fmt.pace(run.avgPaceSecPerKm)} /km  ·  ${Fmt.duration(run.durationMs)}',
                        style: const TextStyle(color: AppColors.textSecondary)),
                  ],
                ),
              ),
              if (delta != null && delta.abs() >= 1)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Icon(delta < 0 ? Icons.trending_up : Icons.trending_down,
                        color: delta < 0 ? AppColors.neon : AppColors.danger, size: 18),
                    Text(
                      '${delta < 0 ? '-' : '+'}${Fmt.pace(delta.abs()).replaceFirst("0'", '')}',
                      style: TextStyle(fontSize: 11, color: delta < 0 ? AppColors.neon : AppColors.danger),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
