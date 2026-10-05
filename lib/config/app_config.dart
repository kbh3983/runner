/// 앱 전역 설정값.
///
/// 비밀이 아닌 공개 키(클라이언트 ID 등)만 둔다. 빌드 시
/// `--dart-define=KEY=VALUE` 로 덮어쓸 수 있다.
class AppConfig {
  AppConfig._();

  static const appName = 'RunTogether';
  static const appNameKo = '런투게더';

  /// Cloud Functions 리전 (functions/src 와 동일해야 함)
  static const functionsRegion = 'asia-northeast3';

  /// Firebase 기능 활성화 여부
  /// 결제 전이거나 로컬에서 UI만 테스트할 때 false 로 설정합니다.
  static const useFirebase = true;

  static const useMaps = true;

  /// 딥링크 / OAuth 콜백 스킴
  static const appScheme = 'runtogether';

  // ---- Social login ----
  static const kakaoNativeAppKey = String.fromEnvironment(
    'KAKAO_NATIVE_APP_KEY',
    defaultValue: 'YOUR_KAKAO_NATIVE_APP_KEY',
  );

  /// Google Sign-In (Android 에서 idToken 을 받기 위한 Web client ID)
  static const googleServerClientId = String.fromEnvironment(
    'GOOGLE_SERVER_CLIENT_ID',
    defaultValue: '',
  );

  /// iOS Google client ID (비워두면 Info.plist 의 GIDClientID 사용)
  static const googleIosClientId = String.fromEnvironment(
    'GOOGLE_IOS_CLIENT_ID',
    defaultValue: '',
  );

  static const instagramAppId = String.fromEnvironment(
    'INSTAGRAM_APP_ID',
    defaultValue: 'YOUR_INSTAGRAM_APP_ID',
  );

  /// Cloud Function `instagramAuthRedirect` 의 URL
  static const instagramRedirectUri = String.fromEnvironment(
    'INSTAGRAM_REDIRECT_URI',
    defaultValue:
        'https://asia-northeast3-YOUR_FIREBASE_PROJECT_ID.cloudfunctions.net/instagramAuthRedirect',
  );

  // ---- Running ----
  /// 단체 러닝 실시간 상태 기본 전송 주기
  static const liveUpdateInterval = Duration(seconds: 4);

  /// 빠르게 이동 중일 때 전송 주기
  static const liveFastInterval = Duration(seconds: 3);

  /// 이동이 거의 없을 때 heartbeat 주기
  static const liveHeartbeat = Duration(seconds: 15);

  /// GPS 정확도 허용치 (m)
  static const maxAccuracyM = 30.0;

  /// 사람이 달릴 수 없는 속도 (m/s) — 튀는 GPS 값 제거용
  static const maxSpeedMps = 12.0;

  /// GPS distanceFilter (m) — 매초 저장하지 않도록 최소 이동거리 기준으로 수신
  static const gpsDistanceFilterM = 4;

  /// 타임라인(시간별 페이스) 샘플 간격
  static const timelineInterval = Duration(seconds: 30);

  /// 서버에 올리는 경로 최대 포인트 수 (원본은 로컬에만 보관)
  static const maxUploadPathPoints = 1500;

  /// 단체 러닝 최대 인원
  static const maxPartyMembers = 10;

  /// 의리게임 제한 시간
  static const loyaltyDuration = Duration(hours: 24);
}
