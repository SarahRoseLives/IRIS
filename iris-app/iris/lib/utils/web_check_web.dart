// lib/utils/web_check_web.dart
import 'dart:html' as html;

bool isFirebaseMessagingSupported() {
  return html.window.navigator.serviceWorker != null;
}
