// widgets/channel_panel.dart
import 'package:flutter/material.dart';
import '../services/websocket_service.dart';

class ChannelPanel extends StatelessWidget {
  final List<String> channels;
  final String selectedConversationTarget;
  final ValueChanged<String> onChannelSelected;
  final bool loadingChannels;
  final String? error;
  final WebSocketStatus wsStatus;

  const ChannelPanel({
    super.key,
    required this.channels,
    required this.selectedConversationTarget,
    required this.onChannelSelected,
    required this.loadingChannels,
    this.error,
    required this.wsStatus,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Expanded(
                flex: 2,
                child: Text(
                  "Channels",
                  style: TextStyle(
                      color: Colors.white60,
                      fontWeight: FontWeight.bold,
                      fontSize: 22),
                ),
              ),
              Expanded( // FIX: Removed stray '_'
                flex: 1,
                child: Text(
                  wsStatus.name,
                  textAlign: TextAlign.right,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: wsStatus == WebSocketStatus.connected
                        ? Colors.greenAccent
                        : Colors.redAccent,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (loadingChannels)
          const Center(child: Padding(
            padding: EdgeInsets.all(8.0),
            child: CircularProgressIndicator(strokeWidth: 2),
          ))
        else if (error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(error!, style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
          )
        else
          Expanded(
              child: ListView.builder(
                padding: EdgeInsets.zero,
                itemCount: channels.length,
                itemBuilder: (context, idx) {
                  final channel = channels[idx];
                  final isSelected = selectedConversationTarget.toLowerCase() == channel.toLowerCase();
                  return ListTile(
                    selected: isSelected,
                    selectedTileColor: const Color(0xFF5865F2),
                    title: Text(channel, // FIX: Removed stray '_'
                        style: TextStyle(
                          color: isSelected ? Colors.white : Colors.white70,
                          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                        )),
                    onTap: () => onChannelSelected(channel),
                  );
                },
              ),
            ),
      ],
    );
  }
}