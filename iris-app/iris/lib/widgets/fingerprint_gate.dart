// lib/widgets/fingerprint_gate.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/fingerprint_service.dart'; // Use the service from the correct location

/// A widget that acts as a gate, requiring fingerprint authentication
/// if it's enabled for the app before showing its [child].
class FingerprintGate extends StatefulWidget {
  /// The main widget to display after successful authentication.
  final Widget child;

  const FingerprintGate({super.key, required this.child});

  @override
  State<FingerprintGate> createState() => _FingerprintGateState();
}

class _FingerprintGateState extends State<FingerprintGate> {
  final FingerprintService _fingerprintService = FingerprintService();
  bool _isAuthenticated = false;
  bool _isChecking = true;

  @override
  void initState() {
    super.initState();
    _checkAndAuthenticate();
  }

  /// Checks if fingerprint security is enabled and triggers authentication if needed.
  Future<void> _checkAndAuthenticate() async {
    // Ensure the widget is still mounted before updating state.
    if (!mounted) return;

    final isEnabled = await _fingerprintService.isFingerprintEnabled();

    if (isEnabled) {
      final authenticated = await _fingerprintService.authenticate();
      if (mounted) {
        setState(() {
          _isAuthenticated = authenticated;
          _isChecking = false;
        });
      }
    } else {
      // If fingerprint is not enabled, treat as authenticated and proceed.
      if (mounted) {
        setState(() {
          _isAuthenticated = true;
          _isChecking = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isChecking) {
      // Show a loading screen while checking fingerprint settings.
      return const Scaffold(
        backgroundColor: Color(0xFF313338),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(color: Color(0xFF5865F2)),
              SizedBox(height: 20),
              Text('Verifying security...', style: TextStyle(color: Colors.white)),
            ],
          ),
        ),
      );
    }

    // If authenticated (or if fingerprint is not required), show the main app.
    // Otherwise, show the authentication failed screen.
    return _isAuthenticated ? widget.child : _buildAuthFailedScreen();
  }

  /// A fallback screen shown when authentication fails.
  Widget _buildAuthFailedScreen() {
    return Scaffold(
      backgroundColor: const Color(0xFF313338),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.fingerprint, color: Colors.redAccent, size: 64),
              const SizedBox(height: 20),
              const Text(
                'Authentication Required',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 10),
              const Text(
                'Your fingerprint could not be verified.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70, fontSize: 16),
              ),
              const SizedBox(height: 40),
              ElevatedButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text('Try Again'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF5865F2),
                  foregroundColor: Colors.white,
                  minimumSize: const Size(200, 50),
                ),
                onPressed: _checkAndAuthenticate,
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                icon: const Icon(Icons.exit_to_app),
                label: const Text('Exit App'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white70,
                  side: const BorderSide(color: Colors.white54),
                  minimumSize: const Size(200, 50),
                ),
                onPressed: () => SystemNavigator.pop(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}