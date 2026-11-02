import 'dart:async';
import 'dart:collection';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// MaglisRemoteParticipant
///
/// Models a remote participant in the room session.
/// Directly mirrors the LiveKit Flutter Client SDK participant structure
/// and noscall session state.
class MaglisRemoteParticipant {
  final String identity; // Peer public/session identifier
  RTCIceConnectionState _iceState;
  bool isDataChannelOpen;
  int lastSeenMs;
  int latencyMs;

  MaglisRemoteParticipant({
    required this.identity,
    RTCIceConnectionState iceState =
        RTCIceConnectionState.RTCIceConnectionStateNew,
    this.isDataChannelOpen = false,
    int? lastSeenMs,
    this.latencyMs = 0,
  })  : _iceState = iceState,
        lastSeenMs = lastSeenMs ?? DateTime.now().millisecondsSinceEpoch;

  RTCIceConnectionState get iceState => _iceState;

  set iceState(RTCIceConnectionState value) {
    _iceState = value;
    if (value == RTCIceConnectionState.RTCIceConnectionStateFailed ||
        value == RTCIceConnectionState.RTCIceConnectionStateClosed) {
      isDataChannelOpen = false;
    }
  }

  bool get isConnected {
    if (_iceState == RTCIceConnectionState.RTCIceConnectionStateFailed ||
        _iceState == RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
        _iceState == RTCIceConnectionState.RTCIceConnectionStateClosed) {
      return false;
    }
    return _iceState == RTCIceConnectionState.RTCIceConnectionStateConnected ||
        _iceState == RTCIceConnectionState.RTCIceConnectionStateCompleted ||
        isDataChannelOpen;
  }
}

/// ParticipantCollection
///
/// Line-for-line port of LiveKit's ParticipantCollection.
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
/// Line-for-line port of noscall's CallingIceStateHandler.
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