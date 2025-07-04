import 'dart:math';

class Motd {
  static final List<String> _messages = [
    "Welcome to IRIS — where your chat is yours.",
    "You are valid. You are seen. You belong here.",
    "Trans joy is real, and so is your strength.",
    "This server runs on love, queerness, and open protocols.",
    "Take a deep breath — you made it here, and that matters.",
    "Your voice matters. Your story matters. You matter.",
    "No identity policing. No gatekeeping. Just connection.",
    "Every day is a chance to start again — with kindness.",
    "Chosen family is real family. We're glad you're here.",
    "You’re not alone — someone out there gets it.",
    "There’s pride in resilience. There’s power in softness.",
    "It’s okay to log off. We’ll be here when you’re ready.",
    "Your presence is enough. You don’t have to earn it.",
    "IRIS: A rainbow in a gray sky, a message that you’re not forgotten.",
    "If the world feels heavy, let IRIS help carry a little of it.",
    "Some days are hard — that doesn’t make you any less amazing.",
    "You are not a burden. You are a light.",
    "You don’t have to be ‘on’ to be welcome here.",
    "This is your space too — come as you are.",
    "You survived more than most — and still offer love. That’s strength.",
    "You deserve safety, joy, and space to breathe.",
    "This is queer tech for queer lives. You’re part of that legacy.",
    "IRIS is more than software. It’s a soft place to land.",
    "Rainbows are made from storms and sunlight — and so are we.",
  ];

  static String random() {
    final random = Random();
    return _messages[random.nextInt(_messages.length)];
  }
}