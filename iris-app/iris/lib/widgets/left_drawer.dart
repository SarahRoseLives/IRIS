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
  final WebSocketStatus wsStatus;
  final bool showDrawer;

  const LeftDrawer({
    super.key,
    required this.dms,
    required this.channels,
    required this.selectedChannelIndex,
    required this.onChannelSelected,
    required this.loadingChannels,
    this.error,
    required this.wsStatus,
    required this.showDrawer,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      // The entire LeftDrawer (including IRIS, DMs, and Channels) animates its width.
      // Total width is 80 (for IRIS/DMs) + 200 (for Channels) = 280.
      width: showDrawer ? 280 : 0, // 280 width when shown, 0 when hidden
      duration: const Duration(milliseconds: 300), // Smooth animation duration
      curve: Curves.easeInOut, // Animation curve
      color: const Color(0xFF2B2D31), // Background color for the entire drawer
      clipBehavior: Clip.hardEdge, // Essential for clean clipping when width is 0
      alignment: Alignment.topLeft, // Align content to top-left when shrinking
      // Use LayoutBuilder to get the current constraints of the AnimatedContainer's child.
      // This allows us to conditionally render the Row based on available width.
      child: LayoutBuilder(
        builder: (context, constraints) {
          // If the current maximum width is less than 80 pixels,
          // it means the AnimatedContainer is in a state of shrinking
          // where the fixed 80px column would cause an overflow.
          // In this case, we simply return an empty Container to avoid layout errors.
          if (constraints.maxWidth < 80) {
            return Container();
          }

          // Otherwise, if there's enough space, render the full Row content.
          return Row(
            children: [
              // 1. Fixed 80px part (IRIS + DMs section)
              // This part will slide WITH the AnimatedContainer.
              Container(
                width: 80,
                color: const Color(0xFF232428), // Slightly darker background for this fixed part
                child: SafeArea( // Ensure content is within safe areas
                  child: Column( // Column to stack IRIS, Divider, and DMs vertically
                    children: [
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
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 4.0),
                        child: Divider(color: Colors.white54),
                      ),
                      Expanded( // This Expanded ensures the DM list takes available vertical space and scrolls
                        child: ListView.builder(
                          itemCount: dms.length,
                          itemBuilder: (context, idx) {
                            final dm = dms[idx];
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4.0),
                              child: CircleAvatar(
                                backgroundColor: Colors.grey[800],
                                child: Text(dm[0].toUpperCase(), // Display first letter as uppercase
                                    style: const TextStyle(color: Colors.white)),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // 2. The Channel Panel (occupies the remaining 200px of the LeftDrawer when open)
              Expanded( // ChannelPanel takes the remaining width within the LeftDrawer's AnimatedContainer
                child: ChannelPanel(
                  channels: channels,
                  selectedChannelIndex: selectedChannelIndex,
                  onChannelSelected: onChannelSelected,
                  loadingChannels: loadingChannels,
                  error: error,
                  wsStatus: wsStatus,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
