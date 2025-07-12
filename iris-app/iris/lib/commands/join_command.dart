import 'package:iris/commands/command_context.dart';
import 'package:iris/commands/slash_command.dart';
import 'package:iris/models/irc_role.dart';

class JoinCommand implements SlashCommand {
  @override
  String get name => 'join';

  @override
  String get description => 'Joins a specified channel.';

  @override
  IrcRole get requiredRole => IrcRole.user; // Available to everyone

  @override
  Future<void> execute(CommandContext context) async {
    final args = context.args;
    // Get the network ID from the currently selected conversation.
    final selectedNetworkId = context.controller.chatState.selectedChannel?.networkId ?? 0;

    if (args.isNotEmpty && args.startsWith('#')) {
      // The joinChannel in ChatController will handle parsing network/channel or
      // using the default for join commands if no network is explicitly passed.
      // We need to provide the network prefix for the channel identifier.
      // For simplicity, we'll try to find the network name for the selected ID.
      final selectedNetworkName = context.controller.chatState.getNetworkNameForChannel(selectedNetworkId);
      if (selectedNetworkName.isNotEmpty && selectedNetworkName != 'Unknown Network') {
        await context.controller.joinChannel("$selectedNetworkName/$args");
      } else {
        context.controller.chatState.addSystemMessage(
          selectedNetworkId,
          context.controller.chatState.selectedConversationTarget,
          'Error: Could not determine current network to join. Please specify network (e.g., Libera/#channel).',
        );
      }
    } else {
      context.controller.chatState.addSystemMessage(
        selectedNetworkId, // Pass networkId
        context.controller.chatState.selectedConversationTarget,
        'Usage: /join <#channel_name>',
      );
    }
  }
}