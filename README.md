# ESP32-S3 RF24 Peer-to-Peer Chat

A Flutter mobile application for communicating with ESP32-S3 nodes using RF24 (nRF24L01) radio modules in a peer-to-peer mesh network.

## Overview

This Flutter app provides a mobile interface for the ESP32-S3 RF24 2-Node Peer-to-Peer Chat system. The app connects to ESP32-S3 devices via WiFi and enables real-time messaging over the RF24 mesh network.

### Features

- **Peer-to-Peer Communication**: Direct node-to-node messaging without a master node
- **WiFi Connection**: Connect to ESP32-S3 devices via WiFi Access Point
- **Real-time Messaging**: Send and receive messages with automatic polling
- **Channel Management**: Organize conversations by channels and direct messages
- **Connection Management**: Easy WiFi/Bluetooth device connection setup

## Hardware Requirements

### ESP32-S3 Node Setup

- **ESP32-S3** development board
- **nRF24L01** RF24 radio module
- **SSD1306 OLED** display (128x64)
- **Wiring**:
  - CE Pin: GPIO 7
  - CSN Pin: GPIO 6
  - OLED SDA: GPIO 8
  - OLED SCL: GPIO 9

### Arduino Code Configuration

```cpp
#define NODE_ID 2          // Set 1 or 2 for each node
#define CE_PIN 7
#define CSN_PIN 6
#define OLED_SDA 8
#define OLED_SCL 9
```

## Network Protocol

### WiFi Access Point

Each ESP32-S3 node creates a WiFi Access Point:
- **SSID**: `RF24-Node-{NODE_ID}` (e.g., `RF24-Node-1`, `RF24-Node-2`)
- **Password**: `12345678`
- **Default IP**: `192.168.4.1`
- **Port**: `80`

### API Endpoints

#### Send Message
- **Method**: `POST`
- **Endpoint**: `/send`
- **Content-Type**: `application/x-www-form-urlencoded`
- **Body**: `m=<message_text>`
- **Response**: `OK` (plain text)

#### Get Chat Log
- **Method**: `GET`
- **Endpoint**: `/chat`
- **Response**: Plain text with messages in format `"Node X: message text\n"`

### Message Format

Messages are transmitted in the following format:
```
Node {NODE_ID}: {message_text}
```

## Flutter App Usage

### Connection Setup

1. **Connect to WiFi**: 
   - Go to Settings → WiFi on your device
   - Connect to `RF24-Node-1` or `RF24-Node-2`
   - Enter password: `12345678`

2. **Connect via App**:
   - Open the app
   - Navigate to the **Connect** tab
   - Tap **Manual** button
   - Select **Connect via WiFi**
   - Enter IP address: `192.168.4.1` (default)
   - Enter Port: `80` (default)
   - Tap **Connect**

### Sending Messages

1. Navigate to **Messages** tab
2. Select **Channels** or **Direct Messages**
3. Open a chat conversation
4. Type your message and tap the send button
5. Messages are sent via POST request to the ESP32-S3 node

### Receiving Messages

- Messages are automatically polled every 500ms
- New messages appear in real-time
- Messages from other nodes are displayed with sender information

## Project Structure

```
lib/
├── main.dart                    # App entry point & navigation
├── models/
│   └── chat_message.dart       # Chat message data model
├── screens/
│   ├── channel_screen.dart     # Messages, Channels & Chat screens
│   ├── connect_screen.dart     # Device connection management
│   └── settings_screen.dart    # App settings
└── widgets/
    └── chat_bubble.dart        # Chat message bubble widget
```

## Dependencies

- `flutter`: SDK
- `http: ^1.1.0`: HTTP client for API communication
- `cupertino_icons: ^1.0.8`: iOS-style icons

## Getting Started

1. **Clone the repository**
   ```bash
   git clone <repository-url>
   cd app
   ```

2. **Install dependencies**
   ```bash
   flutter pub get
   ```

3. **Run the app**
   ```bash
   flutter run
   ```

## Arduino Code Setup

1. Upload the ESP32-S3 RF24 code to your device
2. Set `NODE_ID` to 1 or 2 for each node
3. Power on the ESP32-S3 device
4. Connect to the WiFi Access Point created by the device
5. Use the Flutter app to connect and start chatting

## Technical Details

### E22-900T33S Communication

- **Protocol**: E22-900T33S 915Mhz radio
- **Data Rate**: 1 Mbps
- **Power Level**: Low (RF24_PA_LOW)
- **Pipes**: 
  - Node 1: Writing `0xF0F0F0F0E1`, Reading `0xF0F0F0F0D2`
  - Node 2: Writing `0xF0F0F0F0D2`, Reading `0xF0F0F0F0E1`

### Message Flow

1. User sends message via Flutter app
2. App sends POST request to ESP32-S3 `/send` endpoint
3. ESP32-S3 transmits message via RF24 to peer node
4. Peer node receives message and adds to chat log
5. Flutter app polls `/chat` endpoint every 500ms
6. New messages are displayed in the chat interface

## Troubleshooting

- **Connection Issues**: Ensure device is connected to the ESP32-S3 WiFi network
- **Messages Not Sending**: Check IP address and port settings
- **Messages Not Receiving**: Verify RF24 radio modules are properly configured
- **Polling Errors**: Check network connectivity and device status

## License

This project is open source and available for modification and distribution.
