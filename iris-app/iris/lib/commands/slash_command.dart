import '../models/irc_role.dart';
import 'command_context.dart';

abstract class SlashCommand {
  /// The name of the command (e.g., 'join').
  String get name;

  /// The description shown in autocomplete suggestions.
  String get description;

  /// The minimum role required to execute this command.
  IrcRole get requiredRole;

  /// The function that runs when the command is executed.
  Future<void> execute(CommandContext context);
}