class NotificationService {
  static String? Function()? getCurrentDMChannel;

  Future<void> init() async {}
  Future<String?> getFCMToken() async => null;
  void showFlutterNotification(dynamic message) {}
  void handleNotificationTap(Map<String, dynamic> data) {}

  /// Stub for onAppResumed
  void onAppResumed() {
    // No operation in stub.
  }

  /// Stub for onAppPaused
  void onAppPaused() {
    // No operation in stub.
  }
}