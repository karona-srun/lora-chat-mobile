import 'package:http/http.dart' as http;

import '../models/chat_message.dart';

class GpsMessageUtils {
  static const String fallbackMessage = 'GPS';
  static final RegExp _numberPattern = RegExp(r'\d+');

  static String previewBody(String body, {int maxLength = 200}) {
    final text = body.trim();
    if (text.length <= maxLength) return text;
    return text.substring(0, maxLength);
  }

  static String formatResponseMessage(String body) {
    final text = body.trim();
    if (text.isEmpty) return fallbackMessage;

    final gpsIndex = text.toUpperCase().indexOf('GPS');
    if (gpsIndex < 0) return text;

    final gpsPayload = text.substring(gpsIndex);
    final parts = gpsPayload
        .split(RegExp(r'[,\s]+'))
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList();
    if (parts.length < 4) return gpsPayload.trim();

    final secondTokenHasNumber = _numberPattern.hasMatch(parts[1]);
    final statusToken = secondTokenHasNumber
        ? parts[1]
        : (parts.length > 2 ? parts[2] : '');
    final coordinateOffset = secondTokenHasNumber ? 2 : 3;
    if (statusToken.isEmpty || parts.length <= coordinateOffset + 1) {
      return gpsPayload.trim();
    }

    final statusMatch = _numberPattern.firstMatch(statusToken);
    final status = statusMatch?.group(0) ?? statusToken;
    final lat = parts[coordinateOffset];
    final lng = parts[coordinateOffset + 1];

    return '$lat,$lng';
  }

  static MessageDeliveryStatus deliveryStatusFromResponse(
    http.Response response,
    String body,
  ) {
    final normalizedBody = body.toUpperCase();
    if (response.statusCode == 200) return MessageDeliveryStatus.acked;
    if (response.statusCode == 504 ||
        normalizedBody.contains('NO ACK') ||
        normalizedBody.contains('TIMEOUT')) {
      return MessageDeliveryStatus.noAck;
    }
    return MessageDeliveryStatus.failed;
  }

  static bool isDefinitiveHttpFailure(http.Response response) {
    return response.statusCode >= 400 &&
        response.statusCode < 500 &&
        response.statusCode != 408 &&
        response.statusCode != 429;
  }
}
