import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:table_calendar/table_calendar.dart';

import '../../config/app_config.dart';
import '../../core/format.dart';
import '../../data/local/local_db.dart';
import '../../data/models/gps_point.dart';
import '../../data/models/run_record.dart';
import '../../services/sync_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/run_thumb.dart';
import 'gallery_feed_view.dart';
import 'run_detail_screen.dart';
import 'stats_view.dart';

/// 홈 = 지난 러닝 기록 (월별 달력 / 리스트). 목표는 "꾸준함" 유도.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen>
    with SingleTickerProviderStateMixin {
  final uid = AppConfig.useFirebase
      ? FirebaseAuth.instance.currentUser!.uid
      : 'dummy_uid';
  List<RunRecord> _runs = [];
  Map<String, RunPhoto> _photos = {};
  bool _loading = true;
  late final TabController _tabController;
  bool _isGridView = true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    LocalDb.instance.changes.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    _tabController.dispose();
    LocalDb.instance.changes.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final runs = await LocalDb.instance.getFinishedRuns(uid);
    final photos = await LocalDb.instance.getFirstPhotos(
      runs.map((r) => r.id).toList(),
    );
    if (!mounted) return;
    setState(() {
      _runs = runs;
      _photos = photos;
      _loading = false;
    });
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('홈 · 러닝 기록'),
        actions: [
          ValueListenableBuilder<bool>(
            valueListenable: SyncService.instance.syncing,
            builder: (context, syncing, _) {
              final pendingCount =
                  _runs.where((r) => r.syncStatus != SyncStatus.synced).length;
              return IconButton(
                icon: syncing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppColors.neon,
                        ),
                      )
                    : Badge(
                        isLabelVisible: pendingCount > 0,
                        label: Text('$pendingCount'),
                        backgroundColor: Colors.orange,
                        child: const Icon(Icons.sync),
                      ),
                tooltip: '클라우드 동기화',
                onPressed: syncing
                    ? null
                    : () async {
                        final res =
                            await SyncService.instance.syncAllManual();
                        if (!context.mounted) return;
                        switch (res) {
                          case SyncResult.success:
                            _toast(
                              '클라우드 동기화가 완료되었습니다! ☁️',
                              icon: Icons.cloud_done_rounded,
                              accentColor: AppColors.neon,
                            );
                          case SyncResult.noPending:
                            _toast(
                              '모든 러닝 기록이 이미 동기화되어 있어요.',
                              icon: Icons.check_circle_outline_rounded,
                              accentColor: AppColors.neon,
                            );
                          case SyncResult.notLoggedIn:
                            _toast(
                              '클라우드 동기화를 위해 로그인이 필요해요.',
                              icon: Icons.lock_outline_rounded,
                              accentColor: Colors.orange,
                            );
                          case SyncResult.failed:
                            _toast(
                              '네트워크 연결을 확인해주세요. (오프라인 상태에서는 스마트폰에 안전하게 보관돼요)',
                              icon: Icons.wifi_off_rounded,
                              accentColor: Colors.orange,
                            );
                        }
                      },
              );
            },
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: AppColors.neon,
          labelColor: AppColors.neon,
          unselectedLabelColor: AppColors.textSecondary,
          onTap: (index) {
            // 이미 갤러리/피드 탭(인덱스 1)에 위치해 있을 때 다시 누르면 그리드 <-> 피드 모션 스위칭
            if (index == 1 && _tabController.index == 1) {
              setState(() => _isGridView = !_isGridView);
            }
          },
          tabs: [
            const Tab(icon: Icon(Icons.calendar_month)),
            Tab(
              icon: AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                transitionBuilder: (child, anim) => RotationTransition(
                  turns: child.key == const ValueKey('grid_tab')
                      ? Tween<double>(begin: 0.75, end: 1.0).animate(anim)
                      : Tween<double>(begin: 0.25, end: 1.0).animate(anim),
                  child: FadeTransition(opacity: anim, child: child),
                ),
                child: _isGridView
                    ? const Icon(
                        Icons.grid_view_rounded,
                        key: ValueKey('grid_tab'),
                      )
                    : const Icon(
                        Icons.view_agenda_rounded,
                        key: ValueKey('feed_tab'),
                      ),
              ),
            ),
            const Tab(icon: Icon(Icons.insights)),
          ],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabController,
              children: [
                _MonthView(runs: _runs, photos: _photos),
                GalleryFeedView(
                  runs: _runs,
                  photos: _photos,
                  onOpenRun: (r) => openRunDetail(context, r),
                  isGridView: _isGridView,
                ),
                StatsView(
                  runs: _runs,
                  onOpenRun: (r) => openRunDetail(context, r),
                ),
              ],
            ),
    );
  }
}

void openRunDetail(BuildContext context, RunRecord run) => Navigator.of(
  context,
).push(MaterialPageRoute(builder: (_) => RunDetailScreen(runId: run.id)));

// ====================================================================== 월별 뷰

class _MonthView extends StatefulWidget {
  const _MonthView({required this.runs, required this.photos});
  final List<RunRecord> runs;
  final Map<String, RunPhoto> photos;

  @override
  State<_MonthView> createState() => _MonthViewState();
}

class _MonthViewState extends State<_MonthView>
    with AutomaticKeepAliveClientMixin {
  DateTime _focused = DateTime.now();
  DateTime? _selected = DateTime.now();
  CalendarFormat _calendarFormat = CalendarFormat.month;
  double _calendarDragDistance = 0;

  void _setFormat(CalendarFormat format) {
    if (_calendarFormat == format) return;
    setState(() {
      _calendarFormat = format;
      if (format == CalendarFormat.week && _selected != null) {
        _focused = _selected!;
      }
    });
  }

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

  List<RunRecord> _runsOn(DateTime day) =>
      _byDay[DateTime(day.year, day.month, day.day)] ?? [];

  Widget _dayCell(DateTime day, {bool selected = false, bool today = false}) {
    final runs = _runsOn(day);
    final number = Text(
      '${day.day}',
      style: TextStyle(
        fontWeight: FontWeight.w800,
        fontSize: 12,
        color: runs.isNotEmpty
            ? Colors.white
            : (today ? AppColors.neon : AppColors.textPrimary),
        shadows: runs.isNotEmpty
            ? const [Shadow(blurRadius: 4, color: Colors.black)]
            : null,
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
                      decoration: BoxDecoration(
                        color: AppColors.neon,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '${runs.length}',
                        style: const TextStyle(
                          color: Colors.black,
                          fontSize: 10,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
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
    final monthDays = monthRuns
        .map((r) => DateTime.fromMillisecondsSinceEpoch(r.startedAt).day)
        .toSet()
        .length;
    final monthTime = monthRuns.fold<int>(0, (s, r) => s + r.durationMs);
    final selectedRuns = _selected == null
        ? <RunRecord>[]
        : _runsOn(_selected!);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(vertical: 14),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  children: [
                    _MiniStat(value: '${Fmt.km(monthDist, digits: 1)} km', label: '${_focused.month}월 마일리지'),
                    _MiniStat(value: '${monthRuns.length}', label: '러닝'),
                    _MiniStat(value: '$monthDays', label: '달린 날'),
                    _MiniStat(value: Fmt.minutes(monthTime), label: '총 시간'),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              GestureDetector(
                onVerticalDragStart: (_) => _calendarDragDistance = 0,
                onVerticalDragUpdate: (details) =>
                    _calendarDragDistance += details.delta.dy,
                onVerticalDragEnd: (details) {
                  final velocity = details.primaryVelocity ?? 0;
                  if ((velocity < -200 || _calendarDragDistance < -55) &&
                      _calendarFormat == CalendarFormat.month) {
                    _setFormat(CalendarFormat.week);
                  } else if ((velocity > 200 || _calendarDragDistance > 55) &&
                      _calendarFormat == CalendarFormat.week) {
                    _setFormat(CalendarFormat.month);
                  }
                  _calendarDragDistance = 0;
                },
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.bg,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    children: [
                      TableCalendar<RunRecord>(
                        locale: 'ko_KR',
                        firstDay: DateTime(2020),
                        lastDay: DateTime.now().add(const Duration(days: 365)),
                        focusedDay: _calendarFormat == CalendarFormat.week
                            ? _focused
                            : ((_selected != null &&
                                    _selected!.year == _focused.year &&
                                    _selected!.month == _focused.month)
                                ? _selected!
                                : _focused),
                        calendarFormat: _calendarFormat,
                        onFormatChanged: (format) => _setFormat(format),
                        selectedDayPredicate: (d) =>
                            _selected != null && isSameDay(d, _selected),
                        eventLoader: _runsOn,
                        rowHeight: 52,
                        daysOfWeekHeight: 22,
                        startingDayOfWeek: StartingDayOfWeek.sunday,
                        availableCalendarFormats: const {
                          CalendarFormat.month: '월',
                          CalendarFormat.week: '주',
                        },
                        headerStyle: const HeaderStyle(
                          titleCentered: true,
                          formatButtonVisible: false,
                          titleTextStyle: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        onDaySelected: (sel, foc) => setState(() {
                          _selected = sel;
                          _focused = sel;
                        }),
                        onPageChanged: (foc) => setState(() => _focused = foc),
                        calendarBuilders: CalendarBuilders(
                          defaultBuilder: (_, day, _) => _dayCell(day),
                          todayBuilder: (_, day, _) => _dayCell(day, today: true),
                          selectedBuilder: (_, day, _) => _dayCell(
                            day,
                            selected: true,
                            today: isSameDay(day, DateTime.now()),
                          ),
                          outsideBuilder: (_, day, _) => Center(
                            child: Text(
                              '${day.day}',
                              style: const TextStyle(color: AppColors.outline, fontSize: 12),
                            ),
                          ),
                          markerBuilder: (_, _, _) => const SizedBox.shrink(),
                        ),
                      ),
                      // 하단 핸들 인디케이터 (탭하거나 드래그하여 월<->주 전환)
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          _setFormat(
                            _calendarFormat == CalendarFormat.month
                                ? CalendarFormat.week
                                : CalendarFormat.month,
                          );
                        },
                        onVerticalDragEnd: (details) {
                          final velocity = details.primaryVelocity ?? 0;
                          if (velocity < -120 && _calendarFormat == CalendarFormat.month) {
                            _setFormat(CalendarFormat.week);
                          } else if (velocity > 120 && _calendarFormat == CalendarFormat.week) {
                            _setFormat(CalendarFormat.month);
                          }
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Center(
                            child: Container(
                              width: 40,
                              height: 5,
                              decoration: BoxDecoration(
                                color: AppColors.outline.withValues(alpha: 0.8),
                                borderRadius: BorderRadius.circular(2.5),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        // 하단 선택된 날짜의 러닝 리스트 (스크롤 시 캘린더가 접히거나 확장되도록 NotificationListener 적용)
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification is ScrollUpdateNotification) {
                final delta = notification.scrollDelta ?? 0;
                // 리스트를 아래로 스크롤(손가락을 위로 쓸어올림) 시 delta > 25일 때만 주 단위로 축소
                if (delta > 25 && _calendarFormat == CalendarFormat.month) {
                  _setFormat(CalendarFormat.week);
                } else if (delta < -20 &&
                    _calendarFormat == CalendarFormat.week &&
                    notification.metrics.pixels <= 10) {
                  // 최상단에서 손가락을 아래로 확실히 내릴 때 월 단위로 복귀
                  _setFormat(CalendarFormat.month);
                }
              } else if (notification is OverscrollNotification) {
                // 리스트 최상단에서 아래로 15px 이상 확실히 당길 때 월 단위로 확장
                if (notification.overscroll < -15 &&
                    _calendarFormat == CalendarFormat.week) {
                  _setFormat(CalendarFormat.month);
                }
              }
              return false;
            },
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(
                parent: BouncingScrollPhysics(),
              ),
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
              children: [
                if (_selected != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                    child: Text(
                      Fmt.date(_selected!.millisecondsSinceEpoch),
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        color: AppColors.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                  ),
                if (selectedRuns.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 36),
                    child: Text(
                      '이 날은 기록이 없어요. 오늘 한 번 달려볼까요? 🏃',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.textSecondary),
                    ),
                  ),
                ...selectedRuns.map(
                  (r) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: RunListTile(
                      run: r,
                      photo: widget.photos[r.id],
                      onTap: () => openRunDetail(context, r),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
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
          child: Text(
            value,
            style: const TextStyle(
              fontWeight: FontWeight.w900,
              fontSize: 18,
              color: AppColors.neon,
            ),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: const TextStyle(color: AppColors.textSecondary, fontSize: 11),
        ),
      ],
    ),
  );
}


/// 러닝 기록 한 줄 요약 (평균 페이스 / km / 시간)
class RunListTile extends StatelessWidget {
  const RunListTile({
    super.key,
    required this.run,
    this.photo,
    this.previous,
    required this.onTap,
  });
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
              SizedBox(
                width: 64,
                height: 64,
                child: RunThumb(run: run, photo: photo),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            Fmt.dateTime(run.startedAt),
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        if (run.isGroup) ...[
                          const SizedBox(width: 6),
                          const Icon(
                            Icons.groups,
                            size: 14,
                            color: AppColors.neon,
                          ),
                        ],
                        if (run.syncStatus != SyncStatus.synced) ...[
                          const SizedBox(width: 6),
                          const Icon(
                            Icons.cloud_off,
                            size: 13,
                            color: AppColors.textSecondary,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${Fmt.km(run.distanceM)} km',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${Fmt.pace(run.avgPaceSecPerKm)} /km  ·  ${Fmt.duration(run.durationMs)}',
                      style: const TextStyle(color: AppColors.textSecondary),
                    ),
                  ],
                ),
              ),
              if (delta != null && delta.abs() >= 1)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Icon(
                      delta < 0 ? Icons.trending_up : Icons.trending_down,
                      color: delta < 0 ? AppColors.neon : AppColors.danger,
                      size: 18,
                    ),
                    Text(
                      '${delta < 0 ? '-' : '+'}${Fmt.pace(delta.abs()).replaceFirst("0'", '')}',
                      style: TextStyle(
                        fontSize: 11,
                        color: delta < 0 ? AppColors.neon : AppColors.danger,
                      ),
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
