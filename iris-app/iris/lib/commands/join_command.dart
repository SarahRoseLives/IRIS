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
    if (args.isNotEmpty && args.startsWith('#')) {
      await context.controller.joinChannel(args);
    } else {
      context.controller.chatState.addSystemMessage(
        context.controller.chatState.selectedConversationTarget,
        'Usage: /join <#channel_name>',
      );
    }
  }
}