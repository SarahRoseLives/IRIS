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

    String channelToPart =
        args.isNotEmpty ? args : chatState.selectedConversationTarget;

    if (channelToPart.isNotEmpty && channelToPart.startsWith('#')) {
      await controller.partChannel(channelToPart);
    } else {
      chatState.addSystemMessage(
        chatState.selectedConversationTarget,
        'Usage: /part [#channel_name]',
      );
    }
  }
}