import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';

import '../app_keys.dart';

/// 백그라운드 메시지 핸들러 (top-level 이어야 함). 알림은 OS 가 표시한다.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {}

/// FCM 푸시 알림: 파티 참여/시작/강퇴/의리게임 결과 등
class PushService {
  PushService._();
  static final PushService instance = PushService._();

  FirebaseMessaging get _fm => FirebaseMessaging.instance;
  StreamSubscription? _tokenSub;
  StreamSubscription? _msgSub;
  StreamSubscription? _openSub;

  /// 알림을 눌러 앱이 열렸을 때 (type, partyKey)
  final ValueNotifier<RemoteMessage?> opened = ValueNotifier(null);

  Future<void> start() async {
    try {
      await _fm.requestPermission(alert: true, badge: true, sound: true);
      await _fm.setForegroundNotificationPresentationOptions(alert: true, badge: true, sound: true);
      final token = await _fm.getToken();
      if (token != null) await _saveToken(token);
      _tokenSub ??= _fm.onTokenRefresh.listen(_saveToken);
      _msgSub ??= FirebaseMessaging.onMessage.listen(_onForeground);
      _openSub ??= FirebaseMessaging.onMessageOpenedApp.listen((m) => opened.value = m);
      final initial = await _fm.getInitialMessage();
      if (initial != null) opened.value = initial;
    } catch (e) {
      debugPrint('push init failed: $e');
    }
  }

  Future<void> _saveToken(String token) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      await FirebaseFirestore.instance.collection('users').doc(uid).set({
        'fcmTokens': FieldValue.arrayUnion([token]),
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('save fcm token failed: $e');
    }
  }

  Future<void> removeToken() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    try {
      final token = await _fm.getToken();
      if (uid != null && token != null) {
        await FirebaseFirestore.instance.collection('users').doc(uid).set({
          'fcmTokens': FieldValue.arrayRemove([token]),
        }, SetOptions(merge: true));
      }
    } catch (_) {}
  }

  void _onForeground(RemoteMessage m) {
    final title = m.notification?.title;
    final body = m.notification?.body;
    if (title == null && body == null) return;
    AppKeys.messenger.currentState?.showSnackBar(SnackBar(
      content: Text([title, body].whereType<String>().join('\n')),
      duration: const Duration(seconds: 4),
    ));
  }
}
