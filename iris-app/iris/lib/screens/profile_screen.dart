import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import '../services/api_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import '../config.dart';
import 'package:iris/services/update_service.dart';

class ProfileScreen extends StatefulWidget {
  final String authToken;

  const ProfileScreen({super.key, required this.authToken});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  File? _imageFile;
  final ApiService _apiService = ApiService();
  bool _isUploading = false;
  String? _username;
  String? _avatarUrl;
  String? _bio; // Optionally load bio in the future

  @override
  void initState() {
    super.initState();
    _loadUserInfo();
  }

  Future<void> _loadUserInfo() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _username = prefs.getString('username');
      _bio = prefs.getString('bio'); // If you want to add a bio field
    });
    _loadAvatarUrl();
  }

  Future<void> _loadAvatarUrl() async {
    if (_username != null) {
      final List<String> possibleExtensions = ['.png', '.jpg', '.jpeg', '.gif'];
      String? foundUrl;

      for (final ext in possibleExtensions) {
        final String potentialAvatarUrl = 'http://$apiHost:$apiPort/avatars/$_username$ext';
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

      setState(() {
        _avatarUrl = foundUrl;
      });
    }
  }

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: ImageSource.gallery);

    if (pickedFile != null) {
      setState(() {
        _imageFile = File(pickedFile.path);
      });
    }
  }

  Future<void> _uploadAvatar() async {
    if (_imageFile == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select an image first.')),
      );
      return;
    }

    setState(() {
      _isUploading = true;
    });

    try {
      final response = await _apiService.uploadAvatar(_imageFile!, widget.authToken);
      if (response['success'] == true) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(response['message'] ?? 'Avatar uploaded successfully!')),
          );
        }
        setState(() {
          _imageFile = null;
          _avatarUrl = response['avatarUrl'] != null
              ? 'http://$apiHost:$apiPort${response['avatarUrl']}'
              : null;
        });
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(response['message'] ?? 'Failed to upload avatar.')),
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
      setState(() {
        _isUploading = false;
      });
    }
  }

  Widget _buildProfileHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 18),
      decoration: BoxDecoration(
        color: const Color(0xFF232428),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          // Avatar with edit overlay
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
                    icon: const Icon(Icons.camera_alt, color: Colors.white, size: 20),
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
          // Username and bio/info
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _username ?? 'Not available',
                  style: const TextStyle(
                    fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white),
                ),
                const SizedBox(height: 4),
                Text(
                  _bio ?? "No bio set.",
                  style: TextStyle(color: Colors.grey[400], fontSize: 15),
                  maxLines: 2, overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAvatarActionButtons() {
    if (_imageFile == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.start,
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
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
              child: CircularProgressIndicator(color: Color(0xFF5865F2), strokeWidth: 3),
            ),
        ],
      ),
    );
  }

  Widget _buildActionButtons() {
    return Column(
      children: [
        ElevatedButton.icon(
          onPressed: _pickImage,
          icon: const Icon(Icons.image),
          label: const Text('Select Avatar Image'),
          style: ElevatedButton.styleFrom(
            foregroundColor: Colors.white,
            backgroundColor: const Color(0xFF5865F2),
            minimumSize: const Size.fromHeight(48),
            textStyle: const TextStyle(fontSize: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
        const SizedBox(height: 12),
        ElevatedButton.icon(
          onPressed: () async {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Checking for updates...')),
            );
            await UpdateService.checkForUpdates(context, forceCheck: true);
          },
          icon: const Icon(Icons.update),
          label: const Text('Check for Updates'),
          style: ElevatedButton.styleFrom(
            foregroundColor: Colors.white,
            backgroundColor: Colors.green[600],
            minimumSize: const Size.fromHeight(48),
            textStyle: const TextStyle(fontSize: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildProfileHeader(),
              _buildAvatarActionButtons(),
              const SizedBox(height: 38),
              _buildActionButtons(),
            ],
          ),
        ),
      ),
    );
  }
}