import 'package:iris/viewmodels/chat_controller.dart';
import '../models/irc_role.dart';

class CommandContext {
  final ChatController controller;
  final String args;
  final IrcRole userRole;

  CommandContext({
    required this.controller,
    required this.args,
    required this.userRole,
  });
}