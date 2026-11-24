package com.recitequran.app

import android.app.KeyguardManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.view.WindowManager
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import com.cloudwebrtc.webrtc.audio.AudioSwitchManager
// TODO(playstore-fgs): Restore AudioServiceActivity when re-enabling FOREGROUND_SERVICE_MEDIA_PLAYBACK.
// import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.recitequran.app/playstore"
    private val MAGLIS_SERVICE_CHANNEL = "com.recitequran.app/maglis_service"
    private val LIFECYCLE_CHANNEL = "com.recitequran.app/audio_lifecycle"

    private var isScreenOff = false

    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                Intent.ACTION_SCREEN_OFF -> isScreenOff = true
                Intent.ACTION_SCREEN_ON, Intent.ACTION_USER_PRESENT -> isScreenOff = false
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Keep screen awake continuously while app is in foreground (Standard Android Window Flag)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        WindowCompat.setDecorFitsSystemWindows(window, false)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.attributes.layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            @Suppress("DEPRECATION")
            window.attributes.layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }

        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_USER_PRESENT)
        }
        ContextCompat.registerReceiver(this, screenReceiver, filter, ContextCompat.RECEIVER_NOT_EXPORTED)
    }

    override fun onDestroy() {
        try {
            unregisterReceiver(screenReceiver)
        } catch (_: Exception) {}
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "isPlayStoreInstalled") {
                Thread {
                    val isInstalled = isPackageInstalled("com.android.vending")
                    runOnUiThread {
                        result.success(isInstalled)
                    }
                }.start()
            } else {
                result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, LIFECYCLE_CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "isScreenOffOrLocked") {
                val powerManager = getSystemService(Context.POWER_SERVICE) as? PowerManager
                val keyguardManager = getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager
                val isInteractive = powerManager?.isInteractive ?: true
                val isLocked = keyguardManager?.isKeyguardLocked ?: false
                result.success((!isInteractive) || isLocked || isScreenOff)
            } else {
                result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, MAGLIS_SERVICE_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startService" -> {
                    // TODO(playstore-fgs): Temporarily no-op while FOREGROUND_SERVICE_MICROPHONE is disabled.
                    // val intent = Intent(this, MaglisCallService::class.java).apply {
                    //     action = MaglisCallService.ACTION_START
                    // }
                    // if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    //     startForegroundService(intent)
                    // } else {
                    //     startService(intent)
                    // }
                    result.success(true)
                }
                "stopService" -> {
                    // TODO(playstore-fgs): Temporarily no-op while FOREGROUND_SERVICE_MICROPHONE is disabled.
                    // stopService(Intent(this, MaglisCallService::class.java))
                    result.success(true)
                }
                "resetAudioToNormal" -> {
                    try {
                        AudioSwitchManager.instance?.stop()
                    } catch (_: Throwable) {
                    }
                    // AudioSwitchManager.stop() posts deactivate() to the main looper queue;
                    // posting our hardware reset immediately after ensures sequential execution.
                    Handler(Looper.getMainLooper()).post {
                        try {
                            val am = getSystemService(Context.AUDIO_SERVICE) as? AudioManager
                            if (am != null) {
                                @Suppress("DEPRECATION")
                                am.isSpeakerphoneOn = false
                                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                                    try {
                                        am.clearCommunicationDevice()
                                    } catch (_: Throwable) {
                                    }
                                }
                                try {
                                    @Suppress("DEPRECATION")
                                    if (am.isBluetoothScoOn) {
                                        am.stopBluetoothSco()
                                        am.isBluetoothScoOn = false
                                    }
                                } catch (_: Throwable) {
                                }
                                am.mode = AudioManager.MODE_NORMAL
                            }
                        } catch (_: Throwable) {
                        }
                        result.success(true)
                    }
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    private fun isPackageInstalled(packageName: String): Boolean {
        return try {
            packageManager.getPackageInfo(packageName, 0)
            
            // Validate that the app was actually installed by Google Play Store.
            // Sideloaded apps or alternative stores (like MicroG environments) 
            // will crash or fail if Play Core APIs are invoked.
            val installer = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                packageManager.getInstallSourceInfo(context.packageName).installingPackageName
            } else {
                @Suppress("DEPRECATION")
                packageManager.getInstallerPackageName(context.packageName)
            }
            
            installer == packageName
        } catch (e: Exception) {
            false
        }
    }
}
