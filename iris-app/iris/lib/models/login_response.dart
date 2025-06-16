// lib/models/login_response.dart
class LoginResponse {
  final bool success;
  final String message;
  final String? token; // This will hold the authentication token

  LoginResponse({
    required this.success,
    required this.message,
    this.token,
  });

  factory LoginResponse.fromJson(Map<String, dynamic> json) {
    return LoginResponse(
      success: json['success'] as bool,
      message: json['message'] as String,
      token: json['token'] as String?, // Token is optional/nullable
    );
  }
}