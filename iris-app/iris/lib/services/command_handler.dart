import 'package:iris/commands/join_command.dart';
import 'package:iris/commands/part_command.dart';
import 'package:iris/commands/slash_command.dart';
import 'package:iris/models/irc_role.dart';
import 'package:iris/controllers/chat_controller.dart';
import 'package:iris/commands/command_context.dart';

class CommandHandler {
  final Map<String, SlashCommand> _commands = {};

  void registerCommands() {
    final commandList = [
      JoinCommand(),
      PartCommand(),
      // To add a new op-only command, you would just add it here:
      // KickCommand(),
    ];

    for (final command in commandList) {
      _commands[command.name.toLowerCase()] = command;
    }
  }

  /// This will be used for the autocomplete UI.
  List<SlashCommand> getAvailableCommandsForRole(IrcRole userRole) {
    return _commands.values
        .where((cmd) => userRole.index >= cmd.requiredRole.index)
        .toList();
  }

  Future<void> handleCommand(
      String commandText, ChatController controller) async {
    final parts = commandText.substring(1).split(' ');
    final commandName = parts[0].toLowerCase();
    final args = parts.skip(1).join(' ').trim();

    final command = _commands[commandName];
    final chatState = controller.chatState;
    final currentChannel = chatState.selectedConversationTarget;

    // Get the networkId for the current conversation target using the selectedChannel getter
    final currentNetworkId = chatState.selectedChannel?.networkId ?? 0;

    if (command == null) {
      chatState.addSystemMessage(
        currentNetworkId, // Pass networkId
        currentChannel,
        'Unknown command: /$commandName',
      );
      return;
    }

    final userRole = controller.getCurrentUserRoleInChannel(currentChannel);

    // Check if the user's role index is >= the required role's index.
    // This works because the IrcRole enum is ordered from least to most privileged.
    if (userRole.index >= command.requiredRole.index) {
      final context = CommandContext(
        controller: controller,
        args: args,
        userRole: userRole,
      );
      await command.execute(context);
    } else {
      chatState.addSystemMessage(
        currentNetworkId, // Pass networkId
        currentChannel,
        "You do not have permission to use the '/$commandName' command.",
      );
    }
  }
}