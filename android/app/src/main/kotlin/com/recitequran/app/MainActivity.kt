package com.recitequran.app

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.WindowManager
import androidx.core.view.WindowCompat
import com.cloudwebrtc.webrtc.audio.AudioSwitchManager
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    private val CHANNEL = "com.recitequran.app/playstore"
    private val MAGLIS_SERVICE_CHANNEL = "com.recitequran.app/maglis_service"

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

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, MAGLIS_SERVICE_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startService" -> {
                    val intent = Intent(this, MaglisCallService::class.java).apply {
                        action = MaglisCallService.ACTION_START
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startForegroundService(intent)
                    } else {
                        startService(intent)
                    }
                    result.success(true)
                }
                "stopService" -> {
                    val intent = Intent(this, MaglisCallService::class.java).apply {
                        action = MaglisCallService.ACTION_STOP
                    }
                    startService(intent)
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
