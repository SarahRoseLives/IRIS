import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
// Add this import for platform checking
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class UpdateService {
  static const String _githubReleasesUrl =
      'https://api.github.com/repos/TransIRC/TransIRIS/releases/latest';
  static const String _lastUpdateCheckKey = 'last_update_check';
  static const Duration _checkInterval = Duration(days: 1); // Check once per day

  // Check for updates and show dialog if new version is available
  static Future<void> checkForUpdates(BuildContext context,
      {bool forceCheck = false}) async {
    // --- START OF CHANGE ---
    // This check ensures that the update functionality only runs on Android.
    // It will do nothing on web or any other platform.
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      // If this check was manually triggered on a non-Android platform,
      // you could optionally inform the user, but for now, we'll just exit.
      // The button to trigger this will be hidden on non-Android platforms anyway.
      return;
    }
    // --- END OF CHANGE ---

    try {
      final prefs = await SharedPreferences.getInstance();
      final lastCheck =
          DateTime.tryParse(prefs.getString(_lastUpdateCheckKey) ?? '');

      // Skip if we checked recently and it's not a forced check
      if (!forceCheck &&
          lastCheck != null &&
          DateTime.now().difference(lastCheck) < _checkInterval) {
        return;
      }

      // Get current app version
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;

      // Get latest release from GitHub
      final response = await http.get(Uri.parse(_githubReleasesUrl));
      if (response.statusCode == 200) {
        final releaseData = json.decode(response.body);
        final latestVersion =
            releaseData['tag_name']?.replaceFirst('v', '') ?? '0.0.0';

        // Compare versions
        if (_isNewerVersion(latestVersion, currentVersion)) {
          await prefs.setString(
              _lastUpdateCheckKey, DateTime.now().toIso8601String());
          _showUpdateDialog(context, latestVersion, releaseData['html_url']);
        }
      }
    } catch (e) {
      print('Error checking for updates: $e');
      // Fail silently - we don't want to bother users with update check errors
    }
  }

  // Compare version strings (simple implementation)
  static bool _isNewerVersion(String newVersion, String currentVersion) {
    try {
      final newParts = newVersion.split('.').map(int.parse).toList();
      final currentParts = currentVersion.split('.').map(int.parse).toList();

      for (var i = 0; i < newParts.length; i++) {
        if (i >= currentParts.length) return true;
        if (newParts[i] > currentParts[i]) return true;
        if (newParts[i] < currentParts[i]) return false;
      }
      return false;
    } catch (e) {
      return false; // If version parsing fails, assume it's not newer
    }
  }

  // Show update dialog
  static Future<void> _showUpdateDialog(
      BuildContext context, String newVersion, String releaseUrl) async {
    return showDialog<void>(
      context: context,
      barrierDismissible: false, // User must take action
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Update Available'),
          content: Text(
              'A new version ($newVersion) of IRIS is available. Would you like to download it now?'),
          actions: <Widget>[
            TextButton(
              child: const Text('Later'),
              onPressed: () => Navigator.of(context).pop(),
            ),
            TextButton(
              child: const Text('Download'),
              onPressed: () async {
                Navigator.of(context).pop();
                if (await canLaunchUrl(Uri.parse(releaseUrl))) {
                  await launchUrl(Uri.parse(releaseUrl));
                }
              },
            ),
          ],
        );
      },
    );
  }
}
