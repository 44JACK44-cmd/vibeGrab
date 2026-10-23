package com.example.vibegrab

import android.Manifest
import android.app.PictureInPictureParams
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.ColorDrawable
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.MediaStore
import android.provider.Settings
import android.util.Rational
import android.view.WindowManager
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.text.SimpleDateFormat
import java.util.*

// MUST extend AudioServiceActivity (audio_service README): it provides the
// shared "audio_service_engine" FlutterEngine to the audio_service plugin.
// With a plain FlutterActivity the plugin detects a "wrong engine", every
// AudioService.init() call throws and the Android MediaSession / media
// notification is NEVER created.
class MainActivity : AudioServiceActivity() {
    private val SHARE_CHANNEL = "com.example.vibegrab/share"
    private val DOWNLOAD_CHANNEL = "com.example.vibegrab/downloads"
    private val LOCAL_MEDIA_CHANNEL = "com.example.vibegrab/local_media"
    private val STORAGE_CHANNEL = "com.example.vibegrab/storage"
    private val PIP_CHANNEL = "com.example.vibegrab/pip"
    private val STATUS_CHANNEL = "com.example.vibegrab/status"
    private val APP_CHANNEL = "com.example.vibegrab/app"
    private var shareChannel: MethodChannel? = null
    private var downloadChannel: MethodChannel? = null
    private var localMediaChannel: MethodChannel? = null
    private var storageChannel: MethodChannel? = null
    private var pipChannel: MethodChannel? = null
    private var statusChannel: MethodChannel? = null
    private var appChannel: MethodChannel? = null
    private var pipEventSink: EventChannel.EventSink? = null
    private var initialSharedUrl: String? = null
    private var initialShareOverlay = false
    private var pendingNotificationAction: Map<String, String?>? = null
    private var pendingPickResult: MethodChannel.Result? = null
    private val PICK_DIR_REQUEST = 1001
    private var isInPipMode = false

    // VibeGrab: static R references for the drawables that audio_service
    // resolves BY NAME at runtime (Resources.getIdentifier). If nothing
    // references them statically the packager can drop them from
    // resources.arsc, getIdentifier() returns 0 and the media notification
    // can never be posted. Touching them here guarantees they ship.
    private val mediaDrawables = mapOf(
        "ic_music_note" to R.drawable.ic_music_note,
        "ic_vibegrab_repeat" to R.drawable.ic_vibegrab_repeat,
        "ic_vibegrab_repeat_one" to R.drawable.ic_vibegrab_repeat_one,
        "ic_vibegrab_repeat_off" to R.drawable.ic_vibegrab_repeat_off,
        "ic_vibegrab_shuffle" to R.drawable.ic_vibegrab_shuffle,
        "ic_vibegrab_favorite" to R.drawable.ic_vibegrab_favorite,
        "ic_vibegrab_favorite_filled" to R.drawable.ic_vibegrab_favorite_filled
    )

    override fun onCreate(savedInstanceState: Bundle?) {
        val fromShare = intent?.action == Intent.ACTION_SEND
        setTheme(if (fromShare) R.style.ShareTranslucentTheme else R.style.NormalTheme)
        super.onCreate(savedInstanceState)
        if (fromShare) {
            applyShareWindowOverlay()
        }
    }

    private fun applyShareWindowOverlay() {
        try {
            @Suppress("DEPRECATION")
            window.setFormat(PixelFormat.TRANSLUCENT)
            window.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
            window.addFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND)
            window.setDimAmount(0.6f)
        } catch (e: Exception) {
            android.util.Log.w("VibeGrab", "share window overlay failed: ${e.message}")
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        setupShareChannel(messenger)
        setupDownloadChannel(messenger)
        setupStorageChannel(messenger)
        setupLocalMediaChannel(messenger)
        setupPipChannel(messenger)
        setupStatusChannel(messenger)
        setupAppChannel(messenger)
        setupEqChannel(messenger)
        setupMediaDiagChannel(messenger)

        handleIntent(intent)
    }

    private fun setupShareChannel(messenger: BinaryMessenger) {
        shareChannel = MethodChannel(messenger, SHARE_CHANNEL)
        shareChannel?.setMethodCallHandler { call, result ->
            if (call.method == "getInitialShareInfo") {
                result.success(mapOf(
                    "url" to (initialSharedUrl ?: ""),
                    "overlay" to initialShareOverlay
                ))
                initialSharedUrl = null
                initialShareOverlay = false
            } else {
                result.notImplemented()
            }
        }
    }

    private fun setupDownloadChannel(messenger: BinaryMessenger) {
        downloadChannel = MethodChannel(messenger, DOWNLOAD_CHANNEL)
        downloadChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "startService" -> {
                    val intent = Intent(this, DownloadNotificationService::class.java)
                    intent.putExtra("command", "start")
                    startForegroundService(intent)
                    result.success(true)
                }
                "updateNotification" -> {
                    val args = call.arguments as? Map<*, *>
                    val intent = Intent(this, DownloadNotificationService::class.java).apply {
                        putExtra("command", "update")
                        putExtra("taskId", args?.get("taskId") as? String)
                        putExtra("title", args?.get("title") as? String)
                        putExtra("progress", (args?.get("progress") as? Number)?.toDouble() ?: 0.0)
                        putExtra("speedBps", (args?.get("speedBps") as? Number)?.toLong() ?: 0L)
                    }
                    startForegroundService(intent)
                    result.success(true)
                }
                "showCompleted" -> {
                    val args = call.arguments as? Map<*, *>
                    val intent = Intent(this, DownloadNotificationService::class.java).apply {
                        putExtra("command", "completed")
                        putExtra("taskId", args?.get("taskId") as? String)
                        putExtra("title", args?.get("title") as? String)
                        putExtra("timeoutMs", (args?.get("timeoutMs") as? Number)?.toLong()
                            ?: DownloadNotificationService.MIN_RESULT_TIMEOUT_MS)
                    }
                    startForegroundService(intent)
                    result.success(true)
                }
                "showFailed" -> {
                    val args = call.arguments as? Map<*, *>
                    val intent = Intent(this, DownloadNotificationService::class.java).apply {
                        putExtra("command", "failed")
                        putExtra("taskId", args?.get("taskId") as? String)
                        putExtra("title", args?.get("title") as? String)
                        putExtra("error", args?.get("error") as? String)
                        putExtra("timeoutMs", (args?.get("timeoutMs") as? Number)?.toLong()
                            ?: DownloadNotificationService.MIN_RESULT_TIMEOUT_MS)
                    }
                    startForegroundService(intent)
                    result.success(true)
                }
                "stopService" -> {
                    val intent = Intent(this, DownloadNotificationService::class.java)
                    intent.putExtra("command", "stop")
                    startService(intent)
                    result.success(true)
                }
                "removeTask" -> {
                    val args = call.arguments as? Map<*, *>
                    val intent = Intent(this, DownloadNotificationService::class.java).apply {
                        putExtra("command", "removeTask")
                        putExtra("taskId", args?.get("taskId") as? String)
                    }
                    startService(intent)
                    result.success(true)
                }
                "getPendingNotificationAction" -> {
                    result.success(pendingNotificationAction)
                    pendingNotificationAction = null
                }
                "setResultsSound" -> {
                    val enabled = call.arguments as? Boolean ?: true
                    DownloadNotificationService.applyResultsSound(this, enabled)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun setupStorageChannel(messenger: BinaryMessenger) {
        storageChannel = MethodChannel(messenger, STORAGE_CHANNEL)
        storageChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "pickDirectory" -> {
                    pendingPickResult = result
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
                    intent.addFlags(
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                        Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
                    )
                    startActivityForResult(intent, PICK_DIR_REQUEST)
                }
                "getAndroidSdkVersion" -> {
                    result.success(mapOf("sdkVersion" to android.os.Build.VERSION.SDK_INT))
                }
                "getExternalStorageRoot" -> {
                    val externalRoot = android.os.Environment.getExternalStorageDirectory()
                    result.success(mapOf("path" to externalRoot?.absolutePath))
                }
                "availableBytes" -> {
                    try {
                        val args = call.arguments as? Map<*, *>
                        val path = args?.get("path") as? String
                        if (path.isNullOrBlank()) {
                            result.success(-1)
                        } else {
                            val stat = android.os.StatFs(path)
                            result.success(stat.availableBytes)
                        }
                    } catch (e: Exception) {
                        result.success(-1)
                    }
                }
                "deleteMedia" -> {
                    try {
                        val args = call.arguments as? Map<*, *>
                        val uriText = args?.get("uri") as? String
                        if (uriText.isNullOrBlank()) {
                            result.success(false)
                        } else {
                            val deleted = contentResolver.delete(
                                android.net.Uri.parse(uriText), null, null
                            )
                            result.success(deleted > 0)
                        }
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun setupLocalMediaChannel(messenger: BinaryMessenger) {
        localMediaChannel = MethodChannel(messenger, LOCAL_MEDIA_CHANNEL)
        localMediaChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                // Library/MediaStore code asks this on the local-media channel:
                // without it the Dart side fell back to "SDK 33+" and checked
                // READ_MEDIA_VIDEO/AUDIO on Android 11/12, where those
                // permissions do not exist, so the Library stayed locked behind
                // "Media access required" forever.
                "getAndroidSdkVersion" -> {
                    result.success(mapOf("sdkVersion" to Build.VERSION.SDK_INT))
                }
                "getDeviceMedia" -> {
                    Thread {
                        try {
                            val mediaList = queryDeviceMedia()
                            runOnUiThread { result.success(mediaList) }
                        } catch (e: Exception) {
                            runOnUiThread {
                                result.error("MEDIA_QUERY_ERROR", e.message, null)
                            }
                        }
                    }.start()
                }
                "getMediaContentUri" -> {
                    try {
                        val args = call.arguments as? Map<*, *>
                        val contentUri = args?.get("contentUri") as? String
                        if (contentUri != null) {
                            result.success(contentUri)
                        } else {
                            result.error("INVALID_ARGS", "contentUri is required", null)
                        }
                    } catch (e: Exception) {
                        result.error("URI_ERROR", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun setupPipChannel(messenger: BinaryMessenger) {
        pipChannel = MethodChannel(messenger, PIP_CHANNEL)
        pipChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "isPipAvailable" -> {
                    result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && packageManager.hasSystemFeature("android.software.picture_in_picture"))
                }
                "enterPip" -> {
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            val args = call.arguments as? Map<*, *>
                            val ratio = (args?.get("aspectRatio") as? Number)?.toDouble()
                                ?: (16.0 / 9.0)
                            val safeRatio = if (ratio.isFinite() && ratio > 0.3 && ratio < 3.0)
                                ratio else (16.0 / 9.0)
                            val width = (safeRatio * 1000).toInt()
                            val builder = PictureInPictureParams.Builder()
                                .setAspectRatio(Rational(width, 1000))
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                                builder.setSeamlessResizeEnabled(true)
                            }
                            enterPictureInPictureMode(builder.build())
                            result.success(true)
                        } else {
                            result.success(false)
                        }
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "isInPip" -> {
                    result.success(isInPipMode)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun setupStatusChannel(messenger: BinaryMessenger) {
        statusChannel = MethodChannel(messenger, STATUS_CHANNEL)
        statusChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "checkAccess" -> handleCheckAccess(result)
                "openAllFilesSettings" -> handleOpenAllFilesSettings(result)
                "saveToGallery" -> handleSaveToGallery(call, result)
                // Shares a file (WhatsApp statuses) through the system sheet.
                "shareFile" -> handleShareFile(call, result)
                else -> result.notImplemented()
            }
        }
    }

    private fun handleCheckAccess(result: MethodChannel.Result) {
        try {
            result.success(checkStatusAccess())
        } catch (e: Exception) {
            result.error("STATUS_ERROR", e.message, null)
        }
    }

    private fun handleOpenAllFilesSettings(result: MethodChannel.Result) {
        try {
            if (Build.VERSION.SDK_INT >= 30) {
                val intent = Intent(
                    Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                    Uri.parse("package:$packageName")
                )
                startActivity(intent)
            } else {
                val intent = Intent(
                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.parse("package:$packageName")
                )
                startActivity(intent)
            }
            result.success(true)
        } catch (e: Exception) {
            try {
                val intent = Intent(
                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.parse("package:$packageName")
                )
                startActivity(intent)
                result.success(true)
            } catch (e2: Exception) {
                result.success(false)
            }
        }
    }

    private fun handleSaveToGallery(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *>
        val path = args?.get("path") as? String
        val name = args?.get("name") as? String
        val mime = args?.get("mime") as? String ?: "*/*"
        if (path == null || name == null) {
            result.error("INVALID_ARGS", "path and name required", null)
        } else {
            try {
                result.success(saveToGallery(path, name, mime))
            } catch (e: Exception) {
                android.util.Log.w("VibeGrab", "saveToGallery failed: ${e.message}")
                result.success(false)
            }
        }
    }

    private fun handleShareFile(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *>
        val path = args?.get("path") as? String
        val name = args?.get("name") as? String
        val mime = args?.get("mime") as? String ?: "*/*"
        if (path == null || name == null) {
            result.error("INVALID_ARGS", "path and name required", null)
        } else {
            try {
                val uri = androidx.core.content.FileProvider.getUriForFile(
                    this, "$packageName.fileprovider", File(path)
                )
                val send = Intent(Intent.ACTION_SEND).apply {
                    type = mime
                    putExtra(Intent.EXTRA_STREAM, uri)
                    putExtra(Intent.EXTRA_SUBJECT, name)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
                startActivity(Intent.createChooser(send, name))
                result.success(true)
            } catch (e: Exception) {
                android.util.Log.w("VibeGrab", "shareFile failed: ${e.message}")
                result.success(false)
            }
        }
    }

    private fun setupAppChannel(messenger: BinaryMessenger) {
        appChannel = MethodChannel(messenger, APP_CHANNEL)
        appChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "getVersion" -> handleGetVersion(result)
                "installApk" -> handleInstallApk(call, result)
                "getDeviceAbi" -> {
                    val abis = Build.SUPPORTED_ABIS
                    result.success(if (abis.isNotEmpty()) abis[0] else "arm64-v8a")
                }
                "canInstallPackages" -> {
                    val allowed = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        packageManager.canRequestPackageInstalls()
                    } else {
                        true
                    }
                    result.success(allowed)
                }
                "closeActivity" -> handleCloseActivity(result)
                // Opens a downloaded file with the system viewer.
                "openFile" -> handleOpenFile(call, result)
                "backgroundOverlay" -> handleBackgroundOverlay(result)
                "scanMedia" -> handleScanMedia(call, result)
                // Screen brightness for the video player (window attribute).
                "setBrightness" -> handleSetBrightness(call, result)
                "getBrightness" -> handleGetBrightness(result)
                "getDnsStatus" -> handleGetDnsStatus(result)
                "openPrivateDnsSettings" -> handleOpenPrivateDnsSettings(result)
                else -> result.notImplemented()
            }
        }
    }

    /// Read-only report of the DNS configuration Android is actually using.
    /// VibeGrab cannot override DNS per app: the system resolver (and Android
    /// Private DNS / DoT) applies to the app's sockets and to WebView. This is
    /// reported as-is instead of pretending the app has its own DNS.
    private fun handleGetDnsStatus(result: MethodChannel.Result) {
        try {
            val cm = getSystemService(android.net.ConnectivityManager::class.java)
            val network = cm?.activeNetwork
            val link = if (network != null) cm?.getLinkProperties(network) else null
            val servers = link?.dnsServers
                ?.mapNotNull { it.hostAddress }
                ?.filter { it.isNotBlank() }
                ?: emptyList()

            var mode = "unknown"
            var hostname = ""
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                // Documented Settings.Global keys; the Java constants are not
                // part of the public SDK on every compileSdk.
                mode = Settings.Global.getString(
                    contentResolver, "private_dns_mode"
                ) ?: "unknown"
                hostname = Settings.Global.getString(
                    contentResolver, "private_dns_specifier"
                ) ?: ""
            }
            result.success(mapOf(
                "mode" to mode,
                "hostname" to hostname,
                "servers" to servers,
                "sdk" to Build.VERSION.SDK_INT
            ))
        } catch (e: Exception) {
            result.success(mapOf(
                "mode" to "unknown",
                "hostname" to "",
                "servers" to emptyList<String>(),
                "sdk" to Build.VERSION.SDK_INT
            ))
        }
    }

    private fun handleOpenPrivateDnsSettings(result: MethodChannel.Result) {
        try {
            val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                Intent("android.settings.PRIVATE_DNS_SETTINGS")
            } else {
                Intent(Settings.ACTION_WIRELESS_SETTINGS)
            }
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            result.success(true)
        } catch (e: Exception) {
            try {
                startActivity(Intent(Settings.ACTION_WIRELESS_SETTINGS))
                result.success(true)
            } catch (e2: Exception) {
                result.success(false)
            }
        }
    }

    private fun handleGetVersion(result: MethodChannel.Result) {
        try {
            val pInfo = packageManager.getPackageInfo(packageName, 0)
            val build = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                pInfo.longVersionCode.toInt()
            } else {
                @Suppress("DEPRECATION")
                pInfo.versionCode
            }
            result.success(mapOf(
                "version" to (pInfo.versionName ?: "0"),
                "build" to build
            ))
        } catch (e: Exception) {
            result.error("VERSION_ERROR", e.message, null)
        }
    }

    /// Starts a settings screen, returning false when the device has no
    /// activity for it (some OEM ROMs rename or drop screens).
    private fun openSettingsScreen(intent: Intent): Boolean {
        return try {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            true
        } catch (e: Exception) {
            android.util.Log.w("VibeGrab", "settings screen not available: ${intent.action}")
            false
        }
    }

    private fun handleInstallApk(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        val file = if (path != null) File(path) else null
        if (file == null || !file.exists()) {
            result.error("ENOENT", "APK file not found", null)
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !packageManager.canRequestPackageInstalls()
        ) {
            // Android 8+ needs the user to allow this app to install
            // packages. Without this check the installer opens and dies with
            // a security error that the app never sees: the update simply
            // "does nothing". Open the permission screen instead and tell
            // the app what happened.
            // "Install unknown apps" per-app screen. The previous string
            // (android.settings.MANAGE_APP_INSTALL_PACKAGE) does not exist in
            // Android: startActivity threw ActivityNotFoundException on every
            // device, the update never started and the dialog showed that raw
            // exception. ACTION_MANAGE_UNKNOWN_APP_SOURCES is the real action
            // since API 26 and needs the package URI.
            val opened = openSettingsScreen(
                Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:$packageName")
                )
            ) || openSettingsScreen(
                Intent(
                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.parse("package:$packageName")
                )
            )
            if (opened) {
                // The app keeps the downloaded APK and retries the install
                // when it comes back with the permission granted.
                result.error(
                    "INSTALL_PERMISSION_REQUIRED",
                    "Permission to install packages is required",
                    null
                )
            } else {
                result.error(
                    "INSTALL_ERROR",
                    "No settings screen accepts the install permission",
                    null
                )
            }
        } else {
            try {
                val uri = androidx.core.content.FileProvider.getUriForFile(
                    this, "$packageName.fileprovider", file
                )
                val intent = Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(uri, "application/vnd.android.package-archive")
                    addFlags(
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or
                            Intent.FLAG_ACTIVITY_NEW_TASK
                    )
                }
                startActivity(intent)
                result.success(true)
            } catch (e: Exception) {
                result.error("INSTALL_ERROR", e.message, null)
            }
        }
    }

    private fun handleCloseActivity(result: MethodChannel.Result) {
        runOnUiThread {
            finish()
            result.success(true)
        }
    }

    private fun handleOpenFile(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        val mime = call.argument<String>("mime") ?: "*/*"
        val file = if (path != null) File(path) else null
        if (file == null || !file.exists()) {
            result.error("ENOENT", "File not found", null)
        } else {
            try {
                val uri = androidx.core.content.FileProvider.getUriForFile(
                    this, "$packageName.fileprovider", file
                )
                val intent = Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(uri, mime)
                    addFlags(
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or
                            Intent.FLAG_ACTIVITY_NEW_TASK
                    )
                }
                startActivity(intent)
                result.success(true)
            } catch (e: Exception) {
                android.util.Log.w("VibeGrab", "openFile failed: ${e.message}")
                result.success(false)
            }
        }
    }

    private fun handleBackgroundOverlay(result: MethodChannel.Result) {
        runOnUiThread {
            try {
                window.clearFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND)
                window.setBackgroundDrawableResource(android.R.color.black)
            } catch (e: Exception) {
                android.util.Log.w("VibeGrab", "backgroundOverlay cleanup failed: ${e.message}")
            }
            moveTaskToBack(true)
            result.success(true)
        }
    }

    private fun handleScanMedia(call: MethodCall, result: MethodChannel.Result) {
        val paths = call.argument<List<String>>("paths")
        try {
            if (paths != null && paths.isNotEmpty()) {
                android.media.MediaScannerConnection.scanFile(
                    this,
                    paths.toTypedArray(),
                    paths.map { p ->
                        android.webkit.MimeTypeMap.getSingleton()
                            .getMimeTypeFromExtension(p.substringAfterLast('.', ""))
                            ?: "*/*"
                    }.toTypedArray(),
                    null
                )
            }
            result.success(true)
        } catch (e: Exception) {
            android.util.Log.w("VibeGrab", "scanMedia failed: ${e.message}")
            result.success(false)
        }
    }

    private fun handleSetBrightness(call: MethodCall, result: MethodChannel.Result) {
        try {
            val v = (call.argument<Number>("value")?.toFloat()) ?: -1f
            runOnUiThread {
                val lp = window.attributes
                lp.screenBrightness = v.coerceIn(-1f, 1f)
                window.attributes = lp
            }
            result.success(true)
        } catch (e: Exception) {
            result.success(false)
        }
    }

    private fun handleGetBrightness(result: MethodChannel.Result) {
        try {
            result.success(window.attributes.screenBrightness)
        } catch (e: Exception) {
            result.success(-1.0)
        }
    }

    private fun setupEqChannel(messenger: BinaryMessenger) {
        // VibeGrab: hardware equalizer (DSP) bound to the audio session.
        val eqChannel = MethodChannel(messenger, "com.example.vibegrab/equalizer")
        eqChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "init" -> {
                    val sid = (call.argument<Number>("sessionId")?.toInt()) ?: 0
                    val en = call.argument<Boolean>("enabled") ?: true
                    val ok = EqBridge.attach(sid)
                    if (ok) EqBridge.setEnabled(en)
                    result.success(ok)
                }
                "info" -> result.success(EqBridge.info())
                "setEnabled" -> {
                    EqBridge.setEnabled(call.argument<Boolean>("enabled") == true)
                    result.success(true)
                }
                "setBand" -> {
                    EqBridge.setBand(call.argument<Int>("band") ?: 0,
                        (call.argument<Number>("levelMb")?.toInt()) ?: 0)
                    result.success(true)
                }
                "setPreset" -> {
                    EqBridge.setPreset(call.argument<Int>("index") ?: 0)
                    result.success(true)
                }
                "setBass" -> {
                    EqBridge.setBass((call.argument<Number>("strength")?.toInt()) ?: 0)
                    result.success(true)
                }
                "setLoudness" -> {
                    EqBridge.setLoudness((call.argument<Number>("gainMb")?.toInt()) ?: 0)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun setupMediaDiagChannel(messenger: BinaryMessenger) {
        val mediaDiagChannel = MethodChannel(messenger, "vibegrab/media_diag")
        mediaDiagChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                // True only when the user can actually SEE notifications:
                // covers POST_NOTIFICATIONS (Android 13+) and the per-app
                // toggle of OEM skins (MIUI/HyperOS, One UI, ...).
                "notificationsEnabled" -> {
                    result.success(
                        androidx.core.app.NotificationManagerCompat.from(this)
                            .areNotificationsEnabled()
                    )
                }
                // Runtime proof that the name-resolved drawables really
                // shipped inside the APK (0 means "missing").
                "mediaDrawableIds" -> {
                    result.success(mediaDrawables)
                }
                "openNotificationSettings" -> {
                    try {
                        val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                            .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        try {
                            val intent = Intent(
                                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                Uri.parse("package:$packageName")
                            )
                            startActivity(intent)
                            result.success(true)
                        } catch (e2: Exception) {
                            result.success(false)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (intent.action == Intent.ACTION_SEND) {
            applyShareWindowOverlay()
        }
        handleIntent(intent)
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        isInPipMode = isInPictureInPictureMode
        pipChannel?.invokeMethod("onPipModeChanged", mapOf("isInPip" to isInPictureInPictureMode))
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == PICK_DIR_REQUEST) {
            handlePickDirResult(resultCode, data)
        }
    }

    private fun handlePickDirResult(resultCode: Int, data: Intent?) {
        if (resultCode == RESULT_OK && data?.data != null) {
            val treeUri = data.data!!
            try {
                contentResolver.takePersistableUriPermission(
                    treeUri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                )
            } catch (e: Exception) {
                android.util.Log.w("VibeGrab", "takePersistableUriPermission failed: ${e.message}")
            }
            val docFile = androidx.documentfile.provider.DocumentFile.fromTreeUri(this, treeUri)
            val displayName = docFile?.name ?: "Download"
            pendingPickResult?.success(buildPickDirResult(treeUri, displayName))
        } else {
            pendingPickResult?.success(null)
        }
        pendingPickResult = null
    }

    private fun buildPickDirResult(treeUri: Uri, displayName: String): Map<String, Any?> {
        val directPath = "/storage/emulated/0/$displayName"
        val directFile = java.io.File(directPath)
        val canWriteDirect = try {
            directFile.exists() && directFile.canWrite()
        } catch (e: Exception) {
            false
        }
        return mapOf(
            "uri" to treeUri.toString(),
            "path" to if (canWriteDirect) directPath else "",
            "name" to displayName
        )
    }

    private fun handleIntent(intent: Intent?) {
        handleSharedUrlIntent(intent)
        handleNotificationActionIntent(intent)
    }

    private fun handleSharedUrlIntent(intent: Intent?) {
        if (intent?.action == Intent.ACTION_SEND && intent.type == "text/plain") {
            val sharedText = intent.getStringExtra(Intent.EXTRA_TEXT)
            if (sharedText != null) {
                val overlay = lifecycle.currentState != Lifecycle.State.RESUMED
                if (shareChannel != null) {
                    shareChannel?.invokeMethod(
                        "onSharedUrl",
                        mapOf("url" to sharedText, "overlay" to overlay)
                    )
                } else {
                    initialSharedUrl = sharedText
                    initialShareOverlay = overlay
                }
            }
        }
    }

    private fun handleNotificationActionIntent(intent: Intent?) {
        if (intent?.action == "NOTIFICATION_ACTION") {
            val action = intent.getStringExtra("action")
            val taskId = intent.getStringExtra("taskId")
            if (action != null && taskId != null) {
                val data = mapOf("action" to action, "taskId" to taskId)
                if (downloadChannel != null) {
                    downloadChannel?.invokeMethod("onNotificationAction", data)
                } else {
                    pendingNotificationAction = data
                }
            }
        }
    }

    private fun queryDeviceMedia(): List<Map<String, Any?>> {
        val mediaList = mutableListOf<Map<String, Any?>>()

        queryMediaType(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, "video", mediaList)
        queryMediaType(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, "audio", mediaList)

        mediaList.sortByDescending { (it["createdAt"] as? String) ?: "" }

        return mediaList
    }

    private fun queryMediaType(
        contentUri: android.net.Uri,
        mediaType: String,
        mediaList: MutableList<Map<String, Any?>>
    ) {
        val projection = arrayOf(
            MediaStore.MediaColumns._ID,
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.TITLE,
            MediaStore.MediaColumns.DATA,
            MediaStore.MediaColumns.SIZE,
            MediaStore.MediaColumns.DATE_ADDED,
            MediaStore.MediaColumns.DURATION,
            MediaStore.MediaColumns.MIME_TYPE
        )

        val audioProjection = if (mediaType == "audio") {
            arrayOf(MediaStore.Audio.Media.ALBUM, MediaStore.Audio.Media.ARTIST)
        } else {
            emptyArray()
        }

        val fullProjection = projection + audioProjection

        val sortOrder = "${MediaStore.MediaColumns.DATE_ADDED} DESC"

        val cursor = contentResolver.query(contentUri, fullProjection, null, null, sortOrder)

        cursor?.use { c ->
            val columns = mediaRowColumns(c, mediaType)
            while (c.moveToNext()) {
                mediaList.add(readMediaRow(c, mediaType, columns))
            }
        }
    }

    private fun mediaRowColumns(cursor: android.database.Cursor, mediaType: String): MediaRowColumns =
        MediaRowColumns().apply {
            id = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
            displayName = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME)
            title = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.TITLE)
            data = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DATA)
            size = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE)
            dateAdded = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_ADDED)
            duration = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DURATION)
            album = optionalColumnIndex(cursor, mediaType == "audio", MediaStore.Audio.Media.ALBUM)
            artist = optionalColumnIndex(cursor, mediaType == "audio", MediaStore.Audio.Media.ARTIST)
        }

    private fun optionalColumnIndex(
        cursor: android.database.Cursor,
        enabled: Boolean,
        columnName: String
    ): Int = if (enabled) {
        try {
            cursor.getColumnIndexOrThrow(columnName)
        } catch (e: Exception) {
            -1
        }
    } else {
        -1
    }

    private fun readMediaRow(
        cursor: android.database.Cursor,
        mediaType: String,
        columns: MediaRowColumns
    ): Map<String, Any?> {
        val id = cursor.getLong(columns.id)
        val displayName = cursor.getString(columns.displayName) ?: ""
        val title = cursor.getString(columns.title) ?: ""
        val data = cursor.getString(columns.data) ?: ""
        val size = if (columns.size >= 0) cursor.getLong(columns.size) else 0L
        val dateAdded = if (columns.dateAdded >= 0) cursor.getLong(columns.dateAdded) else 0L
        val duration = if (columns.duration >= 0) cursor.getLong(columns.duration) else 0L

        val album = if (columns.album >= 0) cursor.getString(columns.album) ?: "" else ""
        val artist = if (columns.artist >= 0) cursor.getString(columns.artist) ?: "" else ""

        val uriString = when (mediaType) {
            "video" -> "content://media/external/video/media/$id"
            "audio" -> "content://media/external/audio/media/$id"
            else -> ""
        }

        val extension = if (displayName.contains(".")) {
            displayName.substringAfterLast(".")
        } else {
            ""
        }

        val createdAt = if (dateAdded > 0) {
            val sdf = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US)
            sdf.timeZone = TimeZone.getTimeZone("UTC")
            sdf.format(Date(dateAdded * 1000))
        } else {
            ""
        }

        return mapOf(
            "filename" to displayName,
            "title" to title,
            "filePath" to data,
            "fileSize" to size,
            "fileSizeFormatted" to formatFileSize(size),
            "fileType" to mediaType,
            "extension" to extension,
            "createdAt" to createdAt,
            "source" to "device",
            "sourceType" to "local",
            "contentUri" to uriString,
            "album" to album,
            "artist" to artist,
            "duration" to duration,
            "thumbnailPath" to extractThumbnail(uriString, mediaType, id, displayName)
        )
    }

    private fun extractThumbnail(uriString: String, mediaType: String, id: Long, displayName: String): String? {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val thumbBitmap = contentResolver.loadThumbnail(
                    android.net.Uri.parse(uriString), android.util.Size(320, 320), null
                )
                saveThumbnail(thumbBitmap, mediaType, id)
            } else {
                @Suppress("DEPRECATION")
                val thumbBitmap = MediaStore.Images.Thumbnails.getThumbnail(
                    contentResolver, id,
                    MediaStore.Images.Thumbnails.MINI_KIND, null
                )
                if (thumbBitmap != null) saveThumbnail(thumbBitmap, mediaType, id) else null
            }
        } catch (e: Exception) {
            android.util.Log.d("VibeGrab", "Thumbnail extraction failed for $displayName: ${e.message}")
            null
        }
    }

    private fun saveThumbnail(thumbBitmap: android.graphics.Bitmap, mediaType: String, id: Long): String {
        val thumbFile = java.io.File(cacheDir, "thumb_${mediaType}_${id}.jpg")
        thumbFile.outputStream().use { out ->
            thumbBitmap.compress(android.graphics.Bitmap.CompressFormat.JPEG, 85, out)
        }
        val path = thumbFile.absolutePath
        thumbBitmap.recycle()
        return path
    }

    private class MediaRowColumns {
        var id = -1
        var displayName = -1
        var title = -1
        var data = -1
        var size = -1
        var dateAdded = -1
        var duration = -1
        var album = -1
        var artist = -1
    }

    private fun hasMediaReadPermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= 33) {
            ContextCompat.checkSelfPermission(this, Manifest.permission.READ_MEDIA_IMAGES) ==
                PackageManager.PERMISSION_GRANTED &&
                ContextCompat.checkSelfPermission(this, Manifest.permission.READ_MEDIA_VIDEO) ==
                PackageManager.PERMISSION_GRANTED
        } else {
            ContextCompat.checkSelfPermission(this, Manifest.permission.READ_EXTERNAL_STORAGE) ==
                PackageManager.PERMISSION_GRANTED
        }
    }

    private fun statusDirCandidates(): List<File> {
        val root = Environment.getExternalStorageDirectory().absolutePath
        val list = mutableListOf<File>()
        if (Build.VERSION.SDK_INT >= 29) {
            list.add(File("$root/Android/media/com.whatsapp/WhatsApp/Media/.Statuses"))
            list.add(File("$root/Android/media/com.whatsapp.w4b/WhatsApp Business/Media/.Statuses"))
        }
        list.add(File("$root/WhatsApp/Media/.Statuses"))
        list.add(File("$root/WhatsApp Business/Media/.Statuses"))
        list.add(File("/sdcard/Android/media/com.whatsapp/WhatsApp/Media/.Statuses"))
        return list
    }

    private fun checkStatusAccess(): Map<String, Any?> {
        val candidates = statusDirCandidates().distinctBy { it.absolutePath }
        val existing = candidates.filter { it.exists() }
        if (existing.isEmpty()) {
            // No WhatsApp / Business status folder at all. Asking for
            // permissions cannot create one, so this is not a permission
            // problem.
            return mapOf("state" to "unsupported", "path" to null, "paths" to emptyList<String>())
        }
        if (!hasMediaReadPermission()) {
            return mapOf("state" to "need_media", "path" to null, "paths" to emptyList<String>())
        }
        val readable = existing.filter { it.isDirectory && it.canRead() && it.listFiles() != null }
        if (readable.isNotEmpty()) {
            return mapOf(
                "state" to "granted",
                "path" to readable.first().absolutePath,
                "paths" to readable.map { it.absolutePath }
            )
        }
        if (Build.VERSION.SDK_INT >= 30 && !Environment.isExternalStorageManager()) {
            return mapOf("state" to "need_manage", "path" to null, "paths" to emptyList<String>())
        }
        // Some ROMs keep .Statuses readable only for WhatsApp itself. Never
        // claim support we cannot deliver.
        return mapOf("state" to "unsupported", "path" to null, "paths" to emptyList<String>())
    }

    private fun saveToGallery(path: String, displayName: String, mime: String): Boolean {
        val src = File(path)
        // A zero-byte status (still being written by WhatsApp) must never be
        // reported as saved: the gallery copy would be unplayable.
        if (!src.exists() || src.length() <= 0) return false
        val expectedBytes = src.length()
        val isVideo = mime.startsWith("video")
        val isAudio = mime.startsWith("audio")

        if (Build.VERSION.SDK_INT >= 29) {
            val collection = when {
                isVideo -> MediaStore.Video.Media.EXTERNAL_CONTENT_URI
                isAudio -> MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
                else -> MediaStore.Images.Media.EXTERNAL_CONTENT_URI
            }
            val relativePath = when {
                isVideo -> "Movies/VibeGrab"
                isAudio -> "Music/VibeGrab"
                else -> "Pictures/VibeGrab"
            }
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
                put(MediaStore.MediaColumns.MIME_TYPE, mime)
                put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val uri = contentResolver.insert(collection, values) ?: return false
            return try {
                val out = contentResolver.openOutputStream(uri)
                if (out == null) {
                    contentResolver.delete(uri, null, null)
                    false
                } else {
                    out.use { stream ->
                        src.inputStream().use { it.copyTo(stream) }
                    }
                    values.clear()
                    values.put(MediaStore.MediaColumns.IS_PENDING, 0)
                    contentResolver.update(uri, values, null, null)
                    val copied = contentResolver.openFileDescriptor(uri, "r")
                        ?.use { it.statSize } ?: -1L
                    if (copied != expectedBytes) {
                        contentResolver.delete(uri, null, null)
                        false
                    } else {
                        true
                    }
                }
            } catch (e: Exception) {
                contentResolver.delete(uri, null, null)
                false
            }
        }

        return try {
            val baseDir = when {
                isVideo -> Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MOVIES)
                isAudio -> Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MUSIC)
                else -> Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES)
            }
            val dir = File(baseDir, "VibeGrab")
            dir.mkdirs()
            val dst = File(dir, displayName)
            src.copyTo(dst, overwrite = true)
            if (!dst.exists() || dst.length() != expectedBytes) {
                dst.delete()
                false
            } else {
                android.media.MediaScannerConnection.scanFile(
                    this, arrayOf(dst.absolutePath), arrayOf(mime), null
                )
                true
            }
        } catch (e: Exception) {
            false
        }
    }

    private fun formatFileSize(size: Long): String {
        if (size <= 0) return "0 B"
        val units = arrayOf("B", "KB", "MB", "GB", "TB")
        val digitGroups = (Math.log10(size.toDouble()) / Math.log10(1024.0)).toInt().coerceIn(0, units.size - 1)
        return String.format(
            Locale.US,
            "%.1f %s",
            size / Math.pow(1024.0, digitGroups.toDouble()),
            units[digitGroups]
        )
    }
}
