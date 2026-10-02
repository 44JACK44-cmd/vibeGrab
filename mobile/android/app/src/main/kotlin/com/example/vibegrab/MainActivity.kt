package com.example.vibegrab

import android.Manifest
import android.app.PictureInPictureParams
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.Settings
import android.util.Rational
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.text.SimpleDateFormat
import java.util.*

class MainActivity : FlutterActivity() {
    private val SHARE_CHANNEL = "com.example.vibegrab/share"
    private val DOWNLOAD_CHANNEL = "com.example.vibegrab/downloads"
    private val LOCAL_MEDIA_CHANNEL = "com.example.vibegrab/local_media"
    private val STORAGE_CHANNEL = "com.example.vibegrab/storage"
    private val PIP_CHANNEL = "com.example.vibegrab/pip"
    private val STATUS_CHANNEL = "com.example.vibegrab/status"
    private var shareChannel: MethodChannel? = null
    private var downloadChannel: MethodChannel? = null
    private var localMediaChannel: MethodChannel? = null
    private var storageChannel: MethodChannel? = null
    private var pipChannel: MethodChannel? = null
    private var statusChannel: MethodChannel? = null
    private var pipEventSink: EventChannel.EventSink? = null
    private var initialSharedUrl: String? = null
    private var pendingNotificationAction: Map<String, String?>? = null
    private var pendingPickResult: MethodChannel.Result? = null
    private val PICK_DIR_REQUEST = 1001
    private var isInPipMode = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        shareChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SHARE_CHANNEL)
        shareChannel?.setMethodCallHandler { call, result ->
            if (call.method == "getInitialSharedUrl") {
                result.success(initialSharedUrl)
                initialSharedUrl = null
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
                    try {
                        val mediaList = queryDeviceMedia()
                        result.success(mediaList)
                    } catch (e: Exception) {
                        result.error("MEDIA_QUERY_ERROR", e.message, null)
                    }
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

        handleIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
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
                if (shareChannel != null) {
                    shareChannel?.invokeMethod("onSharedUrl", sharedText)
                } else {
                    initialSharedUrl = sharedText
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

        if (Build.VERSION.SDK_INT >= 29) {
            val collection = if (isVideo) {
                MediaStore.Video.Media.EXTERNAL_CONTENT_URI
            } else {
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI
            }
            val relativePath = if (isVideo) "Movies/VibeGrab" else "Pictures/VibeGrab"
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
            val baseDir = if (isVideo) {
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MOVIES)
            } else {
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES)
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
