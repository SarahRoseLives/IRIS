import 'dart:io';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:iris/main.dart'; // Import main.dart to access AuthManager
import 'package:iris/services/update_service.dart';
import 'package:iris/controllers/chat_state.dart';
import 'package:iris/viewmodels/main_layout_viewmodel.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import '../services/api_service.dart';
import '../services/fingerprint_service.dart';

class ProfileScreen extends StatefulWidget {
  final String authToken;

  const ProfileScreen({super.key, required this.authToken});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final ApiService _apiService = ApiService();
  File? _imageFile;
  bool _isUploading = false;
  String? _username;
  String? _avatarUrl;

  // NEW: Controller for pronouns
  final TextEditingController _pronounsController = TextEditingController();

  final FingerprintService _fingerprintService = FingerprintService();
  bool _fingerprintEnabled = false;

  @override
  void initState() {
    super.initState();
    _loadUserInfo();
    _loadFingerprintSetting();
  }

  @override
  void dispose() {
    _pronounsController.dispose(); // NEW: Dispose the controller
    super.dispose();
  }

  Future<void> _loadUserInfo() async {
    final prefs = await SharedPreferences.getInstance();
    // NEW: Access ChatState via GetIt to load initial pronouns
    final chatState = GetIt.instance<ChatState>();

    if (mounted) {
      setState(() {
        _username = prefs.getString('username');
        // NEW: Load pronouns from ChatState
        if (_username != null) {
          _pronounsController.text = chatState.getPronounsForUser(_username!) ?? '';
        }
      });
    }
    await _loadAvatarUrl();
  }

  // NEW: Method to set pronouns
  Future<void> _setPronouns() async {
    // Hide keyboard
    FocusScope.of(context).unfocus();

    final pronouns = _pronounsController.text.trim();
    // Use context.read to call the method once without listening
    final viewModel = context.read<MainLayoutViewModel>();

    await viewModel.setMyPronouns(pronouns);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(pronouns.isEmpty ? 'Pronouns cleared.' : 'Pronouns set to "$pronouns"'),
          backgroundColor: Colors.green,
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _loadAvatarUrl() async {
    if (_username != null) {
      final List<String> possibleExtensions = ['.png', '.jpg', '.jpeg', '.gif'];
      String? foundUrl;

      for (final ext in possibleExtensions) {
        final String potentialAvatarUrl =
            '$baseSecureUrl/avatars/$_username$ext';
        try {
          final response = await http.head(Uri.parse(potentialAvatarUrl));
          if (response.statusCode == 200) {
            foundUrl = potentialAvatarUrl;
            break;
          }
        } catch (e) {
          print("Error checking avatar URL ($potentialAvatarUrl): $e");
        }
      }

      if (mounted) {
        setState(() {
          _avatarUrl = foundUrl;
        });
      }
    }
  }

  Future<void> _loadFingerprintSetting() async {
    if (kIsWeb) return;
    final enabled = await _fingerprintService.isFingerprintEnabled();
    if (mounted) {
      setState(() {
        _fingerprintEnabled = enabled;
      });
    }
  }

  void _handleFingerprintSwitch(bool value) async {
    if (!mounted) return;

    if (value) {
      final canAuth = await _fingerprintService.canAuthenticate();
      if (!canAuth) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Fingerprint authentication is not available on this device.'),
          backgroundColor: Colors.orangeAccent,
        ));
        return;
      }

      final password = await _promptForPassword();
      if (password == null || password.isEmpty) return;

      final verifyResponse = await _apiService.login(_username!, password);
      if (!verifyResponse.success) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Incorrect password. Fingerprint login not enabled.'),
          backgroundColor: Colors.redAccent,
        ));
        return;
      }

      final authenticated = await _fingerprintService.authenticate(
          localizedReason: 'Confirm to enable fingerprint login');

      if (authenticated) {
        await _fingerprintService.saveCredentials(_username!, password);
        await _fingerprintService.setFingerprintEnabled(true);
        if (mounted) {
          setState(() => _fingerprintEnabled = true);
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Fingerprint login enabled.'),
            backgroundColor: Colors.green,
          ));
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Authentication failed. Setting was not changed.'),
          backgroundColor: Colors.redAccent,
        ));
      }
    } else {
      await _fingerprintService.setFingerprintEnabled(false);
      if (mounted) {
        setState(() => _fingerprintEnabled = false);
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Fingerprint login disabled.')));
      }
    }
  }

  Future<String?> _promptForPassword() {
    final passwordController = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2B2D31),
        title: const Text('Confirm Your Password'),
        content: TextField(
          controller: passwordController,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'Password'),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF5865F2)),
            onPressed: () {
              Navigator.pop(context, passwordController.text);
            },
            child:
                const Text('Confirm', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: ImageSource.gallery);

    if (pickedFile != null) {
      if (mounted) {
        setState(() {
          _imageFile = File(pickedFile.path);
        });
      }
    }
  }

  Future<void> _uploadAvatar() async {
    if (_imageFile == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please select an image first.')),
        );
      }
      return;
    }

    setState(() {
      _isUploading = true;
    });

    try {
      final response =
          await _apiService.uploadAvatar(_imageFile!, widget.authToken);
      if (response['success'] == true) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content:
                    Text(response['message'] ?? 'Avatar uploaded successfully!')),
          );
        }
        if (mounted) {
          setState(() {
            _imageFile = null;
            _avatarUrl = response['avatarUrl'] != null
                ? '$baseSecureUrl${response['avatarUrl']}'
                : null;
          });
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text(response['message'] ?? 'Failed to upload avatar.')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error uploading avatar: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isUploading = false;
        });
      }
    }
  }

  Future<void> _logout() async {
    try {
      await AuthManager.forceLogout();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Logout failed: ${e.toString()}')),
        );
      }
    }
  }

  Widget _buildProfileHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 18),
      decoration: BoxDecoration(
        color: const Color(0xFF232428),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Stack(
                alignment: Alignment.bottomRight,
                children: [
                  CircleAvatar(
                    radius: 48,
                    backgroundColor: const Color(0xFF5865F2),
                    backgroundImage: _imageFile != null
                        ? FileImage(_imageFile!) as ImageProvider
                        : (_avatarUrl != null ? NetworkImage(_avatarUrl!) : null),
                    child: _imageFile == null && _avatarUrl == null
                        ? const Icon(Icons.person, size: 48, color: Colors.white70)
                        : null,
                  ),
                  Positioned(
                    bottom: 2,
                    right: 2,
                    child: Material(
                      shape: const CircleBorder(),
                      color: Colors.black54,
                      child: IconButton(
                        icon: const Icon(Icons.camera_alt,
                            color: Colors.white, size: 20),
                        onPressed: _pickImage,
                        tooltip: "Change Avatar",
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 20),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _username ?? 'Not available',
                      style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          color: Colors.white),
                    ),
                    const SizedBox(height: 4),
                    // This now listens to the controller for live updates
                    ValueListenableBuilder<TextEditingValue>(
                      valueListenable: _pronounsController,
                      builder: (context, value, child) {
                        return Text(
                          value.text.isNotEmpty ? value.text : "No pronouns set.",
                          style: TextStyle(color: Colors.grey[400], fontSize: 15, fontStyle: FontStyle.italic),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        );
                      }
                    ),
                  ],
                ),
              ),
            ],
          ),
          _buildAvatarActionButtons(),
        ],
      ),
    );
  }

  Widget _buildAvatarActionButtons() {
    if (_imageFile == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          ElevatedButton.icon(
            onPressed: _uploadAvatar,
            icon: const Icon(Icons.upload_file),
            label: const Text('Upload'),
            style: ElevatedButton.styleFrom(
              foregroundColor: Colors.white,
              backgroundColor: const Color(0xFF5865F2),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              textStyle: const TextStyle(fontSize: 15),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
          ),
          const SizedBox(width: 12),
          OutlinedButton.icon(
            onPressed: () => setState(() => _imageFile = null),
            icon: const Icon(Icons.cancel, color: Colors.white70),
            label: const Text('Cancel', style: TextStyle(color: Colors.white70)),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: Color(0xFF5865F2)),
            ),
          ),
          if (_isUploading)
            const Padding(
              padding: EdgeInsets.only(left: 16),
              child: CircularProgressIndicator(
                  color: Color(0xFF5865F2), strokeWidth: 3),
            ),
        ],
      ),
    );
  }

  Widget _buildPronounsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Pronouns',
          style: TextStyle(
            color: Colors.grey[300],
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _pronounsController,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: 'e.g., She/Her, They/Them, He/They',
            hintStyle: const TextStyle(color: Colors.white54),
            filled: true,
            fillColor: const Color(0xFF232428),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide.none,
            ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
          ),
        ),
        const SizedBox(height: 12),
        ElevatedButton(
          onPressed: _setPronouns,
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF5865F2),
            foregroundColor: Colors.white,
            minimumSize: const Size.fromHeight(48),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child: const Text('Save Pronouns'),
        ),
      ],
    );
  }

  Widget _buildActionButtons() {
    return Column(
      children: [
        if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) ...[
          SwitchListTile(
            title: const Text('Enable Fingerprint Login',
                style: TextStyle(color: Colors.white)),
            subtitle: const Text('Use your fingerprint for quick logins',
                style: TextStyle(color: Colors.white70)),
            value: _fingerprintEnabled,
            onChanged: _handleFingerprintSwitch,
            activeColor: const Color(0xFF5865F2),
          ),
          const SizedBox(height: 12),
        ],
        if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) ...[
          ElevatedButton.icon(
            onPressed: () async {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Checking for updates...')),
                );
                await UpdateService.checkForUpdates(context, forceCheck: true);
              }
            },
            icon: const Icon(Icons.update),
            label: const Text('Check for Updates'),
            style: ElevatedButton.styleFrom(
              foregroundColor: Colors.white,
              backgroundColor: Colors.green[600],
              minimumSize: const Size.fromHeight(48),
              textStyle: const TextStyle(fontSize: 16),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
          ),
          const SizedBox(height: 12),
        ],
        ElevatedButton.icon(
          onPressed: _logout,
          icon: const Icon(Icons.logout),
          label: const Text('Logout'),
          style: ElevatedButton.styleFrom(
            foregroundColor: Colors.white,
            backgroundColor: Colors.redAccent,
            minimumSize: const Size.fromHeight(48),
            textStyle: const TextStyle(fontSize: 16),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Profile'),
        backgroundColor: const Color(0xFF232428),
        elevation: 0.5,
      ),
      backgroundColor: const Color(0xFF313338),
      body: GestureDetector( // To dismiss keyboard on tap
        onTap: () => FocusScope.of(context).unfocus(),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildProfileHeader(),
                const SizedBox(height: 32),
                _buildPronounsSection(), // NEW
                const SizedBox(height: 24),
                const Divider(color: Colors.white24),
                const SizedBox(height: 24),
                _buildActionButtons(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}