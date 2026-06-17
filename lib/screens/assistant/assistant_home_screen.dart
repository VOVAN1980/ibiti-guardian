import 'package:flutter/material.dart';
import 'package:ibiti_guardian/screens/assistant/components/assistant_voice_screen.dart';
import 'package:ibiti_guardian/screens/assistant/components/assistant_chat_screen.dart';

enum AssistantViewMode { voice, chat }

class AssistantHomeScreen extends StatefulWidget {
  final AssistantViewMode initialMode;

  const AssistantHomeScreen({
    super.key,
    this.initialMode = AssistantViewMode.voice,
  });

  @override
  State<AssistantHomeScreen> createState() => _AssistantHomeScreenState();
}

class _AssistantHomeScreenState extends State<AssistantHomeScreen> {
  late AssistantViewMode _mode;

  @override
  void initState() {
    super.initState();
    _mode = widget.initialMode;
  }

  // Allow dynamic switching if needed externally, but normally tabs handle it
  void switchToChat() {
    if (mounted) setState(() => _mode = AssistantViewMode.chat);
  }

  void switchToVoice() {
    if (mounted) setState(() => _mode = AssistantViewMode.voice);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 400),
      transitionBuilder: (Widget child, Animation<double> animation) {
        return FadeTransition(
          opacity: animation,
          child: child,
        );
      },
      child: _mode == AssistantViewMode.voice
          ? AssistantVoiceScreen(
              key: const ValueKey('voice'), onOpenChat: switchToChat)
          : AssistantChatScreen(
              key: const ValueKey('chat'), onOpenVoice: switchToVoice),
    );
  }
}
