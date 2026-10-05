import 'package:flutter/material.dart';

class AppKeys {
  AppKeys._();
  static final navigator = GlobalKey<NavigatorState>();
  static final messenger = GlobalKey<ScaffoldMessengerState>();

  static void toast(String message) {
    messenger.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}
