import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kakao_flutter_sdk_user/kakao_flutter_sdk_user.dart';

import 'app.dart';
import 'config/app_config.dart';
import 'data/local/local_db.dart';
import 'firebase_options.dart';
import 'services/app_paths.dart';
import 'services/push_service.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  // 로컬 저장소는 네트워크/Firebase 와 무관하게 먼저 준비
  await AppPaths.init();
  await LocalDb.instance.db;
  await initializeDateFormatting('ko_KR');

  if (AppConfig.useFirebase) {
    try {
      await Firebase.initializeApp(
          options: DefaultFirebaseOptions.currentPlatform);
      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
    } catch (e) {
      runApp(_SetupErrorApp(error: e.toString()));
      return;
    }
  } else {
    debugPrint('Firebase is disabled via AppConfig.useFirebase = false');
  }

  try {
    await KakaoSdk.init(nativeAppKey: AppConfig.kakaoNativeAppKey);
  } catch (e) {
    debugPrint('Kakao init failed: $e');
  }

  runApp(const RunTogetherApp());
}

class _SetupErrorApp extends StatelessWidget {
  const _SetupErrorApp({required this.error});
  final String error;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: AppTheme.dark,
      home: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.build_circle_outlined, size: 56, color: AppColors.neon),
                const SizedBox(height: 16),
                const Text('Firebase 설정이 필요해요',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                const SizedBox(height: 12),
                Text(error, style: const TextStyle(color: AppColors.textSecondary)),
                const SizedBox(height: 12),
                const Text('README.md 의 "Firebase 설정" 절을 참고하세요.'),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
