import 'dart:convert';
import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    as flutter_blue;

class ChatBluetoothService {
  // Device and characteristic state
  flutter_blue.BluetoothDevice? connectedDevice;
  flutter_blue.BluetoothCharacteristic? writeChar;
  flutter_blue.BluetoothCharacteristic? notifyChar;

  // Stream for scan results
  Stream<List<flutter_blue.ScanResult>> get scanResults =>
      flutter_blue.FlutterBluePlus.scanResults;

  // Start scanning
  Future<void> startScan() async {
    try {
      await flutter_blue.FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 5),
      );
    } catch (e) {
      print('Error starting scan: $e');
    }
  }

  // Stop scanning
  Future<void> stopScan() async {
    try {
      await flutter_blue.FlutterBluePlus.stopScan();
    } catch (e) {
      print('Error stopping scan: $e');
    }
  }

  // Connect to device
  Future<void> connect(flutter_blue.BluetoothDevice device) async {
    try {
      // Connect to the device
      await device.connect(autoConnect: false);
      connectedDevice = device;

      // Discover services
      List<flutter_blue.BluetoothService> services =
          await device.discoverServices();

      // Find write and notify characteristics
      for (var service in services) {
        for (var char in service.characteristics) {
          // Find write characteristic
          if (char.properties.write) {
            writeChar = char;
          }

          // Find notify characteristic and enable notifications
          if (char.properties.notify) {
            notifyChar = char;
            await char.setNotifyValue(true);
          }

          // Fallback: if no notify property, try read property
          if (char.properties.read && notifyChar == null) {
            notifyChar = char;
          }
        }
      }

      print('Connected and services discovered');
    } catch (e) {
      print('Error connecting to device: $e');
      rethrow;
    }
  }

  // Send message
  Future<void> sendMessage(String msg) async {
    try {
      if (writeChar == null) {
        throw Exception('Write characteristic not found');
      }
      await writeChar!.write(utf8.encode(msg), withoutResponse: false);
    } catch (e) {
      print('Error sending message: $e');
      rethrow;
    }
  }

  // Receive message stream
  Stream<String> onMessageReceived() {
    if (notifyChar == null) {
      return Stream.error('Notify characteristic not found');
    }

    return notifyChar!.onValueReceived
        .map((data) {
          try {
            return utf8.decode(data);
          } catch (e) {
            print('Error decoding message: $e');
            return '';
          }
        })
        .where((msg) => msg.isNotEmpty);
  }

  // Disconnect from device
  Future<void> disconnect() async {
    try {
      if (connectedDevice != null) {
        await connectedDevice!.disconnect();
        connectedDevice = null;
        writeChar = null;
        notifyChar = null;
      }
    } catch (e) {
      print('Error disconnecting: $e');
    }
  }
}