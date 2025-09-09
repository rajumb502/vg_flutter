import 'package:flutter/foundation.dart';

class SimpleLogger {
  static void log(String text) {
    if (kDebugMode) {
      print(text);
    }
  }
}