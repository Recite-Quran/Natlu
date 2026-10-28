import 'package:flutter_web_plugins/flutter_web_plugins.dart';

import '../backend/qvp_backend_web.dart';

/// Web implementation of the QVP Flutter plugin.
class QvpFlutterWeb {
  /// Registers this class as the default instance for web.
  static void registerWith(Registrar registrar) {
    initWebBackend();
  }
}
