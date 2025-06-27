import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../viewmodels/main_layout_viewmodel.dart';
import '../models/channel.dart';

class ChannelTopic extends StatelessWidget {
  const ChannelTopic({super.key});

  void _showEditTopicDialog(BuildContext context, String currentTopic) {
    final viewModel = Provider.of<MainLayoutViewModel>(context, listen: false);
    final controller = TextEditingController(text: currentTopic);

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Edit Channel Topic'),
          content: TextField(
            controller: controller,
            maxLines: 3,
            decoration: const InputDecoration(
              hintText: 'Enter new topic...',
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              child: const Text('Cancel'),
              onPressed: () => Navigator.pop(context),
            ),
            TextButton(
              child: const Text('Save'),
              onPressed: () {
                final newTopic = controller.text.trim();
                viewModel.updateChannelTopic(newTopic);
                Navigator.pop(context);
              },
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final viewModel = Provider.of<MainLayoutViewModel>(context);
    final channel = viewModel.chatState.channels.firstWhere(
      (c) => c.name == viewModel.selectedConversationTarget,
      orElse: () => Channel(name: '', members: []),
    );

    final isOperator = viewModel.members.any((m) =>
      m.nick == viewModel.username &&
      ['~', '&', '@'].contains(m.prefix)
    );

    return GestureDetector(
      onTap: isOperator && !channel.name.startsWith('@')
          ? () => _showEditTopicDialog(context, channel.topic)
          : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF232428),
          border: Border(
            bottom: BorderSide(color: Colors.grey.shade800, width: 1),
          ),
        ),
        child: Row(
          children: [
            const Icon(Icons.info_outline, size: 18, color: Colors.white70),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                channel.topic.isNotEmpty
                    ? channel.topic
                    : 'No topic set${isOperator ? ' - tap to set' : ''}',
                style: const TextStyle(color: Colors.white70, fontSize: 14),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (isOperator && !channel.name.startsWith('@'))
              const Icon(Icons.edit, size: 16, color: Colors.white54),
          ],
        ),
      ),
    );
  }
}