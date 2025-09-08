import 'dart:convert';
import 'package:dio/dio.dart';
import 'dart:io';
import 'dart:async'; // Added for Completer and Timer

import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Establishes a WebRTC connection to the specified URI using the provided API key.
Future<ResponseWebRTC> connectWebRTC(Uri uri, String apiKey, Map<String, String>? headers) async {
  final RTCPeerConnection peerConnection = await createPeerConnection({
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
    ],
  });
  final MediaStream localStream = await navigator.mediaDevices.getUserMedia({
    'audio': true,
    'video': false,
    'mandatory': {
      'googNoiseSuppression': true, // Noise suppression
      'googEchoCancellation': true, // Echo cancellation
      'googAutoGainControl': true, // Auto gain control
      'minSampleRate': 16000, // Minimum sample rate (Hz)
      'maxSampleRate': 48000, // Maximum sample rate (Hz)
      'minBitrate': 32000, // Minimum bitrate (bps)
      'maxBitrate': 128000, // Maximum bitrate (bps)
    },
    'optional': [
      {'googHighpassFilter': true}, // High-pass filter, enhances voice quality
    ],
  });
  localStream.getTracks().forEach((track) async {
    await peerConnection.addTrack(track, localStream);
  });
  final dataChannel = await peerConnection.createDataChannel('oai-events', RTCDataChannelInit());
  final offer = await peerConnection.createOffer();
  await peerConnection.setLocalDescription(offer);

  try {
    final client = HttpClient();
    final request = await client.postUrl(uri);

    // Set request headers
    request.headers.set('Authorization', 'Bearer $apiKey');
    request.headers.set('Content-Type', 'application/sdp');

    request.write(offer.sdp);

    final response = await request.close();
    final responseBody = await response.transform(utf8.decoder).join();
    if (responseBody.isNotEmpty) {
      final remoteDescription = RTCSessionDescription(responseBody, 'answer');
      await peerConnection.setRemoteDescription(remoteDescription);
      return ResponseWebRTC(peerConnection: peerConnection, dataChannel: dataChannel);
    } else {
      throw Exception('Failed to send SDP to server - empty response');
    }
  } catch (e) {
    throw Exception('Failed to send SDP to server: $e');
  }
}

/// Response object containing WebRTC connection components.
class ResponseWebRTC {
  /// The WebRTC peer connection for real-time communication.
  final RTCPeerConnection peerConnection;

  /// The data channel for sending and receiving data.
  final RTCDataChannel dataChannel;

  /// Creates a new [ResponseWebRTC] with the specified peer connection and data channel.
  ResponseWebRTC({required this.peerConnection, required this.dataChannel});

  /// Waits for the peer connection to be established and data channel to be open.
  Future<void> waitUntilReady({Duration timeout = const Duration(seconds: 30)}) async {
    await Future.wait([
      _waitForPeerConnectionReady(timeout),
      _waitForDataChannelReady(timeout),
    ]);
  }

  /// Waits for the peer connection to reach 'connected' state.
  Future<void> _waitForPeerConnectionReady(Duration timeout) async {
    if (peerConnection.connectionState == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
      return;
    }

    final completer = Completer<void>();
    Timer? timeoutTimer;

    void onConnectionStateChange(RTCPeerConnectionState state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        timeoutTimer?.cancel();
        if (!completer.isCompleted) {
          completer.complete();
        }
      }
    }

    peerConnection.onConnectionState = onConnectionStateChange;

    timeoutTimer = Timer(timeout, () {
      if (!completer.isCompleted) {
        completer.completeError(TimeoutException('Peer connection timeout', timeout));
      }
    });

    return completer.future;
  }

  /// Waits for the data channel to reach 'open' state.
  Future<void> _waitForDataChannelReady(Duration timeout) async {
    if (dataChannel.state == RTCDataChannelState.RTCDataChannelOpen) {
      return;
    }

    final completer = Completer<void>();
    Timer? timeoutTimer;

    void onDataChannelStateChange(RTCDataChannelState state) {
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        timeoutTimer?.cancel();
        if (!completer.isCompleted) {
          completer.complete();
        }
      }
    }

    dataChannel.onDataChannelState = onDataChannelStateChange;

    timeoutTimer = Timer(timeout, () {
      if (!completer.isCompleted) {
        completer.completeError(TimeoutException('Data channel timeout', timeout));
      }
    });

    return completer.future;
  }
}

/// Retrieves an ephemeral key for the specified API key.
Future<String> getEphemeralKey(String apiKey, String model) async {
  try {
    final url = Uri.parse('https://api.openai.com/v1/realtime/sessions');
    final body = jsonEncode({
      "model": model,
      "voice": "verse",
    });
    final dio = Dio();
    dio.options.headers['Authorization'] = 'Bearer $apiKey';
    dio.options.headers['Content-Type'] = 'application/json';
    final response = await dio.post<Map<String, dynamic>>(url.toString(), data: body);
    if (response.statusCode == 200) {
      final jsonResponse = response.data;
      if (jsonResponse?["client_secret"]["value"] == null) {
        throw Exception('Failed to get ephemeral key: ${jsonResponse?['error']}');
      }
      return jsonResponse!["client_secret"]["value"];
    }
    throw Exception('Failed to get ephemeral key: ${response.statusCode}');
  } catch (e) {
    return throw Exception('Failed to get ephemeral key: $e');
  }
}
