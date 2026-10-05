import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app_keys.dart';
import 'config/app_config.dart';
import 'screens/login_screen.dart';
import 'screens/main_screen.dart';
import 'services/auth_service.dart';
import 'services/deep_link_service.dart';
import 'services/push_service.dart';
import 'services/server_clock.dart';
import 'services/sync_service.dart';
import 'theme/app_theme.dart';

class RunTogetherApp extends StatelessWidget {
  const RunTogetherApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppConfig.appNameKo,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      navigatorKey: AppKeys.navigator,
      scaffoldMessengerKey: AppKeys.messenger,
      locale: const Locale('ko', 'KR'),
      supportedLocales: const [Locale('ko', 'KR'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: const AuthGate(),
    );
  }
}

/// 로그인 여부에 따라 로그인 / 메인 화면 분기
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> with WidgetsBindingObserver {
  String? _startedFor;
  bool _dummyLoggedIn = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    DeepLinkService.instance.start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) SyncService.instance.syncAll();
  }

  void _startServices(User user) {
    if (_startedFor == user.uid) return;
    _startedFor = user.uid;
    ServerClock.start();
    PushService.instance.start();
    SyncService.instance.start();
    SyncService.instance.pullRemote();
  }

  @override
  Widget build(BuildContext context) {
    if (!AppConfig.useFirebase) {
      if (!_dummyLoggedIn) {
        return LoginScreen(onDummyLogin: () => setState(() => _dummyLoggedIn = true));
      } else {
        if (_startedFor != 'dummy_user') {
          _startedFor = 'dummy_user';
          ServerClock.start();
        }
        return const MainScreen(key: ValueKey('dummy_user'));
      }
    }

    return StreamBuilder<User?>(
      stream: AuthService.instance.authChanges(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        final user = snap.data;
        if (user == null) {
          _startedFor = null;
          return const LoginScreen();
        }
        _startServices(user);
        return MainScreen(key: ValueKey(user.uid));
      },
    );
  }
}
