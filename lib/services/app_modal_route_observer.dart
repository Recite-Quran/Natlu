import 'package:flutter/material.dart';

/// AppModalRouteObserver
///
/// Reliably tracks the presence of modal dialogs, bottom sheets, and popup routes
/// on the Flutter Navigator.
///
/// In Flutter, modal bottom sheets and dialogs are non-opaque ([PopupRoute]),
/// which means Flutter NEVER drives [ModalRoute.secondaryAnimation] on underlying routes.
/// This observer directly intercepts route pushes and pops, providing an instant,
/// zero-overhead notification stream ([activeModalsNotifier]) to pause/resume
/// background ASR visual sync and waveform tickers during modal interactions.
class AppModalRouteObserver extends NavigatorObserver {
  AppModalRouteObserver._();
  static final AppModalRouteObserver instance = AppModalRouteObserver._();

  final ValueNotifier<int> _activeModalsCount = ValueNotifier<int>(0);

  /// ValueNotifier indicating whether any modal bottom sheet, dialog, or popup is open.
  final ValueNotifier<bool> activeModalsNotifier = ValueNotifier<bool>(false);

  /// Whether any modal is currently open.
  bool get isModalOpen => activeModalsNotifier.value;

  bool _isModal(Route<dynamic> route) => route is PopupRoute;

  void _update() {
    final bool open = _activeModalsCount.value > 0;
    if (activeModalsNotifier.value != open) {
      activeModalsNotifier.value = open;
    }
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    if (_isModal(route)) {
      _activeModalsCount.value++;
      _update();
    }
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    if (_isModal(route) && _activeModalsCount.value > 0) {
      if (route is TransitionRoute &&
          route.animation != null &&
          !route.animation!.isDismissed) {
        late final AnimationStatusListener statusListener;
        statusListener = (status) {
          if (status == AnimationStatus.dismissed) {
            route.animation?.removeStatusListener(statusListener);
            if (_activeModalsCount.value > 0) {
              _activeModalsCount.value--;
              _update();
            }
          }
        };
        route.animation!.addStatusListener(statusListener);
      } else {
        _activeModalsCount.value--;
        _update();
      }
    }
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didRemove(route, previousRoute);
    if (_isModal(route) && _activeModalsCount.value > 0) {
      _activeModalsCount.value--;
      _update();
    }
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    if (oldRoute != null && _isModal(oldRoute) && _activeModalsCount.value > 0) {
      _activeModalsCount.value--;
    }
    if (newRoute != null && _isModal(newRoute)) {
      _activeModalsCount.value++;
    }
    _update();
  }
}

