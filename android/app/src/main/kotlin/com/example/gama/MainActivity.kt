package com.example.gama

import android.content.ClipData
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
            if (call.method != "openWithChooser") {
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

                val uri = FileProvider.getUriForFile(
                    this,
                    "${applicationContext.packageName}.fileprovider",
                    file,
                )
                val viewIntent = Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(uri, mimeTypeFor(file))
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    clipData = ClipData.newUri(contentResolver, file.name, uri)
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
