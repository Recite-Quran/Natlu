import 'dart:async';
import 'dart:collection';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// MaglisRemoteParticipant
///
/// Models a remote participant in the room session.
/// Directly mirrors the LiveKit Flutter Client SDK participant structure
/// (from C:\Users\redaa\Downloads\client-sdk-flutter\lib\src\participant\participant.dart)
/// and noscall session state (from C:\Users\redaa\Downloads\noscall\lib\call\calling_controller.dart).
class MaglisRemoteParticipant {
  final String identity; // Peer public/session identifier
  RTCIceConnectionState iceState;
  bool isDataChannelOpen;
  int lastSeenMs;
  int latencyMs;

  MaglisRemoteParticipant({
    required this.identity,
    this.iceState = RTCIceConnectionState.RTCIceConnectionStateNew,
    this.isDataChannelOpen = false,
    int? lastSeenMs,
    this.latencyMs = 0,
  }) : lastSeenMs = lastSeenMs ?? DateTime.now().millisecondsSinceEpoch;

  bool get isConnected =>
      iceState == RTCIceConnectionState.RTCIceConnectionStateConnected ||
      iceState == RTCIceConnectionState.RTCIceConnectionStateCompleted ||
      isDataChannelOpen;
}

/// ParticipantCollection
///
/// Line-for-line port of LiveKit's ParticipantCollection
/// (from C:\Users\redaa\Downloads\client-sdk-flutter\lib\src\core\participant_collection.dart).
/// Provides a single, deterministic source of truth for all room participants.
class ParticipantCollection extends IterableBase<MaglisRemoteParticipant> {
  final Map<String, MaglisRemoteParticipant> _byIdentity = {};

  UnmodifiableMapView<String, MaglisRemoteParticipant> get byIdentity =>
      UnmodifiableMapView(_byIdentity);

  List<String> get identities => _byIdentity.keys.toList();

  /// Updates or inserts a participant. Returns true if newly added.
  bool set(MaglisRemoteParticipant participant) {
    final isNew = !_byIdentity.containsKey(participant.identity);
    _byIdentity[participant.identity] = participant;
    return isNew;
  }

  bool containsIdentity(String identity) => _byIdentity.containsKey(identity);

  MaglisRemoteParticipant? get(String identity) => _byIdentity[identity];

  void clear() {
    _byIdentity.clear();
  }

  MaglisRemoteParticipant? removeByIdentity(String identity) {
    return _byIdentity.remove(identity);
  }

  @override
  Iterator<MaglisRemoteParticipant> get iterator => _byIdentity.values.iterator;

  @override
  int get length => _byIdentity.length;
}

/// CallingIceStateHandler
///
/// Line-for-line port of noscall's CallingIceStateHandler
/// (from C:\Users\redaa\Downloads\noscall\lib\call\calling_ice_state_handler.dart).
typedef CallingIceConnected = FutureOr<void> Function();
typedef CallingIceHangup = FutureOr<void> Function();

class CallingIceStateHandler {
  const CallingIceStateHandler();

  Future<void> handle(
    RTCIceConnectionState connectionState, {
    required CallingIceConnected onConnected,
    required CallingIceHangup onHangup,
  }) async {
    switch (connectionState) {
      case RTCIceConnectionState.RTCIceConnectionStateConnected:
      case RTCIceConnectionState.RTCIceConnectionStateCompleted:
        await onConnected();
        break;
      case RTCIceConnectionState.RTCIceConnectionStateFailed:
      case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
        await onHangup();
        break;
      default:
        break;
    }
  }
}

