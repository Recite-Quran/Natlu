package com.recitequran.app

import android.os.Handler
import android.os.Looper
import com.cloudwebrtc.webrtc.FlutterWebRTCPlugin
import com.cloudwebrtc.webrtc.audio.LocalAudioTrack
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.webrtc.AudioTrackSink
import java.nio.ByteBuffer
import kotlin.math.roundToInt

/**
 * Lightweight single-capture WebRTC audio tap for Android Maglis mode.
 *
 * Attaches an [AudioTrackSink] to the active WebRTC [LocalAudioTrack] so Sherpa
 * ASR receives clean Channel-0 PCM from WebRTC's single hardware AudioRecord
 * before WebRTC software AEC/AGC runs—eliminating dual-AudioRecord contention
 * without altering Maglis call audio.
 */
class MaglisAudioTap(messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {

    companion object {
        private const val METHOD_CHANNEL = "com.recitequran.app/maglis_audio_tap"
        private const val STREAM_CHANNEL = "com.recitequran.app/maglis_audio_tap_stream"
        private const val TARGET_RATE = 16000
        private const val CHUNK_BYTES = 15360 // 7680 samples * 2 bytes (480ms @ 16kHz)
    }

    private val methodChannel = MethodChannel(messenger, METHOD_CHANNEL)
    private val streamChannel = EventChannel(messenger, STREAM_CHANNEL)
    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    private var eventSink: EventChannel.EventSink? = null

    @Volatile
    private var isTapping = false
    private var attachedTrack: LocalAudioTrack? = null

    private val tapLock = Any()
    private val outChunk = ByteArray(CHUNK_BYTES)
    private var outBytes = 0

    // Resampler state guarded by tapLock
    private var lastInRate = 0
    private var decimIdx = 0
    private var s0 = 0
    private var s1 = 0
    private var phase = 0.0
    private var prevSample = 0.0
    private var hasPrev = false

    private val audioSink = AudioTrackSink { audioData: ByteBuffer,
                                             bitsPerSample: Int,
                                             sampleRate: Int,
                                             numberOfChannels: Int,
                                             numberOfFrames: Int,
                                             _: Long ->
        if (!isTapping || bitsPerSample != 16 || numberOfFrames <= 0 || numberOfChannels <= 0 || sampleRate <= 0) {
            return@AudioTrackSink
        }
        val basePos = audioData.position()
        val bytesPerFrame = numberOfChannels * 2
        if (audioData.remaining() < numberOfFrames * bytesPerFrame) {
            return@AudioTrackSink
        }

        synchronized(tapLock) {
            if (!isTapping) return@AudioTrackSink
            if (lastInRate != sampleRate) {
                lastInRate = sampleRate
                decimIdx = 0
                phase = 0.0
                hasPrev = false
            }

            val linearStep = sampleRate.toDouble() / TARGET_RATE.toDouble()
            for (i in 0 until numberOfFrames) {
                val idx = basePos + i * bytesPerFrame
                val lo = audioData.get(idx).toInt() and 0xFF
                val hi = audioData.get(idx + 1).toInt()
                val sample = ((hi shl 8) or lo).toShort().toInt()

                when (sampleRate) {
                    TARGET_RATE -> emitSample(sample)
                    TARGET_RATE * 3 -> {
                        when (decimIdx) {
                            0 -> {
                                s0 = sample
                                decimIdx = 1
                            }
                            1 -> {
                                s1 = sample
                                decimIdx = 2
                            }
                            else -> {
                                val filtered = (s0 + (s1 shl 1) + sample + 2) shr 2
                                emitSample(filtered)
                                decimIdx = 0
                            }
                        }
                    }
                    else -> {
                        val cur = sample.toDouble()
                        if (!hasPrev) {
                            prevSample = cur
                            hasPrev = true
                            emitSample(sample)
                            phase = linearStep
                        } else {
                            while (phase <= 1.0) {
                                val interp = prevSample + (cur - prevSample) * phase
                                emitSample(interp.roundToInt())
                                phase += linearStep
                            }
                            phase -= 1.0
                            prevSample = cur
                        }
                    }
                }
            }
        }
    }

    init {
        methodChannel.setMethodCallHandler(this)
        streamChannel.setStreamHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startTap" -> {
                val trackId = call.argument<String>("trackId")
                startTap(trackId, result)
            }
            "stopTap" -> {
                stopTapInternal()
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    private fun startTap(trackId: String?, result: MethodChannel.Result) {
        stopTapInternal()

        if (trackId.isNullOrEmpty()) {
            result.error("INVALID_TRACK_ID", "Missing WebRTC local audio trackId", null)
            return
        }

        val track = FlutterWebRTCPlugin.sharedSingleton?.getLocalTrack(trackId) as? LocalAudioTrack
        if (track == null) {
            result.error("TRACK_NOT_FOUND", "No active LocalAudioTrack for trackId=$trackId", null)
            return
        }

        synchronized(tapLock) {
            outBytes = 0
            lastInRate = 0
            decimIdx = 0
            phase = 0.0
            hasPrev = false
        }
        attachedTrack = track
        isTapping = true
        track.addSink(audioSink)
        result.success(true)
    }

    private fun stopTapInternal() {
        isTapping = false
        attachedTrack?.let { track ->
            try {
                track.removeSink(audioSink)
            } catch (_: Throwable) {
            }
        }
        attachedTrack = null
        synchronized(tapLock) {
            outBytes = 0
            lastInRate = 0
        }
    }

    private fun emitSample(rawSample: Int) {
        val clamped = rawSample.coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())
        outChunk[outBytes++] = (clamped and 0xFF).toByte()
        outChunk[outBytes++] = ((clamped ushr 8) and 0xFF).toByte()

        if (outBytes >= CHUNK_BYTES) {
            val payload = outChunk.copyOf()
            outBytes = 0
            if (isTapping) {
                mainHandler.post {
                    if (isTapping) {
                        eventSink?.success(payload)
                    }
                }
            }
        }
    }

    fun release() {
        stopTapInternal()
        methodChannel.setMethodCallHandler(null)
        streamChannel.setStreamHandler(null)
    }
}
