# 런투게더 (running_app)

위치 기반 러닝 기록 앱 — 혼자 달리기 / 파티(같이 뛰기) / 의리게임.
Flutter(Android·iOS) + Firebase(Auth · Firestore · Realtime Database · FCM · Cloud Functions).

- 데이터 계약/설계: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- 백엔드 상세: [functions/README.md](functions/README.md)

## 데이터 원칙 요약

| 저장소 | 역할 |
|---|---|
| Local DB (sqflite) | 러닝·GPS **원본** (오프라인에서도 기록, 복구 후 자동 동기화) |
| Realtime Database | 단체 러닝 중 최소 실시간 상태 (3~5초 주기), 종료 후 삭제 |
| Firestore | 완료된 러닝/통계/파티 영구 저장 (서버 검증 `verification` 포함) |
| Firebase Auth | uid 관리 (Google/Apple 기본, 카카오/네이버/인스타는 Custom Token) |
| FCM | 파티 참여/시작/종료/강퇴 알림 |

순위는 DB에 저장하지 않고 앱에서 `distance DESC`로 계산합니다.

---

## 1. 필수 도구

```bash
npm i -g firebase-tools
dart pub global activate flutterfire_cli
firebase login
```

## 2. Firebase 프로젝트 설정

1. Firebase 콘솔에서 프로젝트 생성 → **Blaze 요금제**로 전환 (Cloud Functions 외부 호출 필요).
2. `.firebaserc`의 `YOUR_FIREBASE_PROJECT_ID`를 실제 프로젝트 ID로 변경.
3. 앱 연결 (placeholder인 `lib/firebase_options.dart`를 덮어씀):
   ```bash
   flutterfire configure --project=<프로젝트ID> --platforms=android,ios
   ```
   Android 패키지명/iOS 번들 ID는 `android/app/build.gradle.kts`, Xcode 설정과 일치해야 합니다.
4. 콘솔에서 활성화:
   - **Authentication**: Google, Apple 제공업체 사용 설정
   - **Firestore**: 위치 `asia-northeast3`(서울)
   - **Realtime Database**: 예) `asia-southeast1` → 아래 `RTDB_REGION`과 반드시 동일하게
   - **Cloud Messaging**: iOS는 APNs 인증 키(.p8) 업로드
5. Cloud Functions 런타임 서비스 계정에 **서비스 계정 토큰 생성자(Service Account Token Creator)** 역할 부여 (Custom Token 발급용).

## 3. 백엔드 배포

```bash
cd functions
cp .env.example .env      # KAKAO_APP_ID, INSTAGRAM_APP_ID, INSTAGRAM_REDIRECT_URI, RTDB_REGION 입력
npm install
firebase functions:secrets:set INSTAGRAM_APP_SECRET
cd ..
firebase deploy --only firestore:rules,firestore:indexes,database,functions
```

## 4. 지도 / 소셜 로그인 키

### Google Maps
- Google Cloud 콘솔에서 **Maps SDK for Android / iOS** 사용 설정 후 키 발급
- Android: `android/local.properties`에 추가
  ```properties
  MAPS_API_KEY=발급받은키
  KAKAO_NATIVE_APP_KEY=카카오네이티브앱키
  ```
- iOS: [ios/Flutter/Keys.xcconfig](ios/Flutter/Keys.xcconfig)의 `MAPS_API_KEY`

### Google 로그인
- Firebase Auth의 Google 제공업체에서 **웹 클라이언트 ID** 확인 → `GOOGLE_SERVER_CLIENT_ID`
- iOS 클라이언트 ID → `GOOGLE_IOS_CLIENT_ID`, `Keys.xcconfig`의 `GOOGLE_IOS_CLIENT_ID` / `GOOGLE_REVERSED_CLIENT_ID`
- Android는 Firebase 프로젝트에 디버그/릴리즈 **SHA-1** 등록 필요

### 카카오
- [Kakao Developers](https://developers.kakao.com) 앱 생성 → 네이티브 앱 키, 앱 ID 확인
- 플랫폼에 Android 패키지명+키 해시, iOS 번들 ID 등록, 카카오 로그인 활성화
- 앱: `KAKAO_NATIVE_APP_KEY` (dart-define, `local.properties`, `Keys.xcconfig`)
- 서버: `functions/.env`의 `KAKAO_APP_ID`

### 네이버
- [네이버 개발자센터](https://developers.naver.com) 애플리케이션 등록 (네이버 로그인)
- Android: [naver.xml](android/app/src/main/res/values/naver.xml), iOS: `Keys.xcconfig`의 `NAVER_CLIENT_ID` / `NAVER_CLIENT_SECRET` / `NAVER_URL_SCHEME`

### 인스타그램
- Meta 개발자 앱 → **Instagram API with Instagram Login** 구성
- 리디렉션 URI = 배포된 `instagramAuthRedirect` 함수 URL
- 앱: `INSTAGRAM_APP_ID`, `INSTAGRAM_REDIRECT_URI` / 서버: `.env` + `INSTAGRAM_APP_SECRET` 시크릿

> [!WARNING]
> Meta의 Basic Display API가 종료되어 **인스타그램 로그인은 비즈니스/크리에이터 계정만** 가능합니다.

## 5. 실행

```bash
flutter pub get
flutter run \
  --dart-define=KAKAO_NATIVE_APP_KEY=... \
  --dart-define=GOOGLE_SERVER_CLIENT_ID=....apps.googleusercontent.com \
  --dart-define=GOOGLE_IOS_CLIENT_ID=....apps.googleusercontent.com \
  --dart-define=INSTAGRAM_APP_ID=... \
  --dart-define=INSTAGRAM_REDIRECT_URI=https://...cloudfunctions.net/instagramAuthRedirect
```

`--dart-define-from-file=env.json` 형식으로 파일에 모아 쓰는 것을 권장합니다 (git 커밋 금지).
Firebase 설정 전에 실행하면 설정 안내 화면이 표시됩니다.

## 6. iOS 추가 작업 (macOS / Xcode)

1. `cd ios && pod install` (최소 iOS 15)
2. Xcode에서 `Runner/Runner.entitlements`를 타깃에 연결 (Build Settings → Code Signing Entitlements)
3. Signing & Capabilities: **Push Notifications**, **Sign in with Apple**, **Background Modes**(Location updates, Audio, Remote notifications) 추가
4. Firebase Auth에서 Apple 제공업체 설정 (Services ID / 키)

> [!CAUTION]
> 이 프로젝트는 Windows에서 개발되어 **iOS 빌드는 검증되지 않았습니다.** 특히 네이버 로그인 콜백용
> `SceneDelegate.swift`의 `scene(_:openURLContexts:)` 오버라이드는 Xcode에서 컴파일 확인이 필요합니다.

## 7. 검증

```bash
flutter analyze
flutter test
flutter build apk --debug
cd functions && npm run build
```

## 알려진 제한 / TODO
- "그룹 러닝 초대" 푸시는 친구 시스템이 없어 미구현 (파티 ID 공유 링크 `runtogether://join` 으로 대체)
- 서버에서 복원한 기록의 인증서 공유 이미지에는 참가자 수가 `-`로 표시될 수 있음
- 사진은 기기 로컬에만 저장되며 기기 변경 시 복원되지 않음 (요구사항)
