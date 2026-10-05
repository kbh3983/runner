import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_naver_login/flutter_naver_login.dart';
import 'package:flutter_naver_login/interface/types/naver_login_status.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:kakao_flutter_sdk_user/kakao_flutter_sdk_user.dart' as kakao;

import '../config/app_config.dart';

class AuthCancelled implements Exception {}

/// Firebase Authentication 래퍼.
///
/// * Google / Apple : Firebase Auth 기본 제공자
/// * Kakao / Naver / Instagram : 제공자 토큰을 Cloud Functions 에서 검증 →
///   Firebase Custom Token 발급 → signInWithCustomToken
///
/// 비밀번호/인증정보는 자체 DB에 저장하지 않으며, uid 만 식별자로 쓴다.
class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  FirebaseAuth get _auth => FirebaseAuth.instance;
  FirebaseFunctions get _functions => FirebaseFunctions.instanceFor(region: AppConfig.functionsRegion);

  bool _googleInitialized = false;

  User? get currentUser => AppConfig.useFirebase ? _auth.currentUser : null;
  Stream<User?> authChanges() => AppConfig.useFirebase ? _auth.authStateChanges() : Stream.value(null);

  String get displayName {
    if (!AppConfig.useFirebase) return 'Guest (No Firebase)';
    final u = _auth.currentUser;
    final n = u?.displayName;
    if (n != null && n.trim().isNotEmpty) return n.trim();
    return 'Runner';
  }

  // ------------------------------------------------------------ Google

  Future<void> signInWithGoogle() async {
    final g = GoogleSignIn.instance;
    if (!_googleInitialized) {
      await g.initialize(
        clientId: Platform.isIOS && AppConfig.googleIosClientId.isNotEmpty ? AppConfig.googleIosClientId : null,
        serverClientId: AppConfig.googleServerClientId.isEmpty ? null : AppConfig.googleServerClientId,
      );
      _googleInitialized = true;
    }
    final GoogleSignInAccount account;
    try {
      account = await g.authenticate();
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) throw AuthCancelled();
      rethrow;
    }
    final idToken = account.authentication.idToken;
    if (idToken == null) throw Exception('Google idToken 을 받지 못했어요');
    await _auth.signInWithCredential(GoogleAuthProvider.credential(idToken: idToken));
    await _ensureUserDoc('google');
  }

  // ------------------------------------------------------------ Apple

  Future<void> signInWithApple() async {
    final provider = AppleAuthProvider()
      ..addScope('email')
      ..addScope('name');
    try {
      await _auth.signInWithProvider(provider);
    } on FirebaseAuthException catch (e) {
      if (e.code == 'canceled' || e.code == 'web-context-canceled') throw AuthCancelled();
      rethrow;
    }
    await _ensureUserDoc('apple');
  }

  // ------------------------------------------------------------ Kakao

  Future<void> signInWithKakao() async {
    kakao.OAuthToken token;
    try {
      if (await kakao.isKakaoTalkInstalled()) {
        try {
          token = await kakao.UserApi.instance.loginWithKakaoTalk();
        } catch (e) {
          if (e.isCancel) throw AuthCancelled();
          token = await kakao.UserApi.instance.loginWithKakaoAccount();
        }
      } else {
        token = await kakao.UserApi.instance.loginWithKakaoAccount();
      }
    } on AuthCancelled {
      rethrow;
    } catch (e) {
      if (e.toString().contains('CANCELED') || e.toString().contains('access_denied')) {
        throw AuthCancelled();
      }
      rethrow;
    }
    final result = await _functions.httpsCallable('kakaoLogin').call({'accessToken': token.accessToken});
    await _auth.signInWithCustomToken((result.data as Map)['token'] as String);
    await _ensureUserDoc('kakao');
  }

  // ------------------------------------------------------------ Naver

  Future<void> signInWithNaver() async {
    final res = await FlutterNaverLogin.logIn();
    if (res.status != NaverLoginStatus.loggedIn) {
      if (res.status == NaverLoginStatus.error && (res.errorMessage?.isNotEmpty ?? false)) {
        throw Exception(res.errorMessage);
      }
      throw AuthCancelled();
    }
    var accessToken = res.accessToken?.accessToken ?? '';
    if (accessToken.isEmpty) {
      accessToken = (await FlutterNaverLogin.getCurrentAccessToken()).accessToken;
    }
    final result = await _functions.httpsCallable('naverLogin').call({'accessToken': accessToken});
    await _auth.signInWithCustomToken((result.data as Map)['token'] as String);
    await _ensureUserDoc('naver');
  }

  // ------------------------------------------------------------ common

  Future<void> _ensureUserDoc(String provider) async {
    final u = _auth.currentUser;
    if (u == null) return;
    final ref = FirebaseFirestore.instance.collection('users').doc(u.uid);
    try {
      final snap = await ref.get().timeout(const Duration(seconds: 8));
      final data = <String, dynamic>{
        'displayName': u.displayName ?? 'Runner',
        'photoUrl': u.photoURL,
        'provider': provider,
      };
      if (!snap.exists) data['createdAt'] = FieldValue.serverTimestamp();
      await ref.set(data, SetOptions(merge: true));
    } catch (e) {
      // 네트워크 불안정 시 로그인 자체는 성공으로 둔다.
      debugPrint('ensureUserDoc failed: $e');
    }
  }

  Future<void> signOut() async {
    try {
      await GoogleSignIn.instance.signOut();
    } catch (_) {}
    try {
      await kakao.UserApi.instance.logout();
    } catch (_) {}
    try {
      await FlutterNaverLogin.logOut();
    } catch (_) {}
    await _auth.signOut();
  }

  String _randomString(int length) {
    const chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final rnd = Random.secure();
    return List.generate(length, (_) => chars[rnd.nextInt(chars.length)]).join();
  }
}

/// Kakao SDK 의 취소 예외를 느슨하게 판별하기 위한 헬퍼
extension PlatformExceptionLike on Object {
  bool get isCancel {
    final s = toString();
    return s.contains('CANCELED') || s.contains('canceled') || s.contains('cancelled');
  }
}
