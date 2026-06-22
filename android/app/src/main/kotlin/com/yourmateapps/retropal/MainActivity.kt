package com.yourmateapps.retropal

import android.app.ActivityManager
import android.app.UiModeManager
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.util.Log
import android.webkit.MimeTypeMap
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterShellArgs
import io.flutter.plugin.common.MethodChannel
import android.content.ContentUris
import java.io.File

class MainActivity : FlutterFragmentActivity() {
    private val CHANNEL = "com.yourmateapps.retropal/device"
    private var pendingFilePath: String? = null

    // SAF folder import callback
    private var importRomsResultHandler: ((List<String>?) -> Unit)? = null

    // Texture bridge for zero-copy frame delivery
    private var textureBridge: YageTextureBridge? = null

    // True when we supplied our own FlutterEngine in provideFlutterEngine()
    // (TV/32-bit, Impeller off). That engine already registers plugins in its
    // constructor, so configureFlutterEngine() must NOT call super (which would
    // register them a second time). The default phone path keeps calling super.
    private var providedOwnEngine = false

    // Callback for picking folder (setup) — returns URI only
    private var pickFolderResultHandler: ((String?) -> Unit)? = null

    // Callback for picking one BIOS file — returns a temporary readable path
    private var pickBiosFileResultHandler: ((String?) -> Unit)? = null

    companion object {
        private const val SAF_IMPORT_FOLDER_CODE = 2001
        private const val SAF_PICK_FOLDER_CODE = 2002
        private const val SAF_PICK_BIOS_FILE_CODE = 2003
        private val ROM_EXTENSIONS = setOf(
            "gba", "gb", "gbc", "sgb",
            "nes", "unf", "unif",
            "sfc", "smc",
            "sms", "gg", "sg",
            "md", "gen", "smd", "bin",
            "pce", "sgx", "cue",
            "z64", "n64", "v64",
            "ngp", "ngc", "ws", "wsc",
            "a26",
            "vb",
            "tic",
            "p8",
            // Nintendo DS
            "nds",
            // Mattel Intellivision
            "int", "itv", "rom",
            // Archives, including PS1 ZIPs with .cue + .bin tracks.
            "zip"
        )

        /** Battery-save extensions some cores write themselves (e.g. PS1 memory
         *  card 1 ".mcr"). Kept in sync with EmulatorService._coreManagedSaveExts
         *  so import (here) and export (Dart) cover the same files. Lowercase,
         *  including the leading dot. */
        private val CORE_MANAGED_SAVE_EXTS = setOf(
            ".srm", ".mcr", ".sra", ".eep", ".fla", ".mpk", ".bram", ".brm"
        )

        /** Returns true if a filename matches a known ROM extension, including
         *  PICO-8's `.p8.png` double-extension carts. */
        fun isRomFilename(name: String): Boolean {
            val lower = name.lowercase()
            if (lower.endsWith(".p8.png")) return true
            val ext = lower.substringAfterLast('.', "")
            return ext in ROM_EXTENSIONS
        }
    }

    /**
     * Workaround for Android 8.x framework bug where Activity.isTopOfTask()
     * throws IllegalArgumentException during onResume() IPC. This is a known
     * AOSP issue with no upstream fix for API 26-27.
     */
    override fun onResume() {
        try {
            super.onResume()
        } catch (e: IllegalArgumentException) {
            // Swallow the framework-level IPC failure. The activity will still
            // function correctly — isTopOfTask() is only used for internal
            // bookkeeping (e.g. whether to show the task root activity).
            android.util.Log.w("MainActivity", "onResume: isTopOfTask IPC failed", e)
        }
    }

    /**
     * Whether this device should opt OUT of Impeller (use the legacy Skia/GLES
     * renderer). True only on TV / 32-bit devices.
     *
     * Impeller (Vulkan) is the modern default and gives the sharpest, smoothest
     * result on 64-bit phones — forcing Skia there makes the emulator's external
     * game Texture sample softer and janky ("blurry video" on phones such as the
     * moto g 60). But Impeller's Vulkan backend crashes at startup on the 32-bit
     * Mali GPUs in some Android TV boxes (the original Sony BRAVIA crash_dump32
     * at the home screen). So opt out only there, and keep Impeller everywhere
     * else.
     */
    private fun shouldDisableImpeller(): Boolean {
        val isTelevision = try {
            val uiModeManager = getSystemService(Context.UI_MODE_SERVICE) as UiModeManager
            (uiModeManager.currentModeType and Configuration.UI_MODE_TYPE_MASK) ==
                Configuration.UI_MODE_TYPE_TELEVISION
        } catch (e: Exception) {
            false
        }
        // No 64-bit ABI support → old/weak SoC (e.g. the 32-bit Sony BRAVIA)
        // whose Vulkan driver is the unstable one.
        val is64BitCapable = (Build.SUPPORTED_64_BIT_ABIS?.isNotEmpty() == true)
        return isTelevision || !is64BitCapable
    }

    /**
     * Per-device renderer selection.
     *
     * FlutterFragmentActivity exposes no getFlutterShellArgs() to override (only
     * FlutterActivity does), so we provide the FlutterEngine ourselves with an
     * extra shell arg. Returning null keeps the stock engine path (Impeller on)
     * for phones. For TV/32-bit we build the engine with `--no-enable-impeller`.
     *
     * The engine is built with automaticallyRegisterPlugins = true, so it
     * registers all plugins (Firebase, IAP, etc.) itself in the constructor;
     * configureFlutterEngine() then skips super for this engine so nothing
     * double-registers. (The phone path returns null → stock engine + super.)
     */
    override fun provideFlutterEngine(context: Context): FlutterEngine? {
        if (!shouldDisableImpeller()) {
            Log.i("MainActivity", "Renderer: Impeller enabled (Vulkan)")
            return null
        }
        val shellArgs = FlutterShellArgs.fromIntent(intent)
        shellArgs.add("--no-enable-impeller")
        Log.i("MainActivity", "Renderer: Impeller disabled (Skia/GLES) for TV/32-bit")
        providedOwnEngine = true
        return FlutterEngine(context, shellArgs.toArray(), true)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        // Stock (phone) engine registers plugins via super; our own TV/32-bit
        // engine already did so in its constructor — calling super again would
        // double-register.
        if (!providedOwnEngine) {
            super.configureFlutterEngine(flutterEngine)
        }

        // Initialize texture bridge for zero-copy frame delivery
        textureBridge = YageTextureBridge(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isTelevision" -> {
                        val uiModeManager = getSystemService(Context.UI_MODE_SERVICE) as UiModeManager
                        val isTV = (uiModeManager.currentModeType and Configuration.UI_MODE_TYPE_MASK) == Configuration.UI_MODE_TYPE_TELEVISION
                        result.success(isTV)
                    }
                    "getDeviceMemoryMB" -> {
                        val memInfo = ActivityManager.MemoryInfo()
                        (getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).getMemoryInfo(memInfo)
                        result.success((memInfo.totalMem / (1024 * 1024)).toInt())
                    }
                    "checkGooglePlayServices" -> {
                        // Check if Google Play Services is available and up-to-date.
                        // Returns "available" if ready, or an error description string.
                        val availability = GoogleApiAvailability.getInstance()
                        val status = availability.isGooglePlayServicesAvailable(this)
                        if (status == ConnectionResult.SUCCESS) {
                            result.success("available")
                        } else {
                            val msg = availability.getErrorString(status)
                            result.success("unavailable:$status:$msg")
                        }
                    }
                    "getOpenFilePath" -> {
                        val path = pendingFilePath
                        pendingFilePath = null
                        result.success(path)
                    }

                    // ── SAF-based folder import ──
                    // Opens the system folder picker, recursively scans for ROM files,
                    // copies them to internal storage, returns list of internal paths.
                    "importRomsFromFolder" -> {
                        // Cancel any previous pending import (user tapped again before
                        // the first picker dismissed — that Dart future gets null).
                        importRomsResultHandler?.let { old ->
                            try { old.invoke(null) } catch (_: IllegalStateException) {}
                        }
                        importRomsResultHandler = { paths ->
                            try { result.success(paths) } catch (_: IllegalStateException) {}
                        }
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                            addFlags(
                                Intent.FLAG_GRANT_READ_URI_PERMISSION
                                    or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                                    or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
                            )
                        }
                        startActivityForResult(intent, SAF_IMPORT_FOLDER_CODE)
                    }

                    // ── Pick folder for setup (returns URI only, no import) ──
                    "pickRomsFolder" -> {
                        pickFolderResultHandler?.let { old ->
                            try { old.invoke(null) } catch (_: IllegalStateException) {}
                        }
                        pickFolderResultHandler = { uri ->
                            try { result.success(uri) } catch (_: IllegalStateException) {}
                        }
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                            addFlags(
                                Intent.FLAG_GRANT_READ_URI_PERMISSION
                                    or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                                    or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
                            )
                        }
                        startActivityForResult(intent, SAF_PICK_FOLDER_CODE)
                    }

                    // ── Pick BIOS file ──
                    // FilePicker can be over-aggressive on some Android providers and
                    // show only common documents. Use a direct SAF intent with binary
                    // MIME hints, then copy the selected URI to cache and return a path.
                    "pickBiosFile" -> {
                        pickBiosFileResultHandler?.let { old ->
                            try { old.invoke(null) } catch (_: IllegalStateException) {}
                        }
                        pickBiosFileResultHandler = { path ->
                            try { result.success(path) } catch (_: IllegalStateException) {}
                        }
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "*/*"
                            putExtra(
                                Intent.EXTRA_MIME_TYPES,
                                arrayOf(
                                    "application/octet-stream",
                                    "application/x-binary",
                                    "application/x-rom",
                                    "application/x-msdos-program",
                                    "application/x-executable",
                                    "application/*",
                                    "*/*"
                                )
                            )
                            addFlags(
                                Intent.FLAG_GRANT_READ_URI_PERMISSION
                                    or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
                            )
                        }
                        startActivityForResult(
                            Intent.createChooser(intent, "Select BIOS file"),
                            SAF_PICK_BIOS_FILE_CODE
                        )
                    }

                    // ── Import from persisted folder URI (no picker) ──
                    "importFromFolderUri" -> {
                        val treeUri = call.argument<String>("treeUri")
                        if (treeUri == null) {
                            result.success(emptyList<String>())
                            return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val uri = Uri.parse(treeUri)
                                val importedPaths = importRomsFromTree(uri)
                                runOnUiThread { result.success(importedPaths) }
                            } catch (e: Exception) {
                                e.printStackTrace()
                                runOnUiThread { result.success(emptyList<String>()) }
                            }
                        }.start()
                    }

                    // ── Copy a save file from user folder (SAF tree) to internal storage ──
                    // Used before loading a game: import .sav from user folder if it exists.
                    "copySaveFromUserFolder" -> {
                        val treeUri = call.argument<String>("treeUri")
                        val fileName = call.argument<String>("fileName")
                        val destPath = call.argument<String>("destPath")
                        if (treeUri == null || fileName == null || destPath == null) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val success = copyFileFromTreeByName(Uri.parse(treeUri), fileName, destPath)
                                runOnUiThread { result.success(success) }
                            } catch (e: Exception) {
                                e.printStackTrace()
                                runOnUiThread { result.success(false) }
                            }
                        }.start()
                    }

                    // ── Copy a save file from internal storage to user folder (SAF tree) ──
                    "copySaveToUserFolder" -> {
                        val treeUri = call.argument<String>("treeUri")
                        val sourcePath = call.argument<String>("sourcePath")
                        if (treeUri == null || sourcePath == null) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val success = copyFileToTree(Uri.parse(treeUri), sourcePath)
                                runOnUiThread { result.success(success) }
                            } catch (e: Exception) {
                                e.printStackTrace()
                                runOnUiThread { result.success(false) }
                            }
                        }.start()
                    }

                    // ── Internal ROM storage directory ──
                    "getInternalRomsDir" -> {
                        val romsDir = File(filesDir, "roms")
                        if (!romsDir.exists()) romsDir.mkdirs()
                        result.success(romsDir.absolutePath)
                    }

                    // ── URI permission (persist across app restarts) ──
                    "checkHasUriPermission" -> {
                        val uriString = call.argument<String>("uri")
                        if (uriString == null) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        result.success(checkHasUriPermission(Uri.parse(uriString)))
                    }
                    // Convert content:// or file:// URI to usable file path for emulator core.
                    // For content://, copies to internal storage and returns path.
                    "resolveUriToPath" -> {
                        val uriString = call.argument<String>("uri")
                        if (uriString == null) {
                            result.success(null)
                            return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val uri = Uri.parse(uriString)
                                val path = resolveUriToPath(uri)
                                runOnUiThread { result.success(path) }
                            } catch (e: Exception) {
                                e.printStackTrace()
                                runOnUiThread { result.success(null) }
                            }
                        }.start()
                    }

                    // ── MediaStore API (TV only, no MANAGE_EXTERNAL_STORAGE) ──
                    // Lists ROM files from all MediaStore-indexed folders (Downloads, etc.)
                    "listRomFilesFromMediaStore" -> {
                        Thread {
                            try {
                                val items = listRomFilesFromMediaStore()
                                runOnUiThread { result.success(items) }
                            } catch (e: Exception) {
                                e.printStackTrace()
                                runOnUiThread { result.success(emptyList<Map<String, Any>>()) }
                            }
                        }.start()
                    }
                    // Copies a content URI to internal storage, returns internal path
                    "copyUriToInternalStorage" -> {
                        val uriString = call.argument<String>("uri")
                        if (uriString == null) {
                            result.success(null)
                            return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val uri = Uri.parse(uriString)
                                val path = copyUriToInternalStorage(uri)
                                runOnUiThread { result.success(path) }
                            } catch (e: Exception) {
                                e.printStackTrace()
                                runOnUiThread { result.success(null) }
                            }
                        }.start()
                    }
                    // Batch copy: list of URIs -> list of internal paths
                    "copyUrisToInternalStorage" -> {
                        @Suppress("UNCHECKED_CAST")
                        val uris = call.argument<List<String>>("uris") ?: emptyList()
                        Thread {
                            try {
                                val paths = uris.mapNotNull { uriStr ->
                                    copyUriToInternalStorage(Uri.parse(uriStr))
                                }
                                runOnUiThread { result.success(paths) }
                            } catch (e: Exception) {
                                e.printStackTrace()
                                runOnUiThread { result.success(emptyList<String>()) }
                            }
                        }.start()
                    }

                    // ── Texture rendering — zero-copy frame delivery ──
                    "createGameTexture" -> {
                        val width = call.argument<Int>("width") ?: 240
                        val height = call.argument<Int>("height") ?: 160
                        val textureId = textureBridge?.createTexture(width, height)
                        result.success(textureId)
                    }
                    "destroyGameTexture" -> {
                        textureBridge?.destroy()
                        result.success(null)
                    }
                    "updateGameTextureSize" -> {
                        val width = call.argument<Int>("width") ?: 240
                        val height = call.argument<Int>("height") ?: 160
                        textureBridge?.updateSize(width, height)
                        result.success(null)
                    }

                    else -> result.notImplemented()
                }
            }

        handleIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    override fun onDestroy() {
        textureBridge?.destroy()
        textureBridge = null
        super.onDestroy()
    }

    private fun handleIntent(intent: Intent?) {
        if (intent?.action == Intent.ACTION_VIEW) {
            val uri = intent.data ?: return
            val path = resolveUriToPath(uri)
            if (path != null) {
                pendingFilePath = path
            }
        }
    }

    /**
     * Check if we have persistable URI permission for the given URI.
     * Used to verify stored folder URI is still valid across app restarts.
     */
    private fun checkHasUriPermission(uri: Uri): Boolean {
        return try {
            contentResolver.persistedUriPermissions.any { it.uri == uri }
        } catch (_: Exception) {
            false
        }
    }

    /**
     * Convert content:// or file:// URI to usable file path for emulator core.
     * For content:// URIs, copies to internal storage via ContentResolver.openInputStream
     * and returns the path. The emulator core requires a file path, not a stream.
     */
    private fun resolveUriToPath(uri: Uri): String? {
        if (uri.scheme == "file") return uri.path

        if (uri.scheme == "content") {
            try {
                val fileName = getFileName(uri) ?: "rom_${System.currentTimeMillis()}"
                val romsDir = File(filesDir, "roms")
                romsDir.mkdirs()
                val destFile = File(romsDir, fileName)

                contentResolver.openInputStream(uri)?.use { input ->
                    destFile.outputStream().use { output ->
                        input.copyTo(output)
                    }
                }
                return destFile.absolutePath
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }
        return null
    }

    private fun getFileName(uri: Uri): String? {
        var name: String? = null
        contentResolver.query(uri, null, null, null, null)?.use { cursor ->
            val nameIndex = cursor.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
            if (nameIndex >= 0 && cursor.moveToFirst()) {
                name = cursor.getString(nameIndex)
            }
        }
        return name
    }

    // ══════════════════════════════════════════════════════════════
    //  SAF folder scanning + import
    // ══════════════════════════════════════════════════════════════

    /**
     * ROM file with parent doc ID (for finding sibling save files).
     */
    private data class RomEntry(val fileUri: Uri, val name: String, val parentDocId: String)

    /**
     * Recursively scan a SAF document tree for ROM files and copy them
     * to the app's internal ROM directory. Also copies matching save files
     * (.sav, .ss0-.ss5, .ss0.png-.ss5.png, baseName_*.png) from the same folder.
     *
     * Streams processing: copies each ROM as soon as it's found instead of
     * building a full list first. Avoids OOM on low-RAM devices with 5000+ ROMs.
     */
    private fun importRomsFromTree(treeUri: Uri): List<String> {
        val romsDir = File(filesDir, "roms")
        if (!romsDir.exists()) romsDir.mkdirs()

        val importedPaths = mutableListOf<String>()

        // Guard: if the URI is a single document (not a tree), import it directly.
        // This happens when the user picks a file from Downloads instead of a folder.
        if (!DocumentsContract.isTreeUri(treeUri)) {
            try {
                val docId = DocumentsContract.getDocumentId(treeUri)
                // Extract filename from the document ID or URI path
                val name = docId.substringAfterLast('/').substringAfterLast(':')
                    .let { java.net.URLDecoder.decode(it, "UTF-8") }
                    .ifBlank { treeUri.lastPathSegment ?: "unknown" }

                if (isRomFilename(name)) {
                    val destFile = File(romsDir, name)
                    if (!destFile.exists()) {
                        contentResolver.openInputStream(treeUri)?.use { input ->
                            destFile.outputStream().buffered().use { output ->
                                input.copyTo(output, bufferSize = 8192)
                            }
                        }
                    }
                    if (destFile.exists()) {
                        importedPaths.add(destFile.absolutePath)
                    }
                }
            } catch (e: Exception) {
                Log.w("MainActivity", "importRomsFromTree: single document import failed", e)
            }
            return importedPaths
        }

        // Process each ROM as it's found — no full list in memory.
        // Use destFile.exists() per file instead of romsDir.listFiles() to avoid
        // loading thousands of filenames into memory on large libraries.
        scanTreeRecursive(treeUri, DocumentsContract.getTreeDocumentId(treeUri), null) { entry ->
            try {
                val destFile = File(romsDir, entry.name)

                if (destFile.exists()) {
                    importedPaths.add(destFile.absolutePath)
                    // Still copy matching saves — user may have pasted a .sav from another device
                    try {
                        copyMatchingSaves(treeUri, entry.parentDocId, entry.name, romsDir)
                    } catch (_: Exception) {}
                    return@scanTreeRecursive
                }

                contentResolver.openInputStream(entry.fileUri)?.use { input ->
                    destFile.outputStream().buffered().use { output ->
                        input.copyTo(output, bufferSize = 8192)
                    }
                }
                importedPaths.add(destFile.absolutePath)

                try {
                    copyMatchingSaves(treeUri, entry.parentDocId, entry.name, romsDir)
                } catch (_: Exception) {}
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }

        return importedPaths
    }

    /**
     * Copy a file from internal storage to the user's SAF document tree.
     * Used to sync battery saves and save states to the user folder.
     */
    private fun copyFileToTree(treeUri: Uri, sourcePath: String): Boolean {
        val sourceFile = File(sourcePath)
        if (!sourceFile.exists()) return false
        val fileName = sourceFile.name
        val docId = DocumentsContract.getTreeDocumentId(treeUri)
        val mimeType = getMimeType(fileName)
        return try {
            val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, docId)
            var targetDocId: String? = null
            val duplicateDocIds = mutableListOf<String>()

            fun isDuplicateVariant(name: String, canonicalName: String): Boolean {
                if (name == canonicalName) return false
                val dotIndex = canonicalName.lastIndexOf('.')
                val base = if (dotIndex > 0) canonicalName.substring(0, dotIndex) else canonicalName
                val ext = if (dotIndex > 0) canonicalName.substring(dotIndex) else ""
                val duplicatePrefix = "$base ("
                val duplicateSuffix = ")$ext"
                return name.startsWith(duplicatePrefix) && name.endsWith(duplicateSuffix)
            }
            
            // Search for existing file
            contentResolver.query(
                childrenUri,
                arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME),
                null, null, null
            )?.use { cursor ->
                val idCol = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
                val nameCol = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
                while (cursor.moveToNext()) {
                    val name = cursor.getString(nameCol)
                    val id = cursor.getString(idCol)
                    if (name == fileName) {
                        targetDocId = id
                    } else if (isDuplicateVariant(name, fileName)) {
                        duplicateDocIds.add(id)
                    }
                }
            }

            // Clean up provider-created duplicate variants such as "file (1).sav".
            for (duplicateId in duplicateDocIds) {
                try {
                    val duplicateUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, duplicateId)
                    DocumentsContract.deleteDocument(contentResolver, duplicateUri)
                } catch (_: Exception) {}
            }

            val childUri: Uri
            if (targetDocId != null) {
                // Overwrite existing file
                childUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, targetDocId)
            } else {
                // Create new file
                val docUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, docId)
                childUri = DocumentsContract.createDocument(contentResolver, docUri, mimeType, fileName)
                    ?: return false
            }

            contentResolver.openOutputStream(childUri, "w")?.use { output ->
                sourceFile.inputStream().use { input ->
                    input.copyTo(output)
                }
            }
            true
        } catch (e: Exception) {
            e.printStackTrace()
            false
        }
    }

    private fun getMimeType(fileName: String): String {
        val ext = fileName.substringAfterLast('.', "")
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "application/octet-stream"
    }

    /**
     * Recursively find a file by name in the SAF tree and copy it to destPath.
     * Returns true if found and copied.

     */
    private fun copyFileFromTreeByName(treeUri: Uri, fileName: String, destPath: String): Boolean {
        val destFile = File(destPath)
        destFile.parentFile?.mkdirs()
        return findAndCopyFileInTree(treeUri, DocumentsContract.getTreeDocumentId(treeUri), fileName, destFile)
    }

    private fun findAndCopyFileInTree(treeUri: Uri, parentDocId: String, targetFileName: String, destFile: File): Boolean {
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentDocId)
        try {
            contentResolver.query(
                childrenUri,
                arrayOf(
                    DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                    DocumentsContract.Document.COLUMN_MIME_TYPE
                ),
                null, null, null
            )?.use { cursor ->
                val idCol = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
                val nameCol = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
                val mimeCol = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_MIME_TYPE)

                while (cursor.moveToNext()) {
                    val docId = cursor.getString(idCol)
                    val name = cursor.getString(nameCol) ?: continue
                    val mime = cursor.getString(mimeCol)

                    if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                        if (findAndCopyFileInTree(treeUri, docId, targetFileName, destFile)) return true
                    } else if (name == targetFileName) {
                        val fileUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, docId)
                        contentResolver.openInputStream(fileUri)?.use { input ->
                            destFile.outputStream().use { output ->
                                input.copyTo(output)
                            }
                        }
                        return true
                    }
                }
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
        return false
    }

    /**
     * Copy save files that match the ROM from the same directory.
     * Patterns: baseName.sav, romBase.ss0-5, romBase.ss0-5.png, baseName_*.png
     */
    private fun copyMatchingSaves(treeUri: Uri, parentDocId: String, romName: String, romsDir: File) {
        val baseName = romName.substringBeforeLast('.', romName)
        val savePrefixes = listOf(
            "$baseName.sav",
            "$romName.ss0", "$romName.ss1", "$romName.ss2",
            "$romName.ss3", "$romName.ss4", "$romName.ss5",
            "$romName.ss0.png", "$romName.ss1.png", "$romName.ss2.png",
            "$romName.ss3.png", "$romName.ss4.png", "$romName.ss5.png"
        ).toSet()
        val screenshotPrefix = "${baseName}_"
        val screenshotSuffix = ".png"

        val childUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentDocId)
        try {
            contentResolver.query(
                childUri,
                arrayOf(
                    DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                    DocumentsContract.Document.COLUMN_MIME_TYPE
                ),
                null, null, null
            )?.use { cursor ->
                val idCol = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
                val nameCol = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)

                while (cursor.moveToNext()) {
                    val docId = cursor.getString(idCol)
                    val name = cursor.getString(nameCol) ?: continue
                    val mime = cursor.getString(cursor.getColumnIndex(DocumentsContract.Document.COLUMN_MIME_TYPE))

                    if (mime == DocumentsContract.Document.MIME_TYPE_DIR) continue

                    // Core-managed battery saves the core writes itself (e.g. PS1
                    // memory card 1 ".mcr"), matched by save extension + ROM base.
                    // Mirrors EmulatorService._isCoreManagedSaveSibling on the Dart
                    // side so backup (export) and restore (this import) agree.
                    val isCoreManagedSave = run {
                        val dot = name.lastIndexOf('.')
                        if (dot <= 0) {
                            false
                        } else {
                            val ext = name.substring(dot).lowercase()
                            val stem = name.substring(0, dot)
                            ext in CORE_MANAGED_SAVE_EXTS &&
                                (stem == baseName || stem.startsWith("${baseName}_"))
                        }
                    }

                    val shouldCopy = name in savePrefixes ||
                        (name.startsWith(screenshotPrefix) && name.endsWith(screenshotSuffix)) ||
                        isCoreManagedSave

                    if (shouldCopy) {
                        try {
                            val fileUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, docId)
                            val destFile = File(romsDir, name)
                            contentResolver.openInputStream(fileUri)?.use { input ->
                                destFile.outputStream().use { output ->
                                    input.copyTo(output)
                                }
                            }
                        } catch (_: Exception) {}
                    }
                }
            }
        } catch (_: Exception) {}
    }

    /**
     * Recursively scan ROM files inside the selected folder.
     * Enumerates all children of a SAF document tree node (including subdirectories),
     * invoking [onRomFound] for each ROM file that matches [ROM_EXTENSIONS].
     * [parentDocIdForSaves] is the doc ID of the directory containing these files (for save-file lookup).
     */
    private fun scanTreeRecursive(
        treeUri: Uri,
        parentDocId: String,
        parentDocIdForSaves: String?,
        onRomFound: (RomEntry) -> Unit
    ) {
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentDocId)
        val currentDirAsParent = parentDocIdForSaves ?: parentDocId

        try {
            contentResolver.query(
                childrenUri,
                arrayOf(
                    DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                    DocumentsContract.Document.COLUMN_MIME_TYPE
                ),
                null, null, null
            )?.use { cursor ->
                val idCol = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
                val nameCol = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
                val mimeCol = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_MIME_TYPE)

                while (cursor.moveToNext()) {
                    val docId = cursor.getString(idCol)
                    val name = cursor.getString(nameCol) ?: continue
                    val mime = cursor.getString(mimeCol)

                    val isDirectory = mime == DocumentsContract.Document.MIME_TYPE_DIR
                    val mightBeDirectory = mime.isNullOrEmpty()

                    if (isDirectory) {
                        scanTreeRecursive(treeUri, docId, docId, onRomFound)
                    } else if (mightBeDirectory) {
                        val childUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, docId)
                        try {
                            contentResolver.query(childUri, null, null, null, null)?.use { childCursor ->
                                if (childCursor.moveToFirst()) {
                                    scanTreeRecursive(treeUri, docId, docId, onRomFound)
                                } else {
                                    if (isRomFilename(name)) {
                                        val fileUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, docId)
                                        onRomFound(RomEntry(fileUri, name, currentDirAsParent))
                                    }
                                }
                            } ?: run {
                                if (isRomFilename(name)) {
                                    val fileUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, docId)
                                    onRomFound(RomEntry(fileUri, name, currentDirAsParent))
                                }
                            }
                        } catch (_: Exception) {
                            if (isRomFilename(name)) {
                                val fileUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, docId)
                                onRomFound(RomEntry(fileUri, name, currentDirAsParent))
                            }
                        }
                    } else {
                        if (isRomFilename(name)) {
                            val fileUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, docId)
                            onRomFound(RomEntry(fileUri, name, currentDirAsParent))
                        }
                    }
                }
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    // ══════════════════════════════════════════════════════════════
    //  MediaStore API (TV — no MANAGE_EXTERNAL_STORAGE)
    //  Queries all indexed folders: Downloads, Documents, etc.
    // ══════════════════════════════════════════════════════════════

    /**
     * List ROM files from MediaStore (all indexed folders).
     * MediaStore indexes files recursively from Downloads, Documents, etc.
     * Returns list of maps: {uri, displayName, size, relativePath}
     * No storage permission required on Android 10+.
     */
    private fun listRomFilesFromMediaStore(): List<Map<String, Any>> {
        val items = mutableListOf<Map<String, Any>>()
        val projection = arrayOf(
            MediaStore.Files.FileColumns._ID,
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.SIZE
        ).let { cols ->
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                cols + MediaStore.MediaColumns.RELATIVE_PATH
            } else {
                cols
            }
        }

        // Build selection: DISPLAY_NAME LIKE '%.gba' OR DISPLAY_NAME LIKE '%.gb' ...
        // Add `%.p8.png` for PICO-8 carts (double extension).
        val likePatterns = ROM_EXTENSIONS.map { "%.$it" } + "%.p8.png"
        val selection = likePatterns.joinToString(" OR ") {
            "${MediaStore.MediaColumns.DISPLAY_NAME} LIKE ?"
        }
        val selectionArgs = likePatterns.toTypedArray()

        val collection = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL)
        } else {
            MediaStore.Files.getContentUri("external")
        }

        try {
            contentResolver.query(
                collection,
                projection,
                selection,
                selectionArgs,
                "${MediaStore.MediaColumns.DISPLAY_NAME} ASC"
            )?.use { cursor ->
                val idCol = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns._ID)
                val nameCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME)
                val sizeCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE)
                val pathCol = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    cursor.getColumnIndex(MediaStore.MediaColumns.RELATIVE_PATH)
                } else -1

                while (cursor.moveToNext()) {
                    val id = cursor.getLong(idCol)
                    val uri = ContentUris.withAppendedId(collection, id)
                    val name = cursor.getString(nameCol) ?: continue
                    val size = cursor.getLong(sizeCol)
                    val relativePath = if (pathCol >= 0) cursor.getString(pathCol) ?: "" else ""

                    items.add(mapOf(
                        "uri" to uri.toString(),
                        "displayName" to name,
                        "size" to size,
                        "relativePath" to relativePath
                    ))
                }
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }

        return items
    }

    /**
     * Copy a content URI to the app's internal ROM directory.
     * Returns the internal file path, or null on failure.
     */
    private fun copyUriToInternalStorage(uri: Uri): String? {
        val romsDir = File(filesDir, "roms")
        if (!romsDir.exists()) romsDir.mkdirs()

        val fileName = getFileName(uri) ?: "rom_${System.currentTimeMillis()}"
        val destFile = File(romsDir, fileName)

        return try {
            contentResolver.openInputStream(uri)?.use { input ->
                destFile.outputStream().buffered().use { output ->
                    input.copyTo(output, bufferSize = 8192)
                }
                destFile.absolutePath
            } ?: null
        } catch (e: Exception) {
            e.printStackTrace()
            null
        }
    }

    /**
     * Copy a picked BIOS document to a short-lived cache file so Dart can import
     * it via the existing file-path based BIOS service.
     */
    private fun copyBiosUriToCache(uri: Uri): String? {
        if (uri.scheme == "file") return uri.path

        val biosDir = File(cacheDir, "bios_picker")
        if (!biosDir.exists()) biosDir.mkdirs()
        biosDir.listFiles()?.forEach { file ->
            try {
                file.delete()
            } catch (_: Exception) {}
        }

        val originalName = getFileName(uri) ?: "bios_${System.currentTimeMillis()}.bin"
        val safeName = originalName.replace(Regex("[\\\\/:*?\"<>|]"), "_")
        val destFile = File(biosDir, safeName)

        return try {
            contentResolver.openInputStream(uri)?.use { input ->
                destFile.outputStream().buffered().use { output ->
                    input.copyTo(output, bufferSize = 8192)
                }
                destFile.absolutePath
            } ?: null
        } catch (e: Exception) {
            e.printStackTrace()
            null
        }
    }

    // ══════════════════════════════════════════════════════════════
    //  Activity result handling
    // ══════════════════════════════════════════════════════════════

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        // Handle our custom SAF request codes BEFORE super, so that
        // flutter plugins (e.g. file_picker) don't receive them and crash
        // trying to interpret a tree URI as a document URI.
        if (requestCode == SAF_IMPORT_FOLDER_CODE ||
            requestCode == SAF_PICK_FOLDER_CODE ||
            requestCode == SAF_PICK_BIOS_FILE_CODE) {
            handleCustomSafResult(requestCode, resultCode, data)
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    private fun handleCustomSafResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == SAF_IMPORT_FOLDER_CODE) {
            // Atomically grab and null the handler so it can only fire once.
            val handler = importRomsResultHandler
            importRomsResultHandler = null
            if (handler == null) return

            if (resultCode == RESULT_OK && data?.data != null) {
                val treeUri = data.data!!

                // Persist read permission so folder can be re-scanned later
                try {
                    contentResolver.takePersistableUriPermission(
                        treeUri, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                    )
                } catch (_: Exception) {}

                // Scan + copy in background thread to avoid blocking UI
                Thread {
                    val importedPaths = importRomsFromTree(treeUri)
                    runOnUiThread {
                        try {
                            handler.invoke(importedPaths)
                        } catch (e: IllegalStateException) {
                            Log.w("MainActivity", "SAF_IMPORT reply already submitted", e)
                        }
                    }
                }.start()
            } else {
                try {
                    handler.invoke(null)
                } catch (e: IllegalStateException) {
                    Log.w("MainActivity", "SAF_IMPORT cancel reply already submitted", e)
                }
            }
            return
        }

        if (requestCode == SAF_PICK_FOLDER_CODE) {
            val handler = pickFolderResultHandler
            pickFolderResultHandler = null
            if (handler == null) return

            if (resultCode == RESULT_OK && data?.data != null) {
                val treeUri = data.data!!

                // Persist read+write so we can sync saves to this folder
                try {
                    contentResolver.takePersistableUriPermission(
                        treeUri, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                    )
                } catch (_: Exception) {}

                try {
                    handler.invoke(treeUri.toString())
                } catch (e: IllegalStateException) {
                    Log.w("MainActivity", "SAF_PICK_FOLDER reply already submitted", e)
                }
            } else {
                try {
                    handler.invoke(null)
                } catch (e: IllegalStateException) {
                    Log.w("MainActivity", "SAF_PICK_FOLDER cancel reply already submitted", e)
                }
            }
            return
        }

        if (requestCode == SAF_PICK_BIOS_FILE_CODE) {
            val handler = pickBiosFileResultHandler
            pickBiosFileResultHandler = null
            if (handler == null) return

            if (resultCode == RESULT_OK && data?.data != null) {
                val fileUri = data.data!!
                try {
                    contentResolver.takePersistableUriPermission(
                        fileUri, Intent.FLAG_GRANT_READ_URI_PERMISSION
                    )
                } catch (_: Exception) {}

                Thread {
                    val path = copyBiosUriToCache(fileUri)
                    runOnUiThread {
                        try {
                            handler.invoke(path)
                        } catch (e: IllegalStateException) {
                            Log.w("MainActivity", "SAF_PICK_BIOS reply already submitted", e)
                        }
                    }
                }.start()
            } else {
                try {
                    handler.invoke(null)
                } catch (e: IllegalStateException) {
                    Log.w("MainActivity", "SAF_PICK_BIOS cancel reply already submitted", e)
                }
            }
        }
    }
}
