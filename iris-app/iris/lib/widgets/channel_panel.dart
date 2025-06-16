import 'package:flutter/material.dart';
import '../services/websocket_service.dart';

class ChannelPanel extends StatelessWidget {
  final List<String> channels;
  final int selectedChannelIndex;
  final ValueChanged<int> onChannelSelected;
  final bool loadingChannels;
  final String? error;
  final WebSocketStatus wsStatus;

  const ChannelPanel({
    super.key,
    required this.channels,
    required this.selectedChannelIndex,
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
              // Channels title
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
              // WebSocket status display
              Expanded(
                flex: 1,
                child: Text(
                  wsStatus.name, // Display enum name (e.g., 'connected')
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
        // Loading indicator or error message
        if (loadingChannels)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: CircularProgressIndicator(),
          )
        else if (error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(error!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
          )
        else
          // List of channels
          ListView.builder(
            // These properties are crucial for correct nested scrolling within LeftDrawer's SingleChildScrollView.
            // shrinkWrap: true makes the ListView only take up the space its children need.
            // physics: NeverScrollableScrollPhysics() prevents it from having its own scroll.
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: channels.length,
            itemBuilder: (context, idx) {
              final channel = channels[idx];
              return ListTile(
                selected: selectedChannelIndex == idx,
                selectedTileColor: const Color(0xFF5865F2),
                title: Text(channel,
                    style: TextStyle(
                      color: selectedChannelIndex == idx
                          ? Colors.white
                          : Colors.white70,
                    )),
                onTap: () => onChannelSelected(idx),
              );
            },
          ),
      ],
    );
  }
}
