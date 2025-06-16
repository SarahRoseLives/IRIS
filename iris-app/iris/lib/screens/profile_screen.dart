// lib/screens/profile_screen.dart
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart'; // For picking images from gallery/camera
import 'dart:io'; // For working with File objects
import '../services/api_service.dart';
import 'package:shared_preferences/shared_preferences.dart'; // To get the username
import 'package:http/http.dart' as http; // For checking avatar URL existence
import '../config.dart'; // For base URL

class ProfileScreen extends StatefulWidget {
  final String authToken;

  const ProfileScreen({super.key, required this.authToken});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  File? _imageFile; // The image file selected by the user
  final ApiService _apiService = ApiService(); // Instance of our API service
  bool _isUploading = false; // To show loading indicator during upload
  String? _username; // The current logged-in username
  String? _avatarUrl; // The URL of the user's current avatar

  @override
  void initState() {
    super.initState();
    _loadUserInfo(); // Load username and attempt to find existing avatar
  }

  Future<void> _loadUserInfo() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _username = prefs.getString('username');
    });
    // Once username is loaded, try to load their avatar
    _loadAvatarUrl();
  }

  Future<void> _loadAvatarUrl() async {
    if (_username != null) {
      // Define common image extensions to check
      final List<String> possibleExtensions = ['.png', '.jpg', '.jpeg', '.gif'];
      String? foundUrl;

      // Iterate through possible extensions to find an existing avatar
      for (final ext in possibleExtensions) {
        final String potentialAvatarUrl = 'http://$apiHost:$apiPort/avatars/$_username$ext';
        try {
          // Send a HEAD request to check if the file exists without downloading it
          final response = await http.head(Uri.parse(potentialAvatarUrl));
          if (response.statusCode == 200) {
            foundUrl = potentialAvatarUrl;
            break; // Found one, stop checking
          }
        } catch (e) {
          // Log error but continue trying other extensions
          print("Error checking avatar URL ($potentialAvatarUrl): $e");
        }
      }

      setState(() {
        _avatarUrl = foundUrl; // Set the found URL or null if none exist
      });
    }
  }

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    // Allow user to pick from gallery
    final pickedFile = await picker.pickImage(source: ImageSource.gallery);

    if (pickedFile != null) {
      setState(() {
        _imageFile = File(pickedFile.path); // Store the selected file
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
      _isUploading = true; // Show loading indicator
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
          _imageFile = null; // Clear the selected image preview
          // Construct the full URL for the newly uploaded avatar
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
        _isUploading = false; // Hide loading indicator
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Profile'),
        backgroundColor: const Color(0xFF232428), // Consistent AppBar color
      ),
      backgroundColor: const Color(0xFF313338), // Consistent background color
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(
              'Username: ${_username ?? 'Not available'}',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(color: Colors.white),
            ),
            const SizedBox(height: 20),
            // Display chosen image or current avatar, or a default icon
            CircleAvatar(
              radius: 80,
              backgroundColor: const Color(0xFF5865F2), // Use app primary color
              backgroundImage: _imageFile != null // If a new image is selected, show it
                  ? FileImage(_imageFile!) as ImageProvider
                  : (_avatarUrl != null // Otherwise, if an avatar URL exists, show network image
                      ? NetworkImage(_avatarUrl!)
                      : null), // Otherwise, no background image
              child: _imageFile == null && _avatarUrl == null // If neither, show a default person icon
                  ? const Icon(Icons.person, size: 80, color: Colors.white70)
                  : null,
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: _pickImage,
              icon: const Icon(Icons.image),
              label: const Text('Select Avatar Image'),
              style: ElevatedButton.styleFrom(
                foregroundColor: Colors.white, backgroundColor: const Color(0xFF5865F2), // Text and icon color
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                textStyle: const TextStyle(fontSize: 16),
              ),
            ),
            const SizedBox(height: 20),
            _isUploading
                ? const CircularProgressIndicator(color: Color(0xFF5865F2))
                : ElevatedButton.icon(
                    onPressed: _uploadAvatar,
                    icon: const Icon(Icons.upload_file),
                    label: const Text('Upload Avatar'),
                    style: ElevatedButton.styleFrom(
                      foregroundColor: Colors.white, backgroundColor: const Color(0xFF5865F2),
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                      textStyle: const TextStyle(fontSize: 16),
                    ),
                  ),
          ],
        ),
      ),
    );
  }
}