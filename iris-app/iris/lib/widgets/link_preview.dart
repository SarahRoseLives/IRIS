import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

class LinkPreview extends StatelessWidget {
  final String url;

  const LinkPreview({super.key, required this.url});

  @override
  Widget build(BuildContext context) {
    final Uri uri = Uri.parse(url);
    final bool isYouTube = uri.host.contains('youtube.com') || uri.host.contains('youtu.be');

    if (isYouTube) {
      final videoId = _extractYouTubeId(uri);
      if (videoId != null) {
        return GestureDetector(
          onTap: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
          child: Container(
            margin: const EdgeInsets.only(top: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: Colors.black,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Image.network('https://img.youtube.com/vi/$videoId/0.jpg'),
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Text(
                    'YouTube Video',
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
        );
      }
    }

    // fallback basic preview
    return GestureDetector(
      onTap: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
      child: Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.grey[850],
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(url, style: const TextStyle(color: Colors.blueAccent)),
      ),
    );
  }

  String? _extractYouTubeId(Uri uri) {
    if (uri.host.contains('youtu.be')) {
      return uri.pathSegments.isNotEmpty ? uri.pathSegments[0] : null;
    } else if (uri.queryParameters.containsKey('v')) {
      return uri.queryParameters['v'];
    }
    return null;
  }
}
