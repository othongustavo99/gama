package com.example.gama

import android.content.ClipData
import android.content.ContentValues
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import java.io.FileOutputStream
import android.content.Intent
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            FILE_OPENER_CHANNEL,
        ).setMethodCallHandler { call, result ->
            if (call.method != "openWithChooser" && call.method != "saveToDownloads") {
                result.notImplemented()
                return@setMethodCallHandler
            }

            val path = call.argument<String>("path")
            if (path.isNullOrBlank()) {
                result.error("INVALID_PATH", "Caminho do arquivo ausente.", null)
                return@setMethodCallHandler
            }

            try {
                val file = File(path)
                if (!file.isFile) {
                    result.error("FILE_NOT_FOUND", "Arquivo não encontrado.", path)
                    return@setMethodCallHandler
                }

                if (file.length() <= 0L) {
                    result.error("EMPTY_FILE", "Arquivo vazio ou incompleto.", null)
                    return@setMethodCallHandler
                }
                if (call.method == "saveToDownloads") {
                    val name = call.argument<String>("filename")
                        ?.substringAfterLast('/')?.substringAfterLast('\\')
                        ?.takeIf { it.isNotBlank() } ?: file.name
                    result.success(saveToDownloads(file, name))
                    return@setMethodCallHandler
                }

                // Flutter usa .../app_flutter/gama_library. O FileProvider só
                // permite cacheDir/filesDir. Copiamos para uma área autorizada
                // em vez de abrir uma root-path ampla para /data/data.
                val fileToShare = prepareShareableFile(file)
                val uri = FileProvider.getUriForFile(
                    this,
                    "${applicationContext.packageName}.fileprovider",
                    fileToShare,
                )
                val viewIntent = Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(uri, mimeTypeFor(fileToShare))
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    clipData = ClipData.newUri(contentResolver, fileToShare.name, uri)
                }
                startActivity(Intent.createChooser(viewIntent, "Abrir com"))
                result.success(null)
            } catch (error: Exception) {
                result.error(
                    "OPEN_FAILED",
                    error.message ?: "Não foi possível abrir o arquivo.",
                    null,
                )
            }
        }
    }

    private fun prepareShareableFile(source: File): File {
        val allowedRoots = listOf(filesDir, cacheDir,
            getExternalFilesDir(null), externalCacheDir).filterNotNull()
        val sourcePath = source.canonicalPath
        if (allowedRoots.any {
                val rootPath = it.canonicalPath
                sourcePath == rootPath || sourcePath.startsWith("$rootPath${File.separator}")
            }) return source

        // Nomes determinísticos e isolados previnem colisões e repetição de
        // cópias. Nenhuma pasta privada arbitrária é exposta pelo FileProvider.
        val shareDir = File(cacheDir, "gama_shared_files").apply { mkdirs() }
        val digest = java.security.MessageDigest.getInstance("SHA-256")
            .digest("$sourcePath:${source.lastModified()}:${source.length()}".toByteArray())
            .take(10).joinToString("") { "%02x".format(it) }
        val safeName = source.name.replace(Regex("[^A-Za-z0-9._-]"), "_")
        val target = File(shareDir, "${digest}_$safeName")
        if (!target.isFile || target.length() != source.length()) {
            val tmp = File.createTempFile("gama_", ".part", shareDir)
            try {
                source.inputStream().use { input ->
                    FileOutputStream(tmp).use { output -> input.copyTo(output) }
                }
                if (!tmp.renameTo(target)) {
                    tmp.copyTo(target, overwrite = true)
                }
            } finally {
                tmp.delete()
            }
        }
        return target
    }

    private fun saveToDownloads(source: File, filename: String): String {
        val safeName = filename.replace(Regex("[\\/:*?\"<>|\u0000-\u001f]"), "_")
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            // Android 9 e anteriores: salva na pasta do próprio app, sem
            // pedir permissões de armazenamento amplo.
            val dir = File(getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS), "Gama")
            if (!dir.exists() && !dir.mkdirs()) {
                throw IllegalStateException("Não foi possível criar a pasta de downloads.")
            }
            val target = File(dir, safeName)
            source.copyTo(target, overwrite = true)
            return target.path
        }
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, safeName)
            put(MediaStore.Downloads.MIME_TYPE, mimeTypeFor(source))
            put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/Gama")
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: throw IllegalStateException("Não foi possível criar o arquivo em Downloads.")
        try {
            contentResolver.openOutputStream(uri)?.use { output ->
                source.inputStream().use { input -> input.copyTo(output) }
            } ?: throw IllegalStateException("Não foi possível gravar o download.")
            val ready = ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }
            contentResolver.update(uri, ready, null, null)
            return uri.toString()
        } catch (error: Exception) {
            contentResolver.delete(uri, null, null)
            throw error
        }
    }

    private fun mimeTypeFor(file: File): String {
        val extension = file.extension.lowercase()
        val knownTypes = mapOf(
            "zip" to "application/zip",
            "pdf" to "application/pdf",
            "txt" to "text/plain",
            "md" to "text/markdown",
            "csv" to "text/csv",
            "json" to "application/json",
            "xml" to "application/xml",
            "html" to "text/html",
            "htm" to "text/html",
            "doc" to "application/msword",
            "docx" to "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "xls" to "application/vnd.ms-excel",
            "xlsx" to "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            "ppt" to "application/vnd.ms-powerpoint",
            "pptx" to "application/vnd.openxmlformats-officedocument.presentationml.presentation",
            "png" to "image/png",
            "jpg" to "image/jpeg",
            "jpeg" to "image/jpeg",
            "gif" to "image/gif",
            "webp" to "image/webp",
            "mp4" to "video/mp4",
            "m4v" to "video/mp4",
            "mov" to "video/quicktime",
            "webm" to "video/webm",
            "mkv" to "video/x-matroska",
            "dart" to "text/plain",
            "py" to "text/plain",
            "js" to "text/javascript",
            "ts" to "text/plain",
            "css" to "text/css",
            "yaml" to "text/plain",
            "yml" to "text/plain",
            "toml" to "text/plain",
            "java" to "text/plain",
            "kt" to "text/plain",
            "c" to "text/plain",
            "cpp" to "text/plain",
            "h" to "text/plain",
        )
        return knownTypes[extension]
            ?: MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
            ?: "application/octet-stream"
    }

    companion object {
        private const val FILE_OPENER_CHANNEL = "com.example.gama/file_opener"
    }
}
