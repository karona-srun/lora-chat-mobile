import 'package:flutter/material.dart';
import '../models/chat_message.dart';

class ChatBubble extends StatelessWidget {
  final ChatMessage message;

  const ChatBubble({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    final isMe = message.sender == 'You';
    final isSystem = message.isSystem;
    final status = message.deliveryStatus;

    if (isSystem) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.grey[300],
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              message.text,
              style: TextStyle(
                color: Colors.grey[700],
                fontSize: 12,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        mainAxisAlignment: isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isMe) ...[
            CircleAvatar(
              radius: 16,
              backgroundColor: Theme.of(context).colorScheme.primary,
              child: Text(
                message.sender[0].toUpperCase(),
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: isMe
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.surfaceVariant,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: Radius.circular(isMe ? 16 : 4),
                  bottomRight: Radius.circular(isMe ? 4 : 16),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!isMe)
                    Text(
                      message.sender,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  if (!isMe) const SizedBox(height: 4),
                  Text(
                    message.text,
                    style: TextStyle(
                      color: isMe
                          ? Colors.white
                          : Theme.of(context).colorScheme.onSurface,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${message.timestamp.hour.toString().padLeft(2, '0')}:${message.timestamp.minute.toString().padLeft(2, '0')}',
                    style: TextStyle(
                      fontSize: 10,
                      color: isMe
                          ? Colors.white70
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (isMe && status != MessageDeliveryStatus.none) ...[
                    const SizedBox(height: 2),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _statusIcon(status),
                          size: 12,
                          color: _statusColor(context, status),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _statusText(status),
                          style: TextStyle(
                            fontSize: 10,
                            color: _statusColor(context, status),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (isMe) ...[
            const SizedBox(width: 8),
            CircleAvatar(
              radius: 16,
              backgroundColor: Theme.of(context).colorScheme.primaryContainer,
              child: const Icon(Icons.person, size: 16),
            ),
          ],
        ],
      ),
    );
  }

  IconData _statusIcon(MessageDeliveryStatus status) {
    switch (status) {
      case MessageDeliveryStatus.sending:
        return Icons.schedule;
      case MessageDeliveryStatus.acked:
        return Icons.done_all;
      case MessageDeliveryStatus.noAck:
        return Icons.warning_amber_rounded;
      case MessageDeliveryStatus.failed:
        return Icons.error_outline;
      case MessageDeliveryStatus.none:
        return Icons.check;
    }
  }

  Color _statusColor(BuildContext context, MessageDeliveryStatus status) {
    switch (status) {
      case MessageDeliveryStatus.sending:
        return Colors.white70;
      case MessageDeliveryStatus.acked:
        return Colors.white;
      case MessageDeliveryStatus.noAck:
        return Colors.amber[200] ?? Colors.amberAccent;
      case MessageDeliveryStatus.failed:
        return Colors.red[200] ?? Colors.redAccent;
      case MessageDeliveryStatus.none:
        return Theme.of(context).colorScheme.onSurfaceVariant;
    }
  }

  String _statusText(MessageDeliveryStatus status) {
    switch (status) {
      case MessageDeliveryStatus.sending:
        return 'Sending...';
      case MessageDeliveryStatus.acked:
        return 'ACK';
      case MessageDeliveryStatus.noAck:
        return 'No ACK';
      case MessageDeliveryStatus.failed:
        return 'Failed';
      case MessageDeliveryStatus.none:
        return '';
    }
  }
}

