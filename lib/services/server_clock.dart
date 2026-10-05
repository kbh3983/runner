import 'dart:async';

import 'package:firebase_database/firebase_database.dart';

import '../config/app_config.dart';

/// 서버 기준 시각. 단체 러닝 카운트다운/순위 계산을 기기 시계와 무관하게 맞춘다.
/// RTDB 의 `.info/serverTimeOffset` 을 사용한다.
class ServerClock {
  ServerClock._();

  static int _offsetMs = 0;
  static StreamSubscription? _sub;

  static void start() {
    if (!AppConfig.useFirebase) {
      _offsetMs = 0;
      return;
    }
    _sub ??= FirebaseDatabase.instance.ref('.info/serverTimeOffset').onValue.listen(
      (e) => _offsetMs = (e.snapshot.value as num?)?.toInt() ?? 0,
      onError: (_) {},
    );
  }

  static int nowMs() => DateTime.now().millisecondsSinceEpoch + _offsetMs;

  /// 서버 시각 → 로컬 시각
  static int toLocal(int serverMs) => serverMs - _offsetMs;
}
