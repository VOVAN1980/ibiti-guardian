import 'package:flutter/material.dart';

/// Native approval accepts exactly one choice, including taps in the same frame.
class DappApprovalDialog extends StatefulWidget {
  const DappApprovalDialog({
    super.key,
    required this.title,
    required this.content,
    required this.rejectLabel,
    required this.approveLabel,
  });

  final Widget title;
  final Widget content;
  final String rejectLabel;
  final String approveLabel;

  @override
  State<DappApprovalDialog> createState() => _DappApprovalDialogState();
}

class _DappApprovalDialogState extends State<DappApprovalDialog> {
  bool _decided = false;

  void _choose(bool accepted) {
    // Disabling widgets takes a frame. This synchronous latch also rejects
    // callbacks already queued before the disabled widgets are rebuilt.
    if (_decided || !mounted) return;
    setState(() => _decided = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Paint both disabled buttons before closing. A lifecycle cancellation
      // may already have dismissed this route; never pop the screen behind it.
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        Navigator.of(context).pop(accepted);
      }
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: widget.title,
        content: widget.content,
        actions: [
          TextButton(
            style: const ButtonStyle(animationDuration: Duration.zero),
            onPressed: _decided ? null : () => _choose(false),
            child: Text(widget.rejectLabel),
          ),
          FilledButton(
            style: const ButtonStyle(animationDuration: Duration.zero),
            onPressed: _decided ? null : () => _choose(true),
            child: Text(widget.approveLabel),
          ),
        ],
      );
}
