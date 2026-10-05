import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../config/app_config.dart';
import '../core/format.dart';
import '../data/local/local_db.dart';
import '../data/models/party.dart';
import '../data/models/run_record.dart';
import '../services/auth_service.dart';
import '../services/deep_link_service.dart';
import '../services/party_service.dart';
import '../services/push_service.dart';
import '../services/run_tracker.dart';
import '../services/server_clock.dart';
import '../services/sync_service.dart';
import '../theme/app_theme.dart';
import 'history/history_screen.dart';
import 'party/party_sheets.dart';
import 'run/run_finish_screen.dart';
import 'run/run_screen.dart';
import 'run/start_options_sheet.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  late final String uid = AppConfig.useFirebase ? FirebaseAuth.instance.currentUser!.uid : 'dummy_uid';
  StreamSubscription<List<Party>>? _partySub;
  StreamSubscription<FinishReason>? _finishSub;
  List<Party> _parties = [];
  final Set<String> _autoLaunched = {};
  bool _runOpen = false;

  @override
  void initState() {
    super.initState();
    _partySub = PartyService.instance.myActiveParties(uid).listen(
      (list) {
        setState(() => _parties = list);
        _checkAutoStart(list);
      },
      onError: (Object e) => debugPrint('parties stream error: $e'),
    );
    DeepLinkService.instance.pendingInvite.addListener(_onInvite);
    PushService.instance.opened.addListener(_onPushOpened);
    // 러닝 화면을 내려둔 상태에서 목표 달성 등으로 종료되면 종료 화면으로
    _finishSub = RunTracker.instance.onFinished.listen((_) {
      final run = RunTracker.instance.run;
      if (_runOpen || run == null || !mounted) return;
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => RunFinishScreen(runId: run.id)));
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkUnfinishedRun();
      _onInvite();
      _requestPermissions();
    });
  }

  Future<void> _requestPermissions() async {
    try {
      await RunTracker.ensurePermission();
    } catch (_) {}
  }

  @override
  void dispose() {
    _partySub?.cancel();
    _finishSub?.cancel();
    DeepLinkService.instance.pendingInvite.removeListener(_onInvite);
    PushService.instance.opened.removeListener(_onPushOpened);
    super.dispose();
  }

  // ------------------------------------------------------------ 자동 처리

  /// 비정상 종료로 남아있는 러닝 → 이어하기 / 저장하고 끝내기
  Future<void> _checkUnfinishedRun() async {
    if (RunTracker.instance.isActive) return;
    final run = await LocalDb.instance.getUnfinishedRun(uid);
    if (run == null || !mounted) return;
    final resume = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('진행 중이던 러닝이 있어요'),
        content: Text('${Fmt.dateTime(run.startedAt)}\n${Fmt.km(run.distanceM)} km · ${Fmt.duration(run.durationMs)}\n\n'
            '기록은 기기에 안전하게 저장되어 있어요.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('저장하고 끝내기')),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(100, 44)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('이어서 달리기'),
          ),
        ],
      ),
    );
    await RunTracker.instance.restore(run);
    if (!mounted) return;
    if (resume == true) {
      _openRun(RunScreen.resume());
    } else {
      final r = await RunTracker.instance.finish(FinishReason.manual);
      if (r != null && mounted) {
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => RunFinishScreen(runId: r.id)));
      }
    }
  }

  /// 방장이 시작하면 파티원 앱이 자동으로 카운트다운 화면으로 이동
  Future<void> _checkAutoStart(List<Party> parties) async {
    if (RunTracker.instance.isActive || _runOpen) return;
    for (final p in parties) {
      if (p.status != PartyStatus.running || p.startAt == null) continue;
      if (_autoLaunched.contains(p.key)) continue;
      final sinceStart = ServerClock.nowMs() - p.startAt!;
      if (sinceStart > const Duration(minutes: 2).inMilliseconds) continue;
      final existing = await LocalDb.instance.getRunsForParty(uid, p.key);
      if (existing.isNotEmpty) continue;
      _autoLaunched.add(p.key);
      if (!mounted) return;
      await launchGroupRun(p);
      return;
    }
  }

  void _onInvite() {
    final invite = DeepLinkService.instance.pendingInvite.value;
    if (invite == null || !mounted) return;
    DeepLinkService.instance.pendingInvite.value = null;
    showJoinPartySheet(context, initialId: invite.id, initialPw: invite.pw);
  }

  Future<void> _onPushOpened() async {
    final m = PushService.instance.opened.value;
    if (m == null || !mounted) return;
    PushService.instance.opened.value = null;
    final key = m.data['partyKey'] as String?;
    if (key == null) return;
    final party = await PartyService.instance.get(key).catchError((_) => null);
    if (party == null || !mounted) return;
    if (party.isActive) {
      showPartyDetailSheet(context, party.key, onRun: launchGroupRun);
    }
  }

  // ------------------------------------------------------------ 러닝 시작

  Future<void> _openRun(Widget screen) async {
    _runOpen = true;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen, fullscreenDialog: true));
    _runOpen = false;
  }

  Future<void> _startSolo() async {
    if (RunTracker.instance.isActive) {
      _openRun(RunScreen.resume());
      return;
    }
    try {
      await RunTracker.ensurePermission();
    } on LocationException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      return;
    }
    if (!mounted) return;
    final cfg = await showStartOptionsSheet(context);
    if (cfg == null || !mounted) return;
    _openRun(RunScreen(config: cfg));
  }

  Future<void> _onTogetherTap() async {
    try {
      await RunTracker.ensurePermission();
    } on LocationException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      return;
    }
    if (!mounted) return;
    showTogetherSheet(context);
  }

  /// 단체 러닝 화면 열기 (카운트다운 포함)
  Future<void> launchGroupRun(Party party) async {
    if (RunTracker.instance.isActive) {
      _openRun(RunScreen.resume());
      return;
    }
    try {
      await RunTracker.ensurePermission();
    } on LocationException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      return;
    }
    var base = 0.0;
    if (party.loyalty) {
      final prev = await LocalDb.instance.getRunsForParty(uid, party.key);
      base = prev.where((r) => r.status == RunStatus.finished).fold(0.0, (s, r) => s + r.distanceM);
    }
    if (!mounted) return;
    final startAt = party.startAt;
    final countdownTo = (startAt != null && ServerClock.nowMs() < startAt + 1500) ? startAt : null;
    _openRun(RunScreen(
      config: RunConfig.fromParty(party, uid, baseDistanceM: base),
      countdownTo: countdownTo,
      countdownAlways: true,
    ));
  }

  // ------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    final user = AppConfig.useFirebase ? FirebaseAuth.instance.currentUser : null;
    return Scaffold(
      appBar: AppBar(
        title: const Text(AppConfig.appName, style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: -0.5)),
        actions: [
          ValueListenableBuilder<bool>(
            valueListenable: SyncService.instance.syncing,
            builder: (_, syncing, _) => syncing
                ? const Padding(
                    padding: EdgeInsets.all(16),
                    child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                : const SizedBox.shrink(),
          ),
          PopupMenuButton<String>(
            icon: CircleAvatar(
              radius: 16,
              backgroundColor: AppColors.surfaceHigh,
              backgroundImage: user?.photoURL != null ? NetworkImage(user!.photoURL!) : null,
              child: user?.photoURL == null ? const Icon(Icons.person, size: 18) : null,
            ),
            onSelected: (v) async {
              if (v == 'logout') {
                if (RunTracker.instance.isActive) {
                  ScaffoldMessenger.of(context)
                      .showSnackBar(const SnackBar(content: Text('러닝 중에는 로그아웃할 수 없어요')));
                  return;
                }
                await PushService.instance.removeToken();
                await AuthService.instance.signOut();
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(enabled: false, child: Text(AuthService.instance.displayName)),
              const PopupMenuItem(value: 'logout', child: Text('로그아웃')),
            ],
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            const _MonthSummary(),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (_parties.isNotEmpty) ...[
                    _PartyStrip(parties: _parties, uid: uid, onRun: launchGroupRun),
                    const SizedBox(height: 36),
                  ],
                  ListenableBuilder(
                    listenable: RunTracker.instance,
                    builder: (_, _) => Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        _CircleAction(
                          size: 150,
                          filled: true,
                          icon: RunTracker.instance.isActive ? Icons.play_arrow_rounded : Icons.directions_run_rounded,
                          label: RunTracker.instance.isActive ? '러닝 중' : '러닝 시작',
                          onTap: _startSolo,
                        ),
                        const SizedBox(width: 24),
                        _CircleAction(
                          size: 96,
                          filled: false,
                          icon: Icons.groups_rounded,
                          label: '같이 뛰기',
                          onTap: _onTogetherTap,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            _BottomBar(
              onHome: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const HistoryScreen())),
            ),
          ],
        ),
      ),
    );
  }
}

class _CircleAction extends StatelessWidget {
  const _CircleAction({
    required this.size,
    required this.filled,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final double size;
  final bool filled;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: filled ? AppColors.neon : AppColors.surface,
          shape: CircleBorder(side: filled ? BorderSide.none : const BorderSide(color: AppColors.neon, width: 2)),
          elevation: 0,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Container(
              width: size,
              height: size,
              decoration: filled
                  ? BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: [BoxShadow(color: AppColors.neon.withValues(alpha: 0.45), blurRadius: 36, spreadRadius: 2)],
                    )
                  : null,
              child: Icon(icon, size: size * 0.48, color: filled ? Colors.black : AppColors.neon),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(label, style: TextStyle(fontWeight: FontWeight.w800, fontSize: filled ? 17 : 15)),
      ],
    );
  }
}

/// "러닝 시작" 버튼 위에 표시되는 내 파티 목록
class _PartyStrip extends StatelessWidget {
  const _PartyStrip({required this.parties, required this.uid, required this.onRun});

  final List<Party> parties;
  final String uid;
  final Future<void> Function(Party) onRun;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 112,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        itemCount: parties.length,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (_, i) => PartyCard(
          party: parties[i],
          uid: uid,
          onTap: () => showPartyDetailSheet(context, parties[i].key, onRun: onRun),
        ),
      ),
    );
  }
}

class _MonthSummary extends StatelessWidget {
  const _MonthSummary();

  @override
  Widget build(BuildContext context) {
    final uid = AppConfig.useFirebase ? FirebaseAuth.instance.currentUser!.uid : 'dummy_uid';
    return ValueListenableBuilder<int>(
      valueListenable: LocalDb.instance.changes,
      builder: (_, _, _) {
        final now = DateTime.now();
        return FutureBuilder<List<RunRecord>>(
          future: LocalDb.instance.getFinishedRunsBetween(
            uid,
            DateTime(now.year, now.month),
            DateTime(now.year, now.month + 1),
          ),
          builder: (_, snap) {
            final runs = snap.data ?? [];
            final dist = runs.fold<double>(0, (s, r) => s + r.distanceM);
            final days = runs.map((r) {
              final d = DateTime.fromMillisecondsSinceEpoch(r.startedAt);
              return d.day;
            }).toSet();
            return Container(
              margin: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(18)),
              child: Row(
                children: [
                  Expanded(child: StatColumn(value: Fmt.km(dist, digits: 1), label: '${now.month}월 km')),
                  Expanded(child: StatColumn(value: '${runs.length}', label: '러닝 횟수')),
                  Expanded(child: StatColumn(value: '${days.length}', label: '달린 날')),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class StatColumn extends StatelessWidget {
  const StatColumn({super.key, required this.value, required this.label});
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Text(value, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: AppColors.neon)),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
        ],
      );
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.onHome});
  final VoidCallback onHome;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onHome,
          child: const SizedBox(
            height: 60,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.home_rounded, color: AppColors.neon),
                SizedBox(width: 10),
                Text('홈 · 지난 러닝 기록', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                SizedBox(width: 6),
                Icon(Icons.chevron_right, color: AppColors.textSecondary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
