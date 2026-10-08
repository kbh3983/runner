import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../data/models/run_record.dart';
import '../../services/leaderboard_service.dart';
import '../../services/point_service.dart';
import '../../services/region_service.dart';
import '../../theme/app_theme.dart';
import '../leaderboard/leaderboard_screen.dart';
import '../points/points_screen.dart';

enum _Period {
  w4('4주', 28),
  m3('3개월', 90),
  y1('1년', 365),
  all('전체', null);

  const _Period(this.label, this.days);
  final String label;
  final int? days;
}

/// 러닝 통계: 항목별 카드 모음.
/// - 기간 선택(4주/3개월/1년/전체)이 적용되는 카드: 요약, 페이스 추이, 평균, 요일/시간대/거리/유형 분포, 활동 지역, 고도·속도
/// - 항상 전체 기록 기준인 카드: 주간/월간 마일리지, 개인 최고 기록, 연속 러닝
class StatsView extends StatefulWidget {
  const StatsView({super.key, required this.runs, required this.onOpenRun});

  /// 최신순 완료 기록
  final List<RunRecord> runs;
  final void Function(RunRecord run) onOpenRun;

  @override
  State<StatsView> createState() => _StatsViewState();
}

class _StatsViewState extends State<StatsView>
    with AutomaticKeepAliveClientMixin {
  _Period _period = _Period.m3;

  @override
  void initState() {
    super.initState();
    // 지역 정보가 없는 과거 러닝에 대해 백그라운드 역지오코딩 수행
    RegionService.instance.backfillMissingRegions();
  }

  @override
  bool get wantKeepAlive => true;

  static DateTime _day(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return DateTime(d.year, d.month, d.day);
  }

  static DateTime _weekStart(DateTime d) =>
      DateTime(d.year, d.month, d.day - (d.weekday - 1));

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final all = widget.runs;
    if (all.isEmpty) {
      return const Center(
        child: Text(
          '아직 러닝 기록이 없어요\n달리고 나면 통계가 쌓여요 📊',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.textSecondary, height: 1.5),
        ),
      );
    }
    final now = DateTime.now();
    final days = _period.days;
    final runs = days == null
        ? all
        : all
              .where(
                (r) => DateTime.fromMillisecondsSinceEpoch(
                  r.startedAt,
                ).isAfter(now.subtract(Duration(days: days))),
              )
              .toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        _periodSelector(),
        const SizedBox(height: 14),
        _monthlyRankingCard(now),
        if (runs.isEmpty)
          const _StatCard(
            icon: Icons.insights,
            title: '선택한 기간',
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text(
                '이 기간에는 러닝 기록이 없어요',
                style: TextStyle(color: AppColors.textSecondary),
              ),
            ),
          )
        else ...[
          _summaryCard(runs),
          _paceTrendCard(runs),
          _averageCard(runs),
        ],
        _weeklyCard(all, now),
        _monthlyCard(all, now),
        _recordsCard(all),
        _streakCard(all, now),
        if (runs.isNotEmpty) ...[
          _weekdayCard(runs),
          _timeOfDayCard(runs),
          _distanceBucketCard(runs),
          _elevationCard(runs),
          _modeCard(runs),
          _regionCard(runs),
        ],
      ],
    );
  }

  Widget _periodSelector() => SizedBox(
    width: double.infinity,
    child: SegmentedButton<_Period>(
      showSelectedIcon: false,
      style: SegmentedButton.styleFrom(
        selectedBackgroundColor: AppColors.neon,
        selectedForegroundColor: Colors.black,
        visualDensity: VisualDensity.compact,
      ),
      segments: [
        for (final p in _Period.values)
          ButtonSegment(value: p, label: Text(p.label)),
      ],
      selected: {_period},
      onSelectionChanged: (s) => setState(() => _period = s.first),
    ),
  );

  // ---------------------------------------------------------------- 월간 랭킹

  Widget _monthlyRankingCard(DateTime now) {
    final currentKey = '${now.year}-${now.month.toString().padLeft(2, '0')}';
    final prevMonthDate = DateTime(now.year, now.month - 1, 1);
    final prevKey = '${prevMonthDate.year}-${prevMonthDate.month.toString().padLeft(2, '0')}';

    return FutureBuilder<List<MonthlyLeaderboard>>(
      future: Future.wait([
        LeaderboardService.instance.getMonthlyLeaderboard(currentKey),
        LeaderboardService.instance.getMonthlyLeaderboard(prevKey),
      ]),
      builder: (context, snapshot) {
        final currentLb = snapshot.data != null ? snapshot.data![0] : null;
        final prevLb = snapshot.data != null ? snapshot.data![1] : null;
        final myCur = currentLb?.myEntry;
        final myPrev = prevLb?.myEntry;

        return InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const LeaderboardScreen()),
            );
          },
          child: _StatCard(
            icon: Icons.emoji_events_rounded,
            title: '월간 마일리지 랭킹',
            caption: '혼자/같이 달린 모든 거리가 합산된 앱 전체 순위예요',
            trailing: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '전체 랭킹',
                  style: TextStyle(
                    color: AppColors.neon,
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                  ),
                ),
                SizedBox(width: 2),
                Icon(Icons.chevron_right, size: 16, color: AppColors.neon),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Column(
                children: [
                  Row(
                    children: [
                  // 이번 달
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            const Color(0xFFFFD700).withValues(alpha: 0.12),
                            AppColors.surfaceHigh,
                          ],
                        ),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: const Color(0xFFFFD700).withValues(alpha: 0.3),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                '${now.month}월 (진행중)',
                                style: const TextStyle(
                                  color: Color(0xFFFFD700),
                                  fontWeight: FontWeight.w800,
                                  fontSize: 12,
                                ),
                              ),
                              const Spacer(),
                              const Icon(Icons.bolt_rounded, size: 14, color: Color(0xFFFFD700)),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.baseline,
                            textBaseline: TextBaseline.alphabetic,
                            children: [
                              Text(
                                myCur != null ? '${myCur.rank}' : '-',
                                style: const TextStyle(
                                  fontSize: 26,
                                  fontWeight: FontWeight.w900,
                                  color: AppColors.textPrimary,
                                ),
                              ),
                              const Text(
                                ' 위',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w800,
                                  color: AppColors.textSecondary,
                                ),
                              ),
                              const Spacer(),
                              Text(
                                myCur != null ? '${Fmt.km(myCur.distanceM, digits: 1)} km' : '0.0 km',
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w900,
                                  color: AppColors.neon,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            currentLb != null && myCur != null
                                ? '상위 ${((myCur.rank / currentLb.totalParticipants) * 100).toStringAsFixed(1)}% (${currentLb.totalParticipants}명)'
                                : '달리고 순위를 올려보세요! 🏃',
                            style: const TextStyle(
                              fontSize: 11,
                              color: AppColors.textSecondary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),

                  // 지난 달 (마감)
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceHigh,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: AppColors.outline.withValues(alpha: 0.5),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                '${prevMonthDate.month}월 (마감)',
                                style: const TextStyle(
                                  color: AppColors.textSecondary,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 12,
                                ),
                              ),
                              const Spacer(),
                              const Icon(Icons.lock_clock_rounded, size: 12, color: AppColors.textSecondary),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.baseline,
                            textBaseline: TextBaseline.alphabetic,
                            children: [
                              Text(
                                myPrev != null ? '${myPrev.rank}' : '-',
                                style: const TextStyle(
                                  fontSize: 26,
                                  fontWeight: FontWeight.w900,
                                  color: AppColors.textPrimary,
                                ),
                              ),
                              const Text(
                                ' 위',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w800,
                                  color: AppColors.textSecondary,
                                ),
                              ),
                              const Spacer(),
                              Text(
                                myPrev != null ? '${Fmt.km(myPrev.distanceM, digits: 1)} km' : '0.0 km',
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w900,
                                  color: Colors.white70,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            prevLb != null && myPrev != null
                                ? '최종 마감 (${prevLb.totalParticipants}명)'
                                : '마감 기록 없음',
                            style: const TextStyle(
                              fontSize: 11,
                              color: AppColors.textSecondary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const PointsScreen()),
                  );
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: const Color(0xFFFFD700).withValues(alpha: 0.2),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Text('🪙', style: TextStyle(fontSize: 14)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ValueListenableBuilder<int>(
                          valueListenable: PointService.instance.balance,
                          builder: (context, pts, _) => Text(
                            '러닝 게임머니: $pts P',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFFFFD700),
                            ),
                          ),
                        ),
                      ),
                      const Text(
                        '미션 & 내역',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: AppColors.neon,
                        ),
                      ),
                      const SizedBox(width: 2),
                      const Icon(Icons.chevron_right, size: 14, color: AppColors.neon),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
      },
    );
  }

  // ---------------------------------------------------------------- 요약

  Widget _summaryCard(List<RunRecord> runs) {
    final dist = runs.fold<double>(0, (s, r) => s + r.distanceM);
    final time = runs.fold<int>(0, (s, r) => s + r.durationMs);
    final pace = dist > 0 ? (time / 1000) / (dist / 1000) : null;
    return _StatCard(
      icon: Icons.dashboard_rounded,
      title: '요약',
      caption: '${_period.label} 기준',
      child: Column(
        children: [
          Row(
            children: [
              _Metric(value: Fmt.km(dist, digits: 1), unit: ' km', label: '총 마일리지'),
              _Metric(value: '${runs.length}', unit: '회', label: '러닝 횟수'),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              _Metric(value: Fmt.minutes(time), label: '총 시간'),
              _Metric(value: Fmt.pace(pace), unit: ' /km', label: '평균 페이스'),
            ],
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 페이스 추이

  Widget _paceTrendCard(List<RunRecord> runs) {
    final valid = runs
        .where((r) => r.avgPaceSecPerKm != null && r.distanceM >= 500)
        .take(20)
        .toList()
        .reversed
        .toList();
    if (valid.length < 2) {
      return const _StatCard(
        icon: Icons.speed,
        title: '페이스 추이',
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Text(
            '러닝이 2회 이상 쌓이면 추이를 볼 수 있어요',
            style: TextStyle(color: AppColors.textSecondary),
          ),
        ),
      );
    }
    final spots = [
      for (var i = 0; i < valid.length; i++)
        FlSpot(i.toDouble(), -valid[i].avgPaceSecPerKm!),
    ];
    final paces = valid.map((r) => r.avgPaceSecPerKm!).toList();
    final minP = paces.reduce((a, b) => a < b ? a : b);
    final maxP = paces.reduce((a, b) => a > b ? a : b);
    final improving = paces.last < paces.first;
    return _StatCard(
      icon: Icons.speed,
      title: '페이스 추이',
      caption: '최근 ${valid.length}회 · 최고 ${Fmt.pace(minP)} · 위로 갈수록 빨라요',
      trailing: _Badge(
        text: improving ? '▲ 좋아지는 중' : '꾸준함이 실력',
        highlight: improving,
      ),
      child: SizedBox(
        height: 150,
        child: LineChart(
          LineChartData(
            minY: -(maxP + 15),
            maxY: -(minP - 15),
            gridData: const FlGridData(show: false),
            borderData: FlBorderData(show: false),
            titlesData: FlTitlesData(
              topTitles: const AxisTitles(
                sideTitles: SideTitles(showTitles: false),
              ),
              rightTitles: const AxisTitles(
                sideTitles: SideTitles(showTitles: false),
              ),
              bottomTitles: const AxisTitles(
                sideTitles: SideTitles(showTitles: false),
              ),
              leftTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 44,
                  interval: ((maxP - minP) / 2).clamp(5, 600).toDouble(),
                  getTitlesWidget: (v, meta) => SideTitleWidget(
                    meta: meta,
                    child: Text(
                      Fmt.pace(-v),
                      style: const TextStyle(
                        fontSize: 10,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            lineTouchData: LineTouchData(
              touchTooltipData: LineTouchTooltipData(
                getTooltipItems: (spots) => spots
                    .map(
                      (s) => LineTooltipItem(
                        Fmt.pace(-s.y),
                        const TextStyle(fontWeight: FontWeight.w800),
                      ),
                    )
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
                belowBarData: BarAreaData(
                  show: true,
                  color: AppColors.neon.withValues(alpha: 0.08),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- 평균

  Widget _averageCard(List<RunRecord> runs) {
    final dist = runs.fold<double>(0, (s, r) => s + r.distanceM);
    final time = runs.fold<int>(0, (s, r) => s + r.durationMs);
    final first = DateTime.fromMillisecondsSinceEpoch(runs.last.startedAt);
    final spanDays =
        _period.days ?? DateTime.now().difference(first).inDays + 1;
    final weeks = (spanDays / 7).clamp(1.0, double.infinity);
    return _StatCard(
      icon: Icons.functions,
      title: '러닝당 평균',
      caption: '${_period.label} 기준',
      child: Row(
        children: [
          _Metric(
            value: Fmt.km(dist / runs.length, digits: 1),
            unit: ' km',
            label: '평균 거리',
          ),
          _Metric(
            value: Fmt.durationKo((time / runs.length).round()),
            label: '평균 시간',
          ),
          _Metric(
            value: (runs.length / weeks).toStringAsFixed(1),
            unit: '회',
            label: '주당 러닝',
          ),
          _Metric(
            value: Fmt.km(dist / weeks, digits: 1),
            unit: ' km',
            label: '주당 거리',
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 주간 / 월간 마일리지

  Widget _weeklyCard(List<RunRecord> all, DateTime now) {
    final thisWeek = _weekStart(now);
    final starts = [
      for (var i = 7; i >= 0; i--)
        DateTime(thisWeek.year, thisWeek.month, thisWeek.day - 7 * i),
    ];
    final totals = List<double>.filled(starts.length, 0);
    for (final r in all) {
      final ws = _weekStart(_day(r.startedAt));
      final idx = starts.indexWhere((s) => s == ws);
      if (idx >= 0) totals[idx] += r.distanceM;
    }
    final cur = totals.last, prev = totals[totals.length - 2];
    final diff = cur - prev;
    return _StatCard(
      icon: Icons.bar_chart_rounded,
      title: '주간 마일리지',
      caption:
          '이번 주 ${Fmt.km(cur, digits: 1)} km · 지난주 대비 ${diff >= 0 ? '+' : '-'}${Fmt.km(diff.abs(), digits: 1)} km',
      child: _Bars(
        items: [
          for (var i = 0; i < starts.length; i++)
            _BarItem(
              label: '${starts[i].month}/${starts[i].day}',
              value: totals[i],
              valueLabel: totals[i] > 0 ? Fmt.km(totals[i], digits: 1) : '',
              highlight: i == starts.length - 1,
            ),
        ],
      ),
    );
  }

  Widget _monthlyCard(List<RunRecord> all, DateTime now) {
    final months = [
      for (var i = 5; i >= 0; i--) DateTime(now.year, now.month - i),
    ];
    final totals = List<double>.filled(months.length, 0);
    for (final r in all) {
      final d = DateTime.fromMillisecondsSinceEpoch(r.startedAt);
      final idx = months.indexWhere(
        (m) => m.year == d.year && m.month == d.month,
      );
      if (idx >= 0) totals[idx] += r.distanceM;
    }
    final best = totals.reduce((a, b) => a > b ? a : b);
    return _StatCard(
      icon: Icons.calendar_view_month_rounded,
      title: '월간 마일리지',
      caption: '최근 6개월 · 최고 ${Fmt.km(best, digits: 1)} km',
      child: _Bars(
        items: [
          for (var i = 0; i < months.length; i++)
            _BarItem(
              label: '${months[i].month}월',
              value: totals[i],
              valueLabel: totals[i] > 0 ? Fmt.km(totals[i], digits: 1) : '',
              highlight: i == months.length - 1,
            ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 개인 최고 기록

  Widget _recordsCard(List<RunRecord> all) {
    RunRecord? longest, longestTime, fastest;
    for (final r in all) {
      if (longest == null || r.distanceM > longest.distanceM) longest = r;
      if (longestTime == null || r.durationMs > longestTime.durationMs)
        longestTime = r;
      if (r.distanceM >= 1000 && r.avgPaceSecPerKm != null) {
        if (fastest == null || r.avgPaceSecPerKm! < fastest.avgPaceSecPerKm!)
          fastest = r;
      }
    }
    ({RunRecord run, int ms})? bestAt(int km) {
      ({RunRecord run, int ms})? best;
      for (final r in all) {
        for (final s in r.splits) {
          if (s.km == km && (best == null || s.movingMs < best.ms))
            best = (run: r, ms: s.movingMs);
        }
      }
      return best;
    }

    final b1 = bestAt(1), b5 = bestAt(5), b10 = bestAt(10);
    return _StatCard(
      icon: Icons.emoji_events_rounded,
      title: '개인 최고 기록',
      caption: '전체 기록 기준 · 누르면 해당 러닝으로 이동',
      child: Column(
        children: [
          _RecordRow(
            label: '최장 거리',
            value: longest == null ? '-' : '${Fmt.km(longest.distanceM)} km',
            date: longest?.startedAt,
            onTap: longest == null ? null : () => widget.onOpenRun(longest!),
          ),
          _RecordRow(
            label: '최장 시간',
            value: longestTime == null
                ? '-'
                : Fmt.duration(longestTime.durationMs),
            date: longestTime?.startedAt,
            onTap: longestTime == null
                ? null
                : () => widget.onOpenRun(longestTime!),
          ),
          _RecordRow(
            label: '최고 평균 페이스 (1km 이상)',
            value: fastest == null
                ? '-'
                : "${Fmt.pace(fastest.avgPaceSecPerKm)} /km",
            date: fastest?.startedAt,
            onTap: fastest == null ? null : () => widget.onOpenRun(fastest!),
          ),
          _RecordRow(
            label: '1km 최고 기록',
            value: b1 == null ? '-' : Fmt.duration(b1.ms),
            date: b1?.run.startedAt,
            onTap: b1 == null ? null : () => widget.onOpenRun(b1.run),
          ),
          _RecordRow(
            label: '5km 최고 기록',
            value: b5 == null ? '-' : Fmt.duration(b5.ms),
            date: b5?.run.startedAt,
            onTap: b5 == null ? null : () => widget.onOpenRun(b5.run),
          ),
          _RecordRow(
            label: '10km 최고 기록',
            value: b10 == null ? '-' : Fmt.duration(b10.ms),
            date: b10?.run.startedAt,
            onTap: b10 == null ? null : () => widget.onOpenRun(b10.run),
            last: true,
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 연속 러닝

  Widget _streakCard(List<RunRecord> all, DateTime now) {
    DateTime utc(DateTime d) => DateTime.utc(d.year, d.month, d.day);
    final daySet = all.map((r) => utc(_day(r.startedAt))).toSet();
    final sorted = daySet.toList()..sort();
    var longest = 0, run = 0;
    DateTime? prev;
    for (final d in sorted) {
      run = (prev != null && d.difference(prev).inDays == 1) ? run + 1 : 1;
      if (run > longest) longest = run;
      prev = d;
    }
    // 현재 연속: 오늘 기록이 없으면 어제부터 이어진 것으로 인정
    var cursor = utc(now);
    if (!daySet.contains(cursor))
      cursor = cursor.subtract(const Duration(days: 1));
    var current = 0;
    while (daySet.contains(cursor)) {
      current++;
      cursor = cursor.subtract(const Duration(days: 1));
    }
    final monthDays = daySet
        .where((d) => d.year == now.year && d.month == now.month)
        .length;
    final weekStart = utc(_weekStart(now));
    final weekDays = daySet.where((d) => !d.isBefore(weekStart)).length;
    return _StatCard(
      icon: Icons.local_fire_department_rounded,
      title: '꾸준함',
      caption: current > 0 ? '$current일 연속 러닝 중이에요 🔥' : '오늘 달리면 연속 기록이 시작돼요',
      child: Row(
        children: [
          _Metric(value: '$current', unit: '일', label: '현재 연속'),
          _Metric(value: '$longest', unit: '일', label: '최장 연속'),
          _Metric(value: '$weekDays', unit: '일', label: '이번 주'),
          _Metric(value: '$monthDays', unit: '일', label: '이번 달'),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 분포

  Widget _weekdayCard(List<RunRecord> runs) {
    final dists = List<double>.filled(7, 0);
    for (final r in runs) {
      dists[DateTime.fromMillisecondsSinceEpoch(r.startedAt).weekday - 1] += r.distanceM;
    }
    final max = dists.reduce((a, b) => a > b ? a : b);
    const names = ['월', '화', '수', '목', '금', '토', '일'];
    return _StatCard(
      icon: Icons.event_repeat,
      title: '요일별 러닝',
      caption: max > 0 ? '${names[dists.indexOf(max)]}요일에 가장 많이 달려요' : null,
      child: _Bars(
        items: [
          for (var i = 0; i < 7; i++)
            _BarItem(
              label: names[i],
              value: dists[i],
              valueLabel: dists[i] > 0 ? Fmt.km(dists[i], digits: 1) : '',
              highlight: dists[i] == max && max > 0,
            ),
        ],
      ),
    );
  }

  Widget _timeOfDayCard(List<RunRecord> runs) {
    // 새벽 0-5 / 아침 5-11 / 낮 11-17 / 저녁 17-21 / 밤 21-24
    final counts = <String, int>{
      '🌅 새벽 (0~5시)': 0,
      '☀️ 아침 (5~11시)': 0,
      '🌤️ 낮 (11~17시)': 0,
      '🌇 저녁 (17~21시)': 0,
      '🌙 밤 (21~24시)': 0,
    };
    final keys = counts.keys.toList();
    for (final r in runs) {
      final h = DateTime.fromMillisecondsSinceEpoch(r.startedAt).hour;
      final k = h < 5
          ? 0
          : h < 11
          ? 1
          : h < 17
          ? 2
          : h < 21
          ? 3
          : 4;
      counts[keys[k]] = counts[keys[k]]! + 1;
    }
    return _StatCard(
      icon: Icons.schedule,
      title: '시간대별 러닝',
      caption: '언제 가장 많이 달리는지 확인해보세요',
      child: _HBars(items: [for (final k in keys) (k, counts[k]!)]),
    );
  }

  Widget _distanceBucketCard(List<RunRecord> runs) {
    final labels = ['3km 미만', '3 ~ 5km', '5 ~ 10km', '10km 이상'];
    final counts = List<int>.filled(4, 0);
    for (final r in runs) {
      final km = r.distanceM / 1000;
      counts[km < 3
          ? 0
          : km < 5
          ? 1
          : km < 10
          ? 2
          : 3]++;
    }
    return _StatCard(
      icon: Icons.straighten,
      title: '거리 구간 분포',
      caption: '러닝 1회당 거리',
      child: _HBars(
        items: [for (var i = 0; i < 4; i++) (labels[i], counts[i])],
      ),
    );
  }

  Widget _elevationCard(List<RunRecord> runs) {
    final gain = runs.fold<double>(0, (s, r) => s + (r.elevationGainM ?? 0));
    final withGain = runs.where((r) => r.elevationGainM != null).length;
    final maxSpeed = runs.fold<double>(
      0,
      (s, r) => (r.maxSpeedMps ?? 0) > s ? r.maxSpeedMps! : s,
    );
    return _StatCard(
      icon: Icons.terrain_rounded,
      title: '고도 · 속도',
      caption: '${_period.label} 기준 · GPS 러닝만 집계',
      child: Row(
        children: [
          _Metric(value: '${gain.round()}', unit: ' m', label: '누적 상승고도'),
          _Metric(
            value: withGain == 0 ? '-' : '${(gain / withGain).round()}',
            unit: ' m',
            label: '러닝당 평균',
          ),
          _Metric(
            value: maxSpeed == 0
                ? '-'
                : (maxSpeed * 3.6).toStringAsFixed(1),
            unit: ' km/h',
            label: '최고 속도',
          ),
        ],
      ),
    );
  }

  Widget _modeCard(List<RunRecord> runs) {
    final solo = runs.where((r) => r.mode == RunMode.solo).length;
    final group = runs.where((r) => r.mode == RunMode.group).length;
    final tread = runs.where((r) => r.mode == RunMode.treadmill).length;
    return _StatCard(
      icon: Icons.groups_rounded,
      title: '러닝 유형',
      caption: '혼자 · 같이 · 러닝머신',
      child: _HBars(
        items: [('🏃 혼자 뛰기', solo), ('👥 같이 뛰기', group), ('🏋️ 러닝머신', tread)],
      ),
    );
  }

  Widget _regionCard(List<RunRecord> runs) {
    final stats = <String, ({int count, double distanceM, int durationMs})>{};
    for (final r in runs) {
      final reg = (r.region != null && r.region!.isNotEmpty)
          ? r.region!
          : (r.mode == RunMode.treadmill ? '실내 러닝머신' : '위치 확인 중');
      final cur = stats[reg] ?? (count: 0, distanceM: 0.0, durationMs: 0);
      stats[reg] = (
        count: cur.count + 1,
        distanceM: cur.distanceM + r.distanceM,
        durationMs: cur.durationMs + r.durationMs,
      );
    }

    if (stats.isEmpty) return const SizedBox.shrink();

    final sorted = stats.entries.toList()
      ..sort((a, b) => b.value.count.compareTo(a.value.count));

    final totalRuns = runs.length;
    final maxCount = sorted.first.value.count;

    return _StatCard(
      icon: Icons.location_on_rounded,
      title: '활동 지역',
      caption: '${_period.label} 기준 · 총 ${stats.length}개 지역',
      child: Column(
        children: [
          for (var i = 0; i < sorted.length; i++) ...[
            if (i > 0) const SizedBox(height: 12),
            _RegionStatRow(
              rank: i + 1,
              region: sorted[i].key,
              count: sorted[i].value.count,
              distanceM: sorted[i].value.distanceM,
              durationMs: sorted[i].value.durationMs,
              ratio: maxCount > 0 ? sorted[i].value.count / maxCount : 0.0,
              percent: totalRuns > 0 ? (sorted[i].value.count / totalRuns * 100).round() : 0,
            ),
          ],
        ],
      ),
    );
  }
}

// ====================================================================== 공용 위젯

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.icon,
    required this.title,
    this.caption,
    this.trailing,
    required this.child,
  });
  final IconData icon;
  final String title;
  final String? caption;
  final Widget? trailing;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: AppColors.neon),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
                  ),
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          if (caption != null) ...[
            const SizedBox(height: 4),
            Text(
              caption!,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ],
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text, required this.highlight});
  final String text;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final color = highlight ? AppColors.neon : AppColors.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.value, this.unit, required this.label});
  final String value;
  final String? unit;
  final String label;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Column(
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  value,
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 20,
                    color: AppColors.neon,
                  ),
                ),
              ),
            ),
            if (unit != null)
              Text(
                unit!,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                  color: AppColors.textSecondary,
                ),
              ),
          ],
        ),
        const SizedBox(height: 3),
        Text(
          label,
          style: const TextStyle(color: AppColors.textSecondary, fontSize: 11),
          textAlign: TextAlign.center,
        ),
      ],
    ),
  );
}

class _RecordRow extends StatelessWidget {
  const _RecordRow({
    required this.label,
    required this.value,
    this.date,
    this.onTap,
    this.last = false,
  });
  final String label;
  final String value;
  final int? date;
  final VoidCallback? onTap;
  final bool last;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 2),
        decoration: BoxDecoration(
          border: last
              ? null
              : const Border(
                  bottom: BorderSide(color: AppColors.outline, width: 0.6),
                ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                  if (date != null)
                    Text(
                      Fmt.date(date!),
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 11,
                      ),
                    ),
                ],
              ),
            ),
            Text(
              value,
              style: const TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 17,
                color: AppColors.neon,
              ),
            ),
            if (onTap != null)
              const Icon(
                Icons.chevron_right,
                size: 18,
                color: AppColors.textSecondary,
              ),
          ],
        ),
      ),
    );
  }
}

class _BarItem {
  const _BarItem({
    required this.label,
    required this.value,
    required this.valueLabel,
    this.highlight = false,
  });
  final String label;
  final double value;
  final String valueLabel;
  final bool highlight;
}

/// 단순 세로 막대 차트 (값 라벨 포함)
class _Bars extends StatelessWidget {
  const _Bars({required this.items, this.height = 150});
  final List<_BarItem> items;
  final double height;

  @override
  Widget build(BuildContext context) {
    final maxV = items.fold<double>(0, (m, e) => e.value > m ? e.value : m);
    final barArea = height - 40;
    return SizedBox(
      height: height,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final it in items)
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  SizedBox(
                    height: 14,
                    child: FittedBox(
                      child: Text(
                        it.valueLabel,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          color: it.highlight
                              ? AppColors.neon
                              : AppColors.textSecondary,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 3),
                  TweenAnimationBuilder<double>(
                    tween: Tween(
                      begin: 0,
                      end: maxV <= 0 ? 0 : it.value / maxV,
                    ),
                    duration: const Duration(milliseconds: 500),
                    curve: Curves.easeOutCubic,
                    builder: (_, t, _) => Container(
                      width: 18,
                      height: it.value <= 0 ? 3 : (3 + (barArea - 3) * t),
                      decoration: BoxDecoration(
                        color: it.value <= 0
                            ? AppColors.outline
                            : (it.highlight
                                  ? AppColors.neon
                                  : AppColors.neon.withValues(alpha: 0.4)),
                        borderRadius: BorderRadius.circular(5),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    it.label,
                    style: const TextStyle(
                      fontSize: 10,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 가로 막대 분포 (라벨 / 막대 / 횟수·비율)
class _HBars extends StatelessWidget {
  const _HBars({required this.items});
  final List<(String, int)> items;

  @override
  Widget build(BuildContext context) {
    final total = items.fold<int>(0, (s, e) => s + e.$2);
    final maxV = items.fold<int>(0, (m, e) => e.$2 > m ? e.$2 : m);
    return Column(
      children: [
        for (final (label, count) in items)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              children: [
                SizedBox(
                  width: 118,
                  child: Text(
                    label,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0, end: maxV == 0 ? 0 : count / maxV),
                      duration: const Duration(milliseconds: 500),
                      curve: Curves.easeOutCubic,
                      builder: (_, t, _) => LinearProgressIndicator(
                        value: t,
                        minHeight: 12,
                        color: count == maxV && count > 0
                            ? AppColors.neon
                            : AppColors.neon.withValues(alpha: 0.4),
                        backgroundColor: AppColors.surfaceHigh,
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  width: 62,
                  child: Text(
                    total == 0
                        ? '-'
                        : '$count회 ${(count * 100 / total).round()}%',
                    textAlign: TextAlign.end,
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _RegionStatRow extends StatelessWidget {
  const _RegionStatRow({
    required this.rank,
    required this.region,
    required this.count,
    required this.distanceM,
    required this.durationMs,
    required this.ratio,
    required this.percent,
  });

  final int rank;
  final String region;
  final int count;
  final double distanceM;
  final int durationMs;
  final double ratio;
  final int percent;

  Color get _rankColor => switch (rank) {
    1 => AppColors.neon,
    2 => AppColors.silver,
    3 => AppColors.bronze,
    _ => AppColors.textSecondary,
  };

  @override
  Widget build(BuildContext context) {
    final pace = distanceM > 0 ? (durationMs / 1000) / (distanceM / 1000) : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 22,
              height: 22,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: _rankColor.withValues(alpha: 0.18),
                shape: BoxShape.circle,
                border: Border.all(color: _rankColor, width: 1.2),
              ),
              child: Text(
                '$rank',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                  color: _rankColor,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                region,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                  color: AppColors.textPrimary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '$count회 ($percent%)',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: AppColors.neon,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: ratio),
            duration: const Duration(milliseconds: 500),
            curve: Curves.easeOutCubic,
            builder: (_, t, _) => LinearProgressIndicator(
              value: t,
              minHeight: 6,
              color: rank == 1 ? AppColors.neon : AppColors.neon.withValues(alpha: 0.45),
              backgroundColor: AppColors.surfaceHigh,
            ),
          ),
        ),
        const SizedBox(height: 5),
        Row(
          children: [
            Text(
              '누적 ${Fmt.km(distanceM, digits: 1)} km',
              style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
            ),
            const Spacer(),
            if (pace != null)
              Text(
                '평균 페이스 ${Fmt.pace(pace)} /km',
                style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
              ),
          ],
        ),
      ],
    );
  }
}
