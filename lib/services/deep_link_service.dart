import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';

import '../config/app_config.dart';

/// `runtogether://join?id=...&pw=...` 초대 링크 처리
class DeepLinkService {
  DeepLinkService._();
  static final DeepLinkService instance = DeepLinkService._();

  final _links = AppLinks();
  StreamSubscription? _sub;

  /// 받은 초대 (메인 화면이 소비 후 null 로 되돌림)
  final ValueNotifier<({String id, String? pw})?> pendingInvite = ValueNotifier(null);

  Future<void> start() async {
    try {
      final initial = await _links.getInitialLink();
      if (initial != null) _handle(initial);
    } catch (_) {}
    _sub ??= _links.uriLinkStream.listen(_handle, onError: (_) {});
  }

  void _handle(Uri uri) {
    if (uri.scheme != AppConfig.appScheme || uri.host != 'join') return;
    final id = uri.queryParameters['id'];
    if (id == null || id.isEmpty) return;
    pendingInvite.value = (id: id, pw: uri.queryParameters['pw']);
  }
}
