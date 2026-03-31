class ChatMessage {
  final String text;
  final String sender;
  final DateTime timestamp;
  final bool isSystem;
  final MessageDeliveryStatus deliveryStatus;

  ChatMessage({
    required this.text,
    required this.sender,
    required this.timestamp,
    this.isSystem = false,
    this.deliveryStatus = MessageDeliveryStatus.none,
  });

  ChatMessage copyWith({
    String? text,
    String? sender,
    DateTime? timestamp,
    bool? isSystem,
    MessageDeliveryStatus? deliveryStatus,
  }) {
    return ChatMessage(
      text: text ?? this.text,
      sender: sender ?? this.sender,
      timestamp: timestamp ?? this.timestamp,
      isSystem: isSystem ?? this.isSystem,
      deliveryStatus: deliveryStatus ?? this.deliveryStatus,
    );
  }
}

enum MessageDeliveryStatus { none, sending, acked, noAck, failed }

