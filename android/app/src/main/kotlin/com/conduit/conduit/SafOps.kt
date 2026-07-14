package com.conduit.conduit

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import android.webkit.MimeTypeMap
import androidx.documentfile.provider.DocumentFile
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.FileInputStream

/**
 * SAF (Storage Access Framework) operations exposed to Dart over the
 * `conduit/saf` method channel. Every method takes the tree URI (the path
 * the user picked) plus a relative path within it.
 *
 * The Dart-side SafFileSystemAccess adapts these to the FileSystemAccess
 * interface used by the sync engine.
 *
 * ── Bug #4 fix (2026-06-24) ────────────────────────────────────────────────
 * Previously these methods resolved children via DocumentFile.findFile(), which
 * does a listFiles() + getName().equals(name) match. On this device's SAF
 * provider (OPPO/ColorOS) findFile is unreliable: it returns null for an
 * existing file, the old write/append then fell back to createFile(), and the
 * provider mints a sibling "name (1)", "name (2)" instead of overwriting. The
 * fetched bytes landed in the sibling, the original stayed old, the scanner
 * never saw the new bytes, local_sha never advanced, and the engine re-fetched
 * every cycle → unbounded duplicate growth (PC 9 files, phone 26).
 *
 * Fix: every child resolution now goes through [findChildUri], a raw
 * ContentResolver query against COLUMN_DISPLAY_NAME (the provider's own
 * authoritative name list). createDocument() is used ONLY when a file
 * genuinely does not exist, so a "name (N)" can never be minted. This matches
 * LocalFileSystemAccess.write on Windows (true in-place overwrite), which is
 * the FileSystemAccess.write contract.
 */
object SafOps {

    /**
     * The single replacement for DocumentFile.findFile(). Queries the SAF
     * provider directly for the child whose COLUMN_DISPLAY_NAME exactly equals
     * [name] and returns its document URI, or null if none exists.
     *
     * Reliable where findFile is not: no local caching (always asks the
     * provider fresh), exact match on the provider's own stored name (immune to
     * MIME/suffix mangling), and never creates anything (so can never mint a
     * "name (N)" sibling). An exact match will NOT match "name (1)".
     */
    private fun findChildUri(ctx: Context, parentUri: Uri, name: String): Uri? {
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
            parentUri,
            DocumentsContract.getDocumentId(parentUri)
        )
        ctx.contentResolver.query(
            childrenUri,
            arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME
            ),
            null, null, null
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                if (cursor.getString(1) == name) {
                    return DocumentsContract.buildDocumentUriUsingTree(
                        parentUri,
                        cursor.getString(0)
                    )
                }
            }
        }
        return null
    }

    /** Resolve a relative path like "sub/file.txt" within the tree to a document URI. */
    private fun resolve(ctx: Context, treeUriStr: String, relPath: String): Uri? {
        val root = DocumentFile.fromTreeUri(ctx, Uri.parse(treeUriStr)) ?: return null
        if (relPath.isEmpty()) return root.uri
        var curUri = root.uri
        for (seg in relPath.split('/').filter { it.isNotEmpty() }) {
            curUri = findChildUri(ctx, curUri, seg) ?: return null
        }
        return curUri
    }

    /**
     * Ensure parent dirs exist, creating them as needed. Returns the URI of the
     * deepest parent directory. Uses [findChildUri] for traversal so directory
     * creation cannot mint "subdir (1)" on providers that mangle dir names.
     */
    private fun ensureParents(ctx: Context, treeUriStr: String, relPath: String): Uri {
        val treeUri = Uri.parse(treeUriStr)
        val root = DocumentFile.fromTreeUri(ctx, treeUri)
            ?: throw IllegalStateException("Cannot open SAF tree: $treeUriStr")
        var curUri = root.uri
        val segments = relPath.split('/').dropLast(1).filter { it.isNotEmpty() }
        for (seg in segments) {
            curUri = findChildUri(ctx, curUri, seg) ?: run {
                // Genuinely new subdirectory.
                DocumentsContract.createDocument(
                    ctx.contentResolver,
                    curUri,
                    DocumentsContract.Document.MIME_TYPE_DIR,
                    seg
                ) ?: throw IllegalStateException("Failed to create SAF directory: $seg")
            }
        }
        return curUri
    }

    /** Resolve the EXISTING file at [relPath] to a document URI, or null. */
    private fun resolveFile(ctx: Context, treeUriStr: String, relPath: String): Uri? {
        val uri = resolve(ctx, treeUriStr, relPath) ?: return null
        // Confirm it is a file (not a directory) via the provider.
        val isFile = ctx.contentResolver.query(
            uri,
            arrayOf(DocumentsContract.Document.COLUMN_MIME_TYPE),
            null, null, null
        )?.use { c ->
            c.moveToFirst() &&
                c.getString(0) != DocumentsContract.Document.MIME_TYPE_DIR
        } ?: false
        return if (isFile) uri else null
    }

    fun handle(ctx: Context, call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "listFiles" -> {
                    val tree = call.argument<String>("treeUri")!!
                    val out = ArrayList<String>()
                    listRecursive(ctx, treeFromUri(ctx, tree), "", out)
                    result.success(out)
                }
                "listFilesWithStat" -> {
                    // Battery fix (Roadmap Phase 0.6): one ContentResolver query PER
                    // DIRECTORY instead of listFiles() + one "stat" round trip per
                    // file (each "stat" was itself several queries: path-segment
                    // resolution via findChildUri, a MIME check, then
                    // DocumentFile.length()/lastModified(), which are each their
                    // own lazy query). The Dart-side FolderWatcher polls every 4s
                    // while a peer is connected, so on a folder with hundreds of
                    // files the old path meant thousands of Binder calls every
                    // 4 seconds. Returns path+size+mtime for every file in one
                    // recursive pass.
                    val tree = call.argument<String>("treeUri")!!
                    val out = ArrayList<Map<String, Any>>()
                    listRecursiveWithStat(ctx, treeFromUri(ctx, tree).uri, "", out)
                    result.success(out)
                }
                "stat" -> {
                    val tree = call.argument<String>("treeUri")!!
                    val rel = call.argument<String>("relPath") ?: ""
                    val uri = resolveFile(ctx, tree, rel)
                    if (uri == null) {
                        result.success(null)
                    } else {
                        val doc = DocumentFile.fromSingleUri(ctx, uri)
                        if (doc == null || !doc.isFile) {
                            result.success(null)
                        } else {
                            result.success(
                                mapOf(
                                    "size" to doc.length(),
                                    "mtime" to doc.lastModified()
                                )
                            )
                        }
                    }
                }
                "read" -> {
                    val tree = call.argument<String>("treeUri")!!
                    val rel = call.argument<String>("relPath")!!
                    val offset = call.argument<Int>("offset") ?: 0
                    val uri = resolveFile(ctx, tree, rel)
                    if (uri == null) {
                        result.error("not_found", "no such file: $rel", null)
                        return
                    }
                    ctx.contentResolver.openInputStream(uri).use { ins ->
                        if (ins == null) {
                            result.error("io", "cannot open input stream", null)
                            return
                        }
                        if (offset > 0) ins.skip(offset.toLong())
                        val buf = ByteArrayOutputStream()
                        val tmp = ByteArray(64 * 1024)
                        while (true) {
                            val n = ins.read(tmp)
                            if (n <= 0) break
                            buf.write(tmp, 0, n)
                        }
                        result.success(buf.toByteArray())
                    }
                }
                "write" -> {
                    val tree = call.argument<String>("treeUri")!!
                    val rel = call.argument<String>("relPath")!!
                    val data = call.argument<ByteArray>("data")!!
                    val name = rel.substringAfterLast('/')
                    val parentUri = ensureParents(ctx, tree, rel)
                    // Overwrite in place if the exact-named file exists; only
                    // create when genuinely absent (never mints "name (N)").
                    val targetUri: Uri = findChildUri(ctx, parentUri, name)
                        ?: DocumentsContract.createDocument(
                            ctx.contentResolver,
                            parentUri,
                            "application/octet-stream",
                            name
                        ) ?: throw IllegalStateException(
                            "SAF createDocument returned null for '$name'"
                        )
                    // "wt" = open for write, truncate to zero first.
                    ctx.contentResolver.openOutputStream(targetUri, "wt").use { os ->
                        os?.write(data)
                        os?.flush()
                    }
                    result.success(true)
                }
                "append" -> {
                    val tree = call.argument<String>("treeUri")!!
                    val rel = call.argument<String>("relPath")!!
                    val data = call.argument<ByteArray>("data")!!
                    val name = rel.substringAfterLast('/')
                    val parentUri = ensureParents(ctx, tree, rel)
                    val targetUri: Uri = findChildUri(ctx, parentUri, name)
                        ?: DocumentsContract.createDocument(
                            ctx.contentResolver,
                            parentUri,
                            "application/octet-stream",
                            name
                        ) ?: throw IllegalStateException(
                            "SAF createDocument returned null for '$name'"
                        )
                    // "wa" = open for write, append (do NOT truncate).
                    ctx.contentResolver.openOutputStream(targetUri, "wa").use { os ->
                        os?.write(data)
                        os?.flush()
                    }
                    result.success(true)
                }
                "delete" -> {
                    val tree = call.argument<String>("treeUri")!!
                    val rel = call.argument<String>("relPath")!!
                    val uri = resolveFile(ctx, tree, rel)
                    val ok = uri != null &&
                        DocumentsContract.deleteDocument(ctx.contentResolver, uri)
                    result.success(ok)
                }
                "moveToVault" -> {
                    val tree = call.argument<String>("treeUri")!!
                    val rel = call.argument<String>("relPath")!!
                    val stamp = android.text.format.DateFormat.format(
                        "yyyy-MM-dd_HH-mm-ss", System.currentTimeMillis()
                    ).toString()
                    val name = rel.substringAfterLast('/')
                    val base = name.substringBeforeLast('.', name)
                    val ext = if (name.contains('.')) "." + name.substringAfterLast('.') else ""
                    val vaultRel = ".syncversions/${rel.substringBeforeLast('/', "")}/$base.$stamp$ext"
                    val srcUri = resolveFile(ctx, tree, rel)
                    if (srcUri == null) {
                        result.success(null)
                        return
                    }
                    val parentUri = ensureParents(ctx, tree, vaultRel)
                    // Create the vault destination (timestamped, so unique) and
                    // copy bytes, then delete the original. Same overwrite-safe
                    // createDocument as write/append.
                    val destUri = DocumentsContract.createDocument(
                        ctx.contentResolver,
                        parentUri,
                        "application/octet-stream",
                        vaultRel.substringAfterLast('/')
                    ) ?: throw IllegalStateException(
                        "SAF createDocument returned null for vault dest"
                    )
                    ctx.contentResolver.openInputStream(srcUri).use { ins ->
                        ctx.contentResolver.openOutputStream(destUri, "wt").use { os ->
                            val tmp = ByteArray(64 * 1024)
                            while (true) {
                                val n = ins!!.read(tmp)
                                if (n <= 0) break
                                os!!.write(tmp, 0, n)
                            }
                        }
                    }
                    DocumentsContract.deleteDocument(ctx.contentResolver, srcUri)
                    result.success(vaultRel)
                }
                // Phase 3d: read a raw content:// URI that arrived via the share
                // sheet. These are not tree-based (no treeUri), just a single
                // document URI that the sending app has already granted us
                // short-lived read permission to. Returns the file bytes.
                // NOTE: for small files only. Large files should use
                // readSharedUriBlock + getSharedUriSize to avoid blocking
                // the platform thread for seconds (connection-loss bug fix).
                "readSharedUri" -> {
                    val uriStr = call.argument<String>("uri")!!
                    val uri = Uri.parse(uriStr)
                    ctx.contentResolver.openInputStream(uri).use { ins ->
                        if (ins == null) {
                            result.error("io", "cannot open shared URI: $uriStr", null)
                            return
                        }
                        val buf = ByteArrayOutputStream()
                        val tmp = ByteArray(64 * 1024)
                        while (true) {
                            val n = ins.read(tmp)
                            if (n <= 0) break
                            buf.write(tmp, 0, n)
                        }
                        result.success(buf.toByteArray())
                    }
                }
                // Polish (Large-file fix): return only the file SIZE from the
                // ContentProvider without reading any bytes. Fast and never blocks
                // the platform thread. Used by the streaming send path to build the
                // block plan before any data is read.
                "getSharedUriSize" -> {
                    val uriStr = call.argument<String>("uri")!!
                    val uri = Uri.parse(uriStr)
                    var size: Long = -1
                    ctx.contentResolver.query(
                        uri,
                        arrayOf(android.provider.OpenableColumns.SIZE),
                        null, null, null
                    )?.use { c ->
                        if (c.moveToFirst()) {
                            size = c.getLong(0)
                        }
                    }
                    result.success(size)
                }
                // Polish (Large-file fix): read a specific byte range [offset,
                // offset+length) from a shared content:// URI. The Dart send path
                // calls this once per 1-MiB block rather than loading the whole
                // file at once, so the platform thread is never blocked for more
                // than the time it takes to read one block (~10-50 ms for a 1 MiB
                // block). This eliminates the socket-heartbeat stall that was
                // causing the connection to drop when sharing large files.
                "readSharedUriBlock" -> {
                    val uriStr = call.argument<String>("uri")!!
                    val offset = call.argument<Number>("offset")?.toLong() ?: 0L
                    val length = call.argument<Number>("length")?.toInt() ?: (1024 * 1024)
                    val uri = Uri.parse(uriStr)
                    val fast = readSharedUriBlockFast(ctx, uri, offset, length)
                    if (fast != null) {
                        result.success(fast)
                        return
                    }
                    ctx.contentResolver.openInputStream(uri).use { ins ->
                        if (ins == null) {
                            result.error("io", "cannot open shared URI: $uriStr", null)
                            return
                        }
                        var remaining = offset
                        while (remaining > 0) {
                            val skipped = ins.skip(remaining)
                            if (skipped <= 0) break
                            remaining -= skipped
                        }
                        val buf = ByteArrayOutputStream(length)
                        val tmp = ByteArray(64 * 1024)
                        var toRead = length
                        while (toRead > 0) {
                            val n = ins.read(tmp, 0, minOf(tmp.size, toRead))
                            if (n <= 0) break
                            buf.write(tmp, 0, n)
                            toRead -= n
                        }
                        result.success(buf.toByteArray())
                    }
                }
                // Phase 3d: resolve the display name for a raw content:// URI.
                // Returns the filename string (e.g. "photo.jpg") so the Dart
                // side can pass a proper name to sendAdHocFile.
                "getSharedUriName" -> {

                    val uriStr = call.argument<String>("uri")!!
                    val uri = Uri.parse(uriStr)
                    var name: String? = null
                    ctx.contentResolver.query(
                        uri,
                        arrayOf(android.provider.OpenableColumns.DISPLAY_NAME),
                        null, null, null
                    )?.use { c ->
                        if (c.moveToFirst()) {
                            name = c.getString(0)
                        }
                    }
                    result.success(name ?: uriStr.substringAfterLast('/'))
                }
                // Open a received file in the system viewer (notification tap).
                // [treeUri] is the SAF tree root; [relPath] is the file's relative
                // path within that tree. We resolve the document URI, query its
                // MIME type, and fire ACTION_VIEW. ctx must be an Activity so that
                // the launched viewer appears in the foreground.
                "openFile" -> {
                    val treeUriStr = call.argument<String>("treeUri")!!
                    val relPath = call.argument<String>("relPath")!!
                    val docUri = resolve(ctx, treeUriStr, relPath)
                    if (docUri == null) {
                        result.error("not_found", "File not found: $relPath", null)
                    } else {
                        // Resolve MIME type: extension first, provider type as
                        // fallback, then a generic binary stream type.
                        //
                        // Extension must come first, not last: every file this app
                        // writes via SAF (see createDocument calls above) is created
                        // with the literal type "application/octet-stream", so
                        // ctx.contentResolver.getType(docUri) always returns that
                        // non-null placeholder and a `providerType ?: extensionType`
                        // ordering would never reach the extension lookup — every
                        // received file would open (or fail to open) as a generic
                        // binary blob regardless of its real type.
                        val extMime = MimeTypeMap.getSingleton()
                            .getMimeTypeFromExtension(
                                relPath.substringAfterLast('.', "").lowercase()
                            )
                        val mimeType = extMime
                            ?: ctx.contentResolver.getType(docUri)
                            ?: "application/octet-stream"
                        val intent = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(docUri, mimeType)
                            addFlags(
                                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                Intent.FLAG_ACTIVITY_NEW_TASK
                            )
                        }
                        try {
                            ctx.startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("no_handler", "No app to open $mimeType: ${e.message}", null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("saf_error", e.message, null)
        }
    }


    private fun readSharedUriBlockFast(
        ctx: Context,
        uri: Uri,
        offset: Long,
        length: Int
    ): ByteArray? {
        return try {
            ctx.contentResolver.openAssetFileDescriptor(uri, "r")?.use { afd ->
                FileInputStream(afd.fileDescriptor).use { fis ->
                    fis.channel.position(afd.startOffset + offset)
                    val buf = ByteArrayOutputStream(length)
                    val tmp = ByteArray(64 * 1024)
                    var toRead = length
                    while (toRead > 0) {
                        val n = fis.read(tmp, 0, minOf(tmp.size, toRead))
                        if (n <= 0) break
                        buf.write(tmp, 0, n)
                        toRead -= n
                    }
                    buf.toByteArray()
                }
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun treeFromUri(ctx: Context, treeUriStr: String): DocumentFile =
        DocumentFile.fromTreeUri(ctx, Uri.parse(treeUriStr))
            ?: throw IllegalStateException("Cannot open SAF tree: $treeUriStr")

    private fun listRecursive(
        ctx: Context,
        root: DocumentFile,
        prefix: String,
        out: ArrayList<String>
    ) {
        if (!root.isDirectory) return
        for (child in root.listFiles()) {
            val childPath = if (prefix.isEmpty()) child.name!! else "$prefix/${child.name!!}"
            if (child.isDirectory) {
                if (child.name == ".syncstate" || child.name == ".syncversions") continue
                listRecursive(ctx, child, childPath, out)
            } else if (child.isFile) {
                out.add(childPath)
            }
        }
    }

    /**
     * Same traversal as [listRecursive], but fetches DOCUMENT_ID, DISPLAY_NAME,
     * MIME_TYPE, LAST_MODIFIED, and SIZE in a single ContentResolver query per
     * directory, instead of using DocumentFile.listFiles() (which only fetches
     * the child URI list) plus a separate lazy query on EACH child for
     * isDirectory/isFile/length()/lastModified(). [dirUri] doubles as both the
     * current directory and the tree reference for the next level down — a
     * document URI built via buildDocumentUriUsingTree() carries its tree's
     * authority with it, so buildChildDocumentsUriUsingTree(dirUri, ...) is
     * valid at any depth, exactly like the existing findChildUri() above.
     */
    private fun listRecursiveWithStat(
        ctx: Context,
        dirUri: Uri,
        prefix: String,
        out: ArrayList<Map<String, Any>>
    ) {
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
            dirUri,
            DocumentsContract.getDocumentId(dirUri)
        )
        ctx.contentResolver.query(
            childrenUri,
            arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,   // 0
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,  // 1
                DocumentsContract.Document.COLUMN_MIME_TYPE,     // 2
                DocumentsContract.Document.COLUMN_LAST_MODIFIED, // 3
                DocumentsContract.Document.COLUMN_SIZE           // 4
            ),
            null, null, null
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                val docId = cursor.getString(0) ?: continue
                val name = cursor.getString(1) ?: continue
                val mime = cursor.getString(2)
                val childPath = if (prefix.isEmpty()) name else "$prefix/$name"
                if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                    if (name == ".syncstate" || name == ".syncversions") continue
                    val childUri = DocumentsContract.buildDocumentUriUsingTree(dirUri, docId)
                    listRecursiveWithStat(ctx, childUri, childPath, out)
                } else {
                    out.add(
                        mapOf(
                            "path" to childPath,
                            "size" to cursor.getLong(4),
                            "mtime" to cursor.getLong(3)
                        )
                    )
                }
            }
        }
    }
}
