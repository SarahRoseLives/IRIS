// widgets/left_drawer.dart
import 'package:flutter/material.dart';
import '../services/websocket_service.dart';
import 'channel_panel.dart';

class LeftDrawer extends StatelessWidget {
  final List<String> dms;
  final List<String> channels;
  final int selectedChannelIndex;
  final ValueChanged<int> onChannelSelected;
  final bool loadingChannels;
  final String? error;
  final WebSocketStatus wsStatus; // Pass WebSocket status

  const LeftDrawer({
    super.key,
    required this.dms,
    required this.channels,
    required this.selectedChannelIndex,
    required this.onChannelSelected,
    required this.loadingChannels,
    this.error,
    required this.wsStatus,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 200,
      color: const Color(0xFF2B2D31),
      child: SafeArea(
        child: Column(
          children: [
            // Static DM list part
            const SizedBox(height: 20),
            const CircleAvatar(
              radius: 28,
              backgroundColor: Color(0xFF5865F2),
              child: Text(
                "IRIS",
                style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                    letterSpacing: 1.5),
              ),
            ),
            const SizedBox(height: 30),
            Expanded( // This Expanded is correct for the outer ListView
              child: ListView(
                children: [
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 4.0),
                    child: Divider(color: Colors.white54),
                  ),
                  ...dms.map(
                    (dm) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4.0),
                      child: CircleAvatar(
                        backgroundColor: Colors.grey[800],
                        child: Text(dm[0],
                            style: const TextStyle(color: Colors.white)),
                      ),
                    ),
                  ),
                  // Integrate ChannelPanel here - REMOVED THE NESTED EXPANDED
                  ChannelPanel(
                    channels: channels,
                    selectedChannelIndex: selectedChannelIndex,
                    onChannelSelected: onChannelSelected,
                    loadingChannels: loadingChannels,
                    error: error,
                    wsStatus: wsStatus,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}