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
import io.flutter.plugin.common.EventChannel
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

        shareChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SHARE_CHANNEL)
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

        downloadChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DOWNLOAD_CHANNEL)
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
                    }
                    startForegroundService(intent)
                    result.success(true)
                }
                "stopService" -> {
                    val intent = Intent(this, DownloadNotificationService::class.java)
                    intent.putExtra("command", "stop")
                    startForegroundService(intent)
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

        storageChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, STORAGE_CHANNEL)
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
                else -> result.notImplemented()
            }
        }

        localMediaChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, LOCAL_MEDIA_CHANNEL)
        localMediaChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
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

        pipChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PIP_CHANNEL)
        pipChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "isPipAvailable" -> {
                    result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && packageManager.hasSystemFeature("android.software.picture_in_picture"))
                }
                "enterPip" -> {
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            val builder = PictureInPictureParams.Builder()
                                .setAspectRatio(Rational(16, 9))
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

        statusChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, STATUS_CHANNEL)
        statusChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "checkAccess" -> {
                    try {
                        result.success(checkStatusAccess())
                    } catch (e: Exception) {
                        result.error("STATUS_ERROR", e.message, null)
                    }
                }
                "openAllFilesSettings" -> {
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
                "saveToGallery" -> {
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
                else -> result.notImplemented()
            }
        }

        appChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, APP_CHANNEL)
        appChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "getVersion" -> {
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
                "installApk" -> {
                    val path = call.argument<String>("path")
                    val file = if (path != null) File(path) else null
                    if (file == null || !file.exists()) {
                        result.error("ENOENT", "APK file not found", null)
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
                "closeActivity" -> {
                    runOnUiThread {
                        finish()
                        result.success(true)
                    }
                }
                "backgroundOverlay" -> {
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
                "scanMedia" -> {
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
                else -> result.notImplemented()
            }
        }

        val mediaDiagChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "vibegrab/media_diag")
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

        handleIntent(intent)
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

                val directPath = "/storage/emulated/0/$displayName"
                val directFile = java.io.File(directPath)
                val canWriteDirect = try {
                    directFile.exists() && directFile.canWrite()
                } catch (e: Exception) {
                    false
                }

                if (canWriteDirect) {
                    pendingPickResult?.success(mapOf(
                        "uri" to treeUri.toString(),
                        "path" to directPath,
                        "name" to displayName
                    ))
                } else {
                    pendingPickResult?.success(mapOf(
                        "uri" to treeUri.toString(),
                        "path" to "",
                        "name" to displayName
                    ))
                }
            } else {
                pendingPickResult?.success(null)
            }
            pendingPickResult = null
        }
    }

    private fun handleIntent(intent: Intent?) {
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

        cursor?.use {
            val idColumn = it.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
            val displayNameColumn = it.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME)
            val titleColumn = it.getColumnIndexOrThrow(MediaStore.MediaColumns.TITLE)
            val dataColumn = it.getColumnIndexOrThrow(MediaStore.MediaColumns.DATA)
            val sizeColumn = it.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE)
            val dateAddedColumn = it.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_ADDED)
            val durationColumn = it.getColumnIndexOrThrow(MediaStore.MediaColumns.DURATION)

            val albumColumn = if (mediaType == "audio") {
                try { it.getColumnIndexOrThrow(MediaStore.Audio.Media.ALBUM) } catch (e: Exception) { -1 }
            } else { -1 }

            val artistColumn = if (mediaType == "audio") {
                try { it.getColumnIndexOrThrow(MediaStore.Audio.Media.ARTIST) } catch (e: Exception) { -1 }
            } else { -1 }

            while (it.moveToNext()) {
                val id = it.getLong(idColumn)
                val displayName = it.getString(displayNameColumn) ?: ""
                val title = it.getString(titleColumn) ?: ""
                val data = it.getString(dataColumn) ?: ""
                val size = if (sizeColumn >= 0) it.getLong(sizeColumn) else 0L
                val dateAdded = if (dateAddedColumn >= 0) it.getLong(dateAddedColumn) else 0L
                val duration = if (durationColumn >= 0) it.getLong(durationColumn) else 0L

                val album = if (albumColumn >= 0) it.getString(albumColumn) ?: "" else ""
                val artist = if (artistColumn >= 0) it.getString(artistColumn) ?: "" else ""

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

                val fileSizeFormatted = formatFileSize(size)

                var thumbnailUrl: String? = null
                try {
                    val mediaUri = android.net.Uri.parse(uriString)
                    if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
                        val thumbBitmap = contentResolver.loadThumbnail(mediaUri, android.util.Size(320, 320), null)
                        val thumbFile = java.io.File(cacheDir, "thumb_${mediaType}_${id}.jpg")
                        thumbFile.outputStream().use { out ->
                            thumbBitmap.compress(android.graphics.Bitmap.CompressFormat.JPEG, 85, out)
                        }
                        thumbnailUrl = thumbFile.absolutePath
                        thumbBitmap.recycle()
                    } else {
                        @Suppress("DEPRECATION")
                        val thumbBitmap = MediaStore.Images.Thumbnails.getThumbnail(
                            contentResolver, id,
                            MediaStore.Images.Thumbnails.MINI_KIND, null
                        )
                        if (thumbBitmap != null) {
                            val thumbFile = java.io.File(cacheDir, "thumb_${mediaType}_${id}.jpg")
                            thumbFile.outputStream().use { out ->
                                thumbBitmap.compress(android.graphics.Bitmap.CompressFormat.JPEG, 85, out)
                            }
                            thumbnailUrl = thumbFile.absolutePath
                            thumbBitmap.recycle()
                        }
                    }
                } catch (e: Exception) {
                    android.util.Log.d("VibeGrab", "Thumbnail extraction failed for $displayName: ${e.message}")
                }

                val mediaItem = mapOf(
                    "filename" to displayName,
                    "title" to title,
                    "filePath" to data,
                    "fileSize" to size,
                    "fileSizeFormatted" to fileSizeFormatted,
                    "fileType" to mediaType,
                    "extension" to extension,
                    "createdAt" to createdAt,
                    "source" to "device",
                    "sourceType" to "local",
                    "contentUri" to uriString,
                    "album" to album,
                    "artist" to artist,
                    "duration" to duration,
                    "thumbnailPath" to thumbnailUrl
                )

                mediaList.add(mediaItem)
            }
        }
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
        if (!hasMediaReadPermission()) {
            return mapOf("state" to "need_media", "path" to null)
        }
        val readable = statusDirCandidates().firstOrNull { it.isDirectory && it.listFiles() != null }
        if (readable != null) {
            return mapOf("state" to "granted", "path" to readable.absolutePath)
        }
        if (Build.VERSION.SDK_INT >= 30 && !Environment.isExternalStorageManager()) {
            return mapOf("state" to "need_manage", "path" to null)
        }
        return mapOf("state" to "unsupported", "path" to null)
    }

    private fun saveToGallery(path: String, displayName: String, mime: String): Boolean {
        val src = File(path)
        if (!src.exists()) return false
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
                    true
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
            android.media.MediaScannerConnection.scanFile(
                this, arrayOf(dst.absolutePath), arrayOf(mime), null
            )
            true
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
