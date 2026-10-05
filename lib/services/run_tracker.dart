import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:uuid/uuid.dart';

import '../config/app_config.dart';
import '../core/geo.dart';
import '../data/local/local_db.dart';
import '../data/models/gps_point.dart';
import '../data/models/party.dart';
import '../data/models/run_record.dart';
import 'live_session_service.dart';
import 'server_clock.dart';
import 'sync_service.dart';
import 'voice_service.dart';

class RunConfig {
  final RunMode mode;
  final GoalType goalType;
  final double? goalValue; // distance → m, time → s
  final String? partyKey;
  final String? partyId;
  final bool loyalty;
  final int? raceStartAt; // 서버 시각 기준 공통 출발 시각
  final int? colorIndex;
  final List<Participant> participants;

  /// 의리게임: 이전 세션까지 내가 기여한 거리 (m)
  final double baseDistanceM;

  const RunConfig({
    this.mode = RunMode.solo,
    this.goalType = GoalType.none,
    this.goalValue,
    this.partyKey,
    this.partyId,
    this.loyalty = false,
    this.raceStartAt,
    this.colorIndex,
    this.participants = const [],
    this.baseDistanceM = 0,
  });

  factory RunConfig.fromParty(Party party, String uid, {double baseDistanceM = 0}) => RunConfig(
        mode: RunMode.group,
        goalType: party.goalType,
        goalValue: party.goalValue,
        partyKey: party.key,
        partyId: party.id,
        loyalty: party.loyalty,
        raceStartAt: party.startAt,
        colorIndex: party.members[uid]?.colorIndex ?? 0,
        participants: party.sortedMembers.map((m) => m.toParticipant()).toList(),
        baseDistanceM: baseDistanceM,
      );
}

enum TrackerState { idle, running, paused, finished }

enum FinishReason { manual, goalDistance, goalTime, loyaltySuccess, loyaltyFailed }

class LocationException implements Exception {
  final String message;
  LocationException(this.message);
  @override
  String toString() => message;
}

/// 러닝 엔진.
///
/// GPS → (필터링) → Local DB 저장 → 화면 표시용 상태 계산
///                       └ (단체 러닝일 때만) 주기적으로 RTDB 에 최소 상태 전송
///
/// 서버 전송 실패는 러닝 진행에 영향을 주지 않는다.
class RunTracker extends ChangeNotifier {
  RunTracker._();
  static final RunTracker instance = RunTracker._();

  // ------------------------------------------------------------ 공개 상태
  RunRecord? run;
  RunConfig config = const RunConfig();
  TrackerState state = TrackerState.idle;
  LatLng? position;
  double? currentPaceSec;
  FinishReason? finishReason;

  /// 화면 표시용 경로 (일시정지마다 구간 분리). GPS 원본은 Local DB 에 따로 보관.
  final List<List<LatLng>> segments = [];

  /// 단체 러닝: 파티원 실시간 상태 / 받은 위치로 그린 간이 궤적
  Map<String, LiveMember> liveMembers = {};
  final Map<String, List<LatLng>> memberTrails = {};

  double get distanceM => run?.distanceM ?? 0;
  int get movingMs => _accumulatedMs + (_activeSince == null ? 0 : _nowMs() - _activeSince!);
  double? get avgPaceSec => _pace(movingMs, distanceM);
  bool get isActive => state == TrackerState.running || state == TrackerState.paused;
  bool get isGroup => config.mode == RunMode.group;

  /// 의리게임 팀 합계 (km)
  double get teamTotalKm {
    var sum = 0.0;
    final me = run?.ownerId;
    for (final m in liveMembers.values) {
      if (m.userId == me) continue;
      sum += m.teamContributionKm;
    }
    return sum + (config.baseDistanceM + distanceM) / 1000;
  }

  final _finishCtrl = StreamController<FinishReason>.broadcast();
  Stream<FinishReason> get onFinished => _finishCtrl.stream;

  // ------------------------------------------------------------ 내부 상태
  StreamSubscription<Position>? _posSub;
  StreamSubscription? _membersSub;
  StreamSubscription? _metaSub;
  Timer? _ticker;
  int _accumulatedMs = 0;
  int? _activeSince;
  int _segment = 0;
  int _seq = 0;
  ({double lat, double lng, int ts, int elapsed, double dist})? _last;
  int _lastStoredTs = 0;
  final List<({int t, double d})> _paceWindow = [];
  double? _lastAltitude;
  int _nextTimelineMs = 0;
  int _lastPersistAt = 0;
  double _lastSpeed = 0;

  LiveSessionService? _live;
  int _lastPushAt = 0;
  LatLng? _lastPushPos;
  String? _lastPushStatus;
  bool _finishing = false;

  int _nowMs() => DateTime.now().millisecondsSinceEpoch;

  static double? _pace(int ms, double meters) {
    if (meters < 50 || ms <= 0) return null;
    return (ms / 1000) / (meters / 1000);
  }

  // ------------------------------------------------------------ 권한

  static Future<void> ensurePermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw LocationException('위치 서비스(GPS)를 켜 주세요');
    }
    var p = await Geolocator.checkPermission();
    if (p == LocationPermission.denied) p = await Geolocator.requestPermission();
    if (p == LocationPermission.denied) throw LocationException('위치 권한이 필요해요');
    if (p == LocationPermission.deniedForever) {
      throw LocationException('설정에서 위치 권한을 허용해 주세요');
    }
  }

  static Future<LatLng?> currentLatLng() async {
    try {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null) return LatLng(last.latitude, last.longitude);
      final p = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      ).timeout(const Duration(seconds: 8));
      return LatLng(p.latitude, p.longitude);
    } catch (_) {
      return null;
    }
  }

  LocationSettings _locationSettings() {
    if (Platform.isAndroid) {
      return AndroidSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: AppConfig.gpsDistanceFilterM,
        intervalDuration: const Duration(seconds: 1),
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: '${AppConfig.appNameKo} 러닝 중',
          notificationText: '러닝 기록을 측정하고 있어요',
          notificationChannelName: '러닝 측정',
          enableWakeLock: true,
          setOngoing: true,
        ),
      );
    }
    if (Platform.isIOS) {
      return AppleSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        activityType: ActivityType.fitness,
        distanceFilter: AppConfig.gpsDistanceFilterM,
        pauseLocationUpdatesAutomatically: false,
        showBackgroundLocationIndicator: true,
        allowBackgroundLocationUpdates: true,
      );
    }
    return const LocationSettings(accuracy: LocationAccuracy.best, distanceFilter: AppConfig.gpsDistanceFilterM);
  }

  // ------------------------------------------------------------ 시작 / 복구

  Future<RunRecord> start(RunConfig cfg, {required String uid, required String name}) async {
    if (isActive) throw StateError('이미 러닝 중이에요');
    await ensurePermission();
    _resetInternal();
    config = cfg;
    final now = _nowMs();
    run = RunRecord(
      id: const Uuid().v4(),
      ownerId: uid,
      ownerName: name,
      mode: cfg.mode,
      partyKey: cfg.partyKey,
      partyId: cfg.partyId,
      goalType: cfg.goalType,
      goalValue: cfg.goalValue,
      loyalty: cfg.loyalty,
      startedAt: now,
      raceStartAt: cfg.raceStartAt,
      colorIndex: cfg.colorIndex,
      participants: cfg.participants,
      status: RunStatus.active,
    );
    segments.add([]);
    await LocalDb.instance.upsertRun(run!);

    state = TrackerState.running;
    _activeSince = now;
    _startStreams();
    _maybePublish(force: true);
    notifyListeners();
    return run!;
  }

  /// 앱이 비정상 종료됐을 때 Local DB 에 남아있던 러닝을 이어서 복구한다.
  Future<void> restore(RunRecord saved) async {
    _resetInternal();
    final pts = await LocalDb.instance.getPoints(saved.id);
    run = saved;
    config = RunConfig(
      mode: saved.mode,
      goalType: saved.goalType,
      goalValue: saved.goalValue,
      partyKey: saved.partyKey,
      partyId: saved.partyId,
      loyalty: saved.loyalty,
      raceStartAt: saved.raceStartAt,
      colorIndex: saved.colorIndex,
      participants: saved.participants,
    );
    if (saved.loyalty && saved.partyKey != null) {
      final prev = await LocalDb.instance.getRunsForParty(saved.ownerId, saved.partyKey!);
      config = RunConfig(
        mode: config.mode,
        goalType: config.goalType,
        goalValue: config.goalValue,
        partyKey: config.partyKey,
        partyId: config.partyId,
        loyalty: true,
        raceStartAt: config.raceStartAt,
        colorIndex: config.colorIndex,
        participants: config.participants,
        baseDistanceM: prev
            .where((r) => r.id != saved.id && r.status == RunStatus.finished)
            .fold<double>(0, (s, r) => s + r.distanceM),
      );
    }
    var seg = -1;
    for (final p in pts) {
      if (p.segment != seg) {
        segments.add([]);
        seg = p.segment;
      }
      segments.last.add(p.latLng);
    }
    if (pts.isNotEmpty) {
      final lastP = pts.last;
      run!.distanceM = lastP.distance > run!.distanceM ? lastP.distance : run!.distanceM;
      run!.durationMs = lastP.elapsedMs > run!.durationMs ? lastP.elapsedMs : run!.durationMs;
      _segment = lastP.segment;
      _seq = lastP.seq + 1;
      position = lastP.latLng;
    }
    if (segments.isEmpty) segments.add([]);
    _accumulatedMs = run!.durationMs;
    _nextTimelineMs = ((run!.durationMs ~/ AppConfig.timelineInterval.inMilliseconds) + 1) *
        AppConfig.timelineInterval.inMilliseconds;
    state = TrackerState.paused;
    run!.status = RunStatus.paused;
    await LocalDb.instance.upsertRun(run!);
    _startStreams();
    notifyListeners();
  }

  void _startStreams() {
    _posSub?.cancel();
    _posSub = Geolocator.getPositionStream(locationSettings: _locationSettings()).listen(
      _onPosition,
      onError: (Object e) => debugPrint('GPS error: $e'),
    );
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());

    if (isGroup && config.partyKey != null) {
      _live = LiveSessionService(config.partyKey!);
      _membersSub = _live!.members().listen(_onLiveMembers);
      _metaSub = _live!.metaStatus().listen((status) {
        if (!isActive) return;
        if (status == 'COMPLETED' && config.loyalty) finish(FinishReason.loyaltySuccess);
        if (status == 'FAILED' && config.loyalty) finish(FinishReason.loyaltyFailed);
      });
    }
  }

  // ------------------------------------------------------------ 일시정지 / 재개

  Future<void> pause() async {
    if (state != TrackerState.running) return;
    _accumulatedMs = movingMs;
    _activeSince = null;
    state = TrackerState.paused;
    run!
      ..status = RunStatus.paused
      ..durationMs = _accumulatedMs;
    notifyListeners();
    _maybePublish(force: true);
    await LocalDb.instance.upsertRun(run!, notify: false);
  }

  Future<void> resume() async {
    if (state != TrackerState.paused) return;
    _segment++;
    _last = null; // 일시정지 중 이동한 거리는 포함하지 않음
    _paceWindow.clear();
    segments.add([]);
    _activeSince = _nowMs();
    state = TrackerState.running;
    run!.status = RunStatus.active;
    notifyListeners();
    _maybePublish(force: true);
    await LocalDb.instance.upsertRun(run!, notify: false);
  }

  // ------------------------------------------------------------ GPS 처리

  void _onPosition(Position pos) {
    final latLng = LatLng(pos.latitude, pos.longitude);
    position = latLng;

    if (state != TrackerState.running || run == null) {
      notifyListeners();
      return;
    }
    if (pos.accuracy > AppConfig.maxAccuracyM) {
      notifyListeners();
      return; // 부정확한 값은 기록하지 않음
    }

    final ts = pos.timestamp.millisecondsSinceEpoch;
    final elapsed = movingMs;
    final r = run!;
    final prevDistance = r.distanceM;
    final prevElapsed = _last?.elapsed ?? elapsed;

    if (_last != null) {
      final d = Geo.distance(_last!.lat, _last!.lng, pos.latitude, pos.longitude);
      final dt = (ts - _last!.ts) / 1000;
      if (dt <= 0) return;
      if (d / dt > AppConfig.maxSpeedMps) return; // GPS 튐
      r.distanceM += d;
    }

    // 속도 / 고도
    if (pos.speed >= 0 && pos.speed < AppConfig.maxSpeedMps) {
      _lastSpeed = pos.speed;
      if ((r.maxSpeedMps ?? 0) < pos.speed) r.maxSpeedMps = pos.speed;
    }
    if (pos.altitude != 0) {
      if (_lastAltitude == null) {
        _lastAltitude = pos.altitude;
      } else {
        final diff = pos.altitude - _lastAltitude!;
        if (diff.abs() >= 2 && diff.abs() < 30) {
          if (diff > 0) r.elevationGainM = (r.elevationGainM ?? 0) + diff;
          _lastAltitude = pos.altitude;
        }
      }
    }

    // 현재 페이스 (최근 30초)
    _paceWindow.add((t: elapsed, d: r.distanceM));
    _paceWindow.removeWhere((e) => elapsed - e.t > 30000);
    if (_paceWindow.length >= 2) {
      final dd = _paceWindow.last.d - _paceWindow.first.d;
      final dtt = _paceWindow.last.t - _paceWindow.first.t;
      currentPaceSec = dd > 15 ? (dtt / 1000) / (dd / 1000) : null;
    }

    _last = (lat: pos.latitude, lng: pos.longitude, ts: ts, elapsed: elapsed, dist: r.distanceM);
    segments.last.add(latLng);
    r.durationMs = elapsed;
    r.avgPaceSecPerKm = _pace(elapsed, r.distanceM);

    // Local DB 원본 저장 (매초가 아니라 최소 간격 기준)
    final minGap = isGroup ? 2000 : 3000;
    final segmentStart = segments.last.length == 1;
    if (segmentStart || ts - _lastStoredTs >= minGap) {
      _lastStoredTs = ts;
      LocalDb.instance.insertPoint(GpsPoint(
        runId: r.id,
        seq: _seq++,
        lat: pos.latitude,
        lng: pos.longitude,
        ts: ts,
        speed: pos.speed >= 0 ? pos.speed : null,
        altitude: pos.altitude == 0 ? null : pos.altitude,
        accuracy: pos.accuracy,
        distance: r.distanceM,
        pace: currentPaceSec,
        segment: _segment,
        elapsedMs: elapsed,
      ));
    }

    _checkSplits(prevDistance, prevElapsed, elapsed);
    _checkGoals();
    _maybePublish();
    _persistThrottled();
    notifyListeners();
  }

  void _checkSplits(double prevDistance, int prevElapsed, int elapsed) {
    final r = run!;
    while (r.distanceM >= (r.splits.length + 1) * 1000) {
      final km = r.splits.length + 1;
      final target = km * 1000.0;
      // 1km 지점 통과 시점을 직전/현재 포인트 사이에서 보간
      final span = r.distanceM - prevDistance;
      final frac = span > 0 ? ((target - prevDistance) / span).clamp(0.0, 1.0) : 1.0;
      final crossMs = (prevElapsed + (elapsed - prevElapsed) * frac).round();
      final prevMs = r.splits.isEmpty ? 0 : r.splits.last.movingMs;
      final lapPace = (crossMs - prevMs) / 1000;
      final raceMs = r.raceStartAt == null
          ? null
          : (ServerClock.nowMs() - r.raceStartAt! - (elapsed - crossMs)).clamp(0, 1 << 40).toInt();
      r.splits.add(KmSplit(km: km, movingMs: crossMs, raceMs: raceMs, paceSec: lapPace));
      VoiceService.instance.announceKm(km: km, lapPaceSec: lapPace, avgPaceSec: _pace(crossMs, target));
    }
  }

  void _checkGoals() {
    final r = run!;
    if (r.goalType == GoalType.distance && !r.loyalty && r.goalValue != null && r.distanceM >= r.goalValue!) {
      finish(FinishReason.goalDistance);
    } else if (r.goalType == GoalType.time && r.goalValue != null && movingMs >= r.goalValue! * 1000) {
      finish(FinishReason.goalTime);
    } else if (r.loyalty && r.goalValue != null && teamTotalKm * 1000 >= r.goalValue!) {
      finish(FinishReason.loyaltySuccess);
    } else if (r.loyalty &&
        r.raceStartAt != null &&
        ServerClock.nowMs() > r.raceStartAt! + AppConfig.loyaltyDuration.inMilliseconds) {
      finish(FinishReason.loyaltyFailed);
    }
  }

  void _onTick() {
    if (state != TrackerState.running || run == null) {
      if (state == TrackerState.paused) _maybePublish();
      return;
    }
    final elapsed = movingMs;
    run!.durationMs = elapsed;

    // 시간별 페이스 샘플
    while (elapsed >= _nextTimelineMs) {
      final r = run!;
      r.timeline.add(TimelineSample(
        t: _nextTimelineMs ~/ 1000,
        d: r.distanceM,
        r: r.raceStartAt == null ? null : ((ServerClock.nowMs() - r.raceStartAt!) ~/ 1000),
      ));
      _nextTimelineMs += AppConfig.timelineInterval.inMilliseconds;
    }
    _checkGoals();
    if (!isActive) return;
    _maybePublish();
    _persistThrottled();
    notifyListeners();
  }

  void _persistThrottled() {
    final now = _nowMs();
    if (now - _lastPersistAt < 10000) return;
    _lastPersistAt = now;
    LocalDb.instance.upsertRun(run!, notify: false);
  }

  // ------------------------------------------------------------ 실시간 (단체)

  void _onLiveMembers(Map<String, LiveMember> members) {
    liveMembers = members;
    for (final m in members.values) {
      if (m.userId == run?.ownerId || m.latitude == null) continue;
      final trail = memberTrails.putIfAbsent(m.userId, () => []);
      final p = LatLng(m.latitude!, m.longitude!);
      if (trail.isEmpty || Geo.distanceLatLng(trail.last, p) > 3) trail.add(p);
    }
    if (state == TrackerState.running) _checkGoals();
    notifyListeners();
  }

  String get _liveStatus => switch (state) {
        TrackerState.running => 'RUNNING',
        TrackerState.paused => 'PAUSED',
        TrackerState.finished => 'FINISHED',
        TrackerState.idle => 'READY',
      };

  /// 실시간 서버 업데이트. 기본 4초, 빠를 땐 3초, 거의 이동이 없으면 15초 heartbeat.
  /// 상태 변화(일시정지/재개/종료)는 즉시 전송.
  void _maybePublish({bool force = false}) {
    final live = _live;
    final r = run;
    if (live == null || r == null) return;
    final now = _nowMs();
    final status = _liveStatus;
    if (!force && status == _lastPushStatus) {
      var interval = AppConfig.liveUpdateInterval;
      if (_lastSpeed > 4) interval = AppConfig.liveFastInterval;
      final moved = (position != null && _lastPushPos != null)
          ? Geo.distanceLatLng(position!, _lastPushPos!)
          : double.infinity;
      if (moved < 5 || state == TrackerState.paused) interval = AppConfig.liveHeartbeat;
      if (now - _lastPushAt < interval.inMilliseconds) return;
    }
    _lastPushAt = now;
    _lastPushPos = position;
    _lastPushStatus = status;
    live.publish(
      uid: r.ownerId,
      name: r.ownerName,
      colorIndex: r.colorIndex ?? 0,
      distanceM: r.distanceM,
      baseDistanceM: config.baseDistanceM,
      avgPaceSec: avgPaceSec,
      lat: position?.latitude,
      lng: position?.longitude,
      status: status,
    );
  }

  // ------------------------------------------------------------ 종료

  Future<RunRecord?> finish(FinishReason reason) async {
    if (!isActive || _finishing || run == null) return run;
    _finishing = true;
    try {
      if (state == TrackerState.running) _accumulatedMs = movingMs;
      _activeSince = null;
      state = TrackerState.finished;
      finishReason = reason;
      final r = run!
        ..status = RunStatus.finished
        ..endedAt = _nowMs()
        ..durationMs = _accumulatedMs
        ..syncStatus = SyncStatus.pending;
      r.avgPaceSecPerKm = _pace(r.durationMs, r.distanceM);
      if (r.durationMs > 0) {
        r.timeline.add(TimelineSample(
          t: r.durationMs ~/ 1000,
          d: r.distanceM,
          r: r.raceStartAt == null ? null : ((ServerClock.nowMs() - r.raceStartAt!) ~/ 1000),
        ));
      }

      await _posSub?.cancel();
      _posSub = null;
      _ticker?.cancel();
      _ticker = null;

      // 1) Local DB 가 원본 → 가장 먼저 확정 저장
      await LocalDb.instance.upsertRun(r);

      // 2) 단체 러닝이면 실시간 상태를 FINISHED 로
      _maybePublish(force: true);
      await _membersSub?.cancel();
      await _metaSub?.cancel();
      _membersSub = null;
      _metaSub = null;
      await _live?.dispose();
      _live = null;

      switch (reason) {
        case FinishReason.goalDistance:
        case FinishReason.goalTime:
          VoiceService.instance.speak('목표를 달성했어요!');
        case FinishReason.loyaltySuccess:
          VoiceService.instance.speak('의리게임 성공! 모두 수고하셨어요');
        case FinishReason.loyaltyFailed:
          VoiceService.instance.speak('의리게임 제한 시간이 지났어요');
        case FinishReason.manual:
          break;
      }
      VoiceService.instance.announceFinish();
      notifyListeners();
      _finishCtrl.add(reason);

      // 3) 서버 동기화 (실패하면 로컬에 남아 있다가 나중에 재시도)
      unawaited(SyncService.instance.syncAll());
      return r;
    } finally {
      _finishing = false;
    }
  }

  /// 종료 화면 진입 후 엔진을 초기 상태로
  void reset() {
    if (isActive) return;
    _resetInternal();
    notifyListeners();
  }

  void _resetInternal() {
    _posSub?.cancel();
    _ticker?.cancel();
    _membersSub?.cancel();
    _metaSub?.cancel();
    _live?.dispose();
    _posSub = null;
    _ticker = null;
    _membersSub = null;
    _metaSub = null;
    _live = null;
    run = null;
    state = TrackerState.idle;
    finishReason = null;
    position = null;
    currentPaceSec = null;
    segments.clear();
    liveMembers = {};
    memberTrails.clear();
    _accumulatedMs = 0;
    _activeSince = null;
    _segment = 0;
    _seq = 0;
    _last = null;
    _lastStoredTs = 0;
    _paceWindow.clear();
    _lastAltitude = null;
    _nextTimelineMs = AppConfig.timelineInterval.inMilliseconds;
    _lastPersistAt = 0;
    _lastSpeed = 0;
    _lastPushAt = 0;
    _lastPushPos = null;
    _lastPushStatus = null;
  }
}
