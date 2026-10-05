import 'dart:io';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../config/app_config.dart';
import '../services/auth_service.dart';
import '../theme/app_theme.dart';

class LoginScreen extends StatefulWidget {
  final VoidCallback? onDummyLogin;
  const LoginScreen({super.key, this.onDummyLogin});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  String? _busy;

  Future<void> _run(String provider, Future<void> Function() action) async {
    if (!AppConfig.useFirebase && widget.onDummyLogin != null) {
      widget.onDummyLogin!();
      return;
    }
    if (_busy != null) return;
    setState(() => _busy = provider);
    try {
      await action();
    } on AuthCancelled {
      // 사용자가 취소
    } on FirebaseFunctionsException catch (e) {
      _error(e.message ?? '로그인 서버 오류 (${e.code})');
    } on FirebaseAuthException catch (e) {
      _error(e.message ?? '로그인에 실패했어요 (${e.code})');
    } catch (e) {
      _error('로그인에 실패했어요\n$e');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  void _error(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final auth = AuthService.instance;
    final isKorean = Localizations.localeOf(context).languageCode == 'ko';
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF1A2005), AppColors.bg, AppColors.bg],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Spacer(flex: 2),
                Container(
                  width: 96,
                  height: 96,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.neon,
                    boxShadow: [BoxShadow(color: AppColors.neon.withValues(alpha: 0.5), blurRadius: 40)],
                  ),
                  child: const Icon(Icons.directions_run_rounded, size: 56, color: Colors.black),
                ),
                const SizedBox(height: 24),
                const Text(
                  AppConfig.appName,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 34, fontWeight: FontWeight.w900, letterSpacing: -0.5),
                ),
                const SizedBox(height: 8),
                const Text(
                  '혼자서도, 함께라도.\n오늘의 러닝을 기록하세요',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.textSecondary, fontSize: 15, height: 1.5),
                ),
                const Spacer(flex: 3),
                _SocialButton(
                  label: 'Google로 계속하기',
                  background: Colors.white,
                  foreground: Colors.black87,
                  icon: const Text('G', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Color(0xFF4285F4))),
                  loading: _busy == 'google',
                  onTap: () => _run('google', auth.signInWithGoogle),
                ),
                if (isKorean) ...[
                  _SocialButton(
                    label: '카카오로 계속하기',
                    background: const Color(0xFFFEE500),
                    foreground: const Color(0xFF191919),
                    icon: const Icon(Icons.chat_bubble, color: Color(0xFF191919), size: 20),
                    loading: _busy == 'kakao',
                    onTap: () => _run('kakao', auth.signInWithKakao),
                  ),
                  _SocialButton(
                    label: '네이버로 계속하기',
                    background: const Color(0xFF03C75A),
                    foreground: Colors.white,
                    icon: const Text('N', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Colors.white)),
                    loading: _busy == 'naver',
                    onTap: () => _run('naver', auth.signInWithNaver),
                  ),
                ],

                if (Platform.isIOS)
                  _SocialButton(
                    label: 'Apple로 계속하기',
                    background: Colors.black,
                    foreground: Colors.white,
                    border: Colors.white24,
                    icon: const Icon(Icons.apple, color: Colors.white),
                    loading: _busy == 'apple',
                    onTap: () => _run('apple', auth.signInWithApple),
                  ),
                const SizedBox(height: 12),
                const Text(
                  '로그인 정보는 Firebase Authentication 으로만 관리되며\n비밀번호는 저장하지 않아요.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SocialButton extends StatelessWidget {
  const _SocialButton({
    required this.label,
    required this.foreground,
    required this.icon,
    required this.onTap,
    this.background,
    this.gradient,
    this.border,
    this.loading = false,
  });

  final String label;
  final Color? background;
  final Gradient? gradient;
  final Color foreground;
  final Color? border;
  final Widget icon;
  final bool loading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: loading ? null : onTap,
          child: Ink(
            height: 54,
            decoration: BoxDecoration(
              color: background,
              gradient: gradient,
              borderRadius: BorderRadius.circular(14),
              border: border == null ? null : Border.all(color: border!),
            ),
            child: Row(
              children: [
                const SizedBox(width: 20),
                SizedBox(width: 24, child: Center(child: icon)),
                Expanded(
                  child: Center(
                    child: loading
                        ? SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2.5, color: foreground),
                          )
                        : Text(label,
                            style: TextStyle(color: foreground, fontSize: 16, fontWeight: FontWeight.w700)),
                  ),
                ),
                const SizedBox(width: 44),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
