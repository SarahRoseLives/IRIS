import 'package:flutter/material.dart';

class RightDrawer extends StatelessWidget {
  final List<String> members;

  const RightDrawer({
    super.key,
    required this.members,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 200,
      color: const Color(0xFF2B2D31),
      child: SafeArea(
        child: Column(
          children: [
            const ListTile(
              title: Text(
                "Members",
                style: TextStyle(
                    color: Color(0xFF5865F2),
                    fontWeight: FontWeight.bold,
                    fontSize: 22),
              ),
            ),
            Expanded( // Wrap ListView.builder with Expanded
              child: ListView.builder(
                itemCount: members.length,
                itemBuilder: (context, idx) {
                  final m = members[idx];
                  return ListTile(
                    leading: CircleAvatar(child: Text(m[0])),
                    title: Text(m, style: const TextStyle(color: Colors.white)),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}