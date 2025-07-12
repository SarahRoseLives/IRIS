import 'package:iris/commands/command_context.dart';
import 'package:iris/commands/slash_command.dart';
import 'package:iris/models/irc_role.dart';

class PartCommand implements SlashCommand {
  @override
  String get name => 'part';

  @override
  String get description => 'Leaves the current or a specified channel.';

  @override
  IrcRole get requiredRole => IrcRole.user; // Available to everyone

  @override
  Future<void> execute(CommandContext context) async {
    final args = context.args;
    final controller = context.controller;
    final chatState = controller.chatState;

    // Get the network ID from the currently selected conversation.
    final selectedNetworkId = chatState.selectedChannel?.networkId ?? 0;
    final selectedNetworkName = chatState.getNetworkNameForChannel(selectedNetworkId);

    String channelToPartIdentifier;

    if (args.isNotEmpty && args.startsWith('#')) {
      // If args provided, assume it's a raw channel name for the current network
      if (selectedNetworkName.isNotEmpty && selectedNetworkName != 'Unknown Network') {
        channelToPartIdentifier = "$selectedNetworkName/$args";
      } else {
        chatState.addSystemMessage(
          selectedNetworkId,
          chatState.selectedConversationTarget,
          'Error: Could not determine current network to part from. Please select a channel first or specify network (e.g., Libera/#channel).',
        );
        return;
      }
    } else if (chatState.selectedConversationTarget.isNotEmpty) {
      channelToPartIdentifier = chatState.selectedConversationTarget;
    } else {
      chatState.addSystemMessage(
        selectedNetworkId,
        chatState.selectedConversationTarget,
        'Usage: /part [#channel_name] or select a channel.',
      );
      return;
    }

    if (channelToPartIdentifier.isNotEmpty && channelToPartIdentifier.contains('#')) {
      await controller.partChannel(channelToPartIdentifier);
    } else {
      chatState.addSystemMessage(
        selectedNetworkId, // Pass networkId
        chatState.selectedConversationTarget,
        'Usage: /part [#channel_name]',
      );
    }
  }
}