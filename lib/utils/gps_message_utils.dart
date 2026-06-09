import 'package:http/http.dart' as http;

import '../models/chat_message.dart';

class GpsMessageUtils {
  static const String fallbackMessage = 'GPS';
  static final RegExp _gpsPayloadPattern = RegExp(
    r'GPS\s*,\s*[^,]*\s*,\s*[^,]*\s*,\s*([+-]?(?:\d+(?:\.\d*)?|\.\d+))\s*,\s*([+-]?(?:\d+(?:\.\d*)?|\.\d+))',
    caseSensitive: false,
  );

  static String previewBody(String body, {int maxLength = 200}) {
    final text = body.trim().replaceAll("OK (ACK) ", "").replaceAll("Timeout waiting ACK -", "");
    if (text.length <= maxLength) return text;
    return text.substring(0, maxLength);
  }

  static String formatResponseMessage(String body) {
    final text = body.trim().replaceAll("OK (ACK) ", "").replaceAll("Timeout waiting ACK -", "") ;
    if (text.isEmpty) return fallbackMessage;

    final match = _gpsPayloadPattern.firstMatch(text);
    if (match != null) {
      final lat = match.group(1)?.trim() ?? '';
      final lng = match.group(2)?.trim() ?? '';
      if (lat.isNotEmpty && lng.isNotEmpty) return '$lat,$lng';
    }

    final gpsIndex = text.toUpperCase().indexOf('GPS');
    if (gpsIndex < 0) return text;

    return text.substring(gpsIndex).trim();
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
