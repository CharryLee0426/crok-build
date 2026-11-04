package dev.chenli.crok.mobile.logic

import dev.chenli.crok.mobile.data.Attachment
import java.io.File
import java.text.NumberFormat
import java.time.LocalDateTime
import java.util.Locale
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Photos and files in prompts (relay/DESIGN.md §5 "Photos and files in prompts"): the limits, how an image is prepared
 * before upload, its name, and how sizes and types read. Pure, so the JVM tests cover it.
 */
object AttachmentRules {
    const val MAX_COUNT = 10
    const val MAX_FILE_BYTES = 20L * 1024 * 1024

    /** Images are re-encoded at most this long on their longer side. */
    const val MAX_SIDE = 2048

    /** Each image's thumbnail, for previews. */
    const val THUMB_SIDE = 480

    /** A GIF goes as it is up to this size; a larger one goes as its first frame. */
    const val GIF_MAX_BYTES = 10L * 1024 * 1024
    const val JPEG_QUALITY = 85
    const val THUMB_QUALITY = 70
    const val OCTET_STREAM = "application/octet-stream"

    /** The size for a [width] × [height] picture: the same when it fits, else scaled so its longer side is [maxSide]. */
    fun targetSize(width: Int, height: Int, maxSide: Int = MAX_SIDE): Pair<Int, Int> {
        val longest = max(width, height)
        if (longest <= maxSide || width <= 0 || height <= 0) return width to height
        val scale = maxSide.toDouble() / longest
        return (width * scale).roundToInt().coerceAtLeast(1) to (height * scale).roundToInt().coerceAtLeast(1)
    }

    /** How an image is uploaded: re-encoded as JPEG or PNG, or (a GIF that fits) as it is. */
    enum class Encoding { Jpeg, Png, AsIs }

    /**
     * Every image except a GIF of at most [GIF_MAX_BYTES] is re-encoded: as PNG when the source is a PNG or has
     * transparency, else as JPEG (HEIC, TIFF, BMP and the rest included).
     */
    fun encodingFor(sourceMime: String?, hasAlpha: Boolean, byteCount: Long?): Encoding {
        val mime = sourceMime?.lowercase(Locale.ROOT)
        if (mime == "image/gif" && byteCount != null && byteCount <= GIF_MAX_BYTES) return Encoding.AsIs
        if (mime == "image/png" || hasAlpha) return Encoding.Png
        return Encoding.Jpeg
    }

    fun mimeFor(encoding: Encoding, sourceMime: String?): String = when (encoding) {
        Encoding.Jpeg -> "image/jpeg"
        Encoding.Png -> "image/png"
        Encoding.AsIs -> sourceMime ?: "image/gif"
    }

    private val extensions = mapOf(
        "jpg" to "image/jpeg", "jpeg" to "image/jpeg", "png" to "image/png", "gif" to "image/gif", "webp" to "image/webp",
        "heic" to "image/heic", "heif" to "image/heif", "bmp" to "image/bmp", "tif" to "image/tiff", "tiff" to "image/tiff",
        "svg" to "image/svg+xml", "pdf" to "application/pdf", "txt" to "text/plain", "md" to "text/markdown",
        "csv" to "text/csv", "json" to "application/json", "html" to "text/html", "xml" to "application/xml",
        "zip" to "application/zip", "gz" to "application/gzip", "tar" to "application/x-tar",
        "doc" to "application/msword", "docx" to "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "xls" to "application/vnd.ms-excel", "xlsx" to "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "ppt" to "application/vnd.ms-powerpoint", "pptx" to "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "mp4" to "video/mp4", "mov" to "video/quicktime", "mp3" to "audio/mpeg", "m4a" to "audio/mp4", "wav" to "audio/wav",
        "kt" to "text/plain", "swift" to "text/plain", "rs" to "text/plain", "py" to "text/x-python", "js" to "text/javascript",
        "ts" to "text/plain", "log" to "text/plain", "yaml" to "text/yaml", "yml" to "text/yaml", "toml" to "text/plain",
    )

    /** The type a file is sent with: the system's, else by its extension, else `application/octet-stream`. */
    fun mimeFor(name: String, systemType: String?): String {
        val system = systemType?.substringBefore(';')?.trim()?.lowercase(Locale.ROOT)
        if (!system.isNullOrEmpty() && system != OCTET_STREAM && system.contains('/')) return system
        return extensions[extensionOf(name)] ?: OCTET_STREAM
    }

    fun isImageType(mime: String?): Boolean = mime?.lowercase(Locale.ROOT)?.startsWith("image/") == true

    /** The extension an uploaded image's name ends with. */
    fun extensionFor(mime: String): String = when (mime.lowercase(Locale.ROOT)) {
        "image/jpeg" -> "jpg"
        "image/png" -> "png"
        "image/gif" -> "gif"
        "image/webp" -> "webp"
        else -> mime.substringAfter('/').substringBefore('+').ifBlank { "bin" }
    }

    fun extensionOf(name: String): String =
        name.substringAfterLast('/').let { base -> if ('.' in base.drop(1)) base.substringAfterLast('.').lowercase(Locale.ROOT) else "" }

    /** [name] with its extension changed to [extension] (added when it has none). */
    fun withExtension(name: String, extension: String): String {
        val base = name.substringAfterLast('/').trim()
        val stem = if ('.' in base.drop(1)) base.substringBeforeLast('.') else base
        return "${stem.ifBlank { "file" }}.$extension"
    }

    /** A photo without a name of its own: `photo-YYYYMMDD-HHMMSS.jpg`, then `-2`, `-3`, … for more in one pick. */
    fun photoName(at: LocalDateTime, index: Int, extension: String): String {
        val stamp = "%04d%02d%02d-%02d%02d%02d".format(Locale.ROOT, at.year, at.monthValue, at.dayOfMonth, at.hour, at.minute, at.second)
        val suffix = if (index > 0) "-${index + 1}" else ""
        return "photo-$stamp$suffix.$extension"
    }

    /** "1.2 MB", "340 KB", "12 B" (1024-based, one decimal below 10, in the locale's digits). */
    fun sizeLabel(bytes: Long, locale: Locale = Locale.getDefault()): String {
        if (bytes < 1024) return "$bytes B"
        val units = listOf("KB", "MB", "GB")
        var value = bytes / 1024.0
        var unit = 0
        while (value >= 1024 && unit < units.lastIndex) {
            value /= 1024
            unit++
        }
        val format = NumberFormat.getNumberInstance(locale).apply {
            maximumFractionDigits = if (value < 10) 1 else 0
            minimumFractionDigits = 0
        }
        return "${format.format(value)} ${units[unit]}"
    }

    /** "PDF" for `report.pdf`; from the type when the name has no extension ("PNG"); "FILE" when neither says. */
    fun typeLabel(name: String, mime: String): String {
        val extension = extensionOf(name)
        if (extension.isNotEmpty() && extension.length <= 6) return extension.uppercase(Locale.ROOT)
        val subtype = mime.substringAfter('/', "").substringBefore('+').substringAfterLast('.')
        return subtype.takeIf { it.isNotEmpty() && it != "octet-stream" && it.length <= 8 }?.uppercase(Locale.ROOT) ?: "FILE"
    }

    /** A file row's second line: "1.2 MB · PDF". */
    fun fileLine(size: Long, name: String, mime: String, locale: Locale = Locale.getDefault()): String =
        "${sizeLabel(size, locale)} · ${typeLabel(name, mime)}"

    /** How many of [picked] new attachments fit next to [attached] ones. */
    fun room(attached: Int, picked: Int): Int = picked.coerceAtMost((MAX_COUNT - attached).coerceAtLeast(0))
}

enum class AttachmentKind { Image, File }

/** Where an attachment in the composer's strip is. */
sealed interface UploadState {
    /** Being read and re-encoded on the phone. */
    data object Preparing : UploadState

    /** [progress] 0…1. */
    data class Uploading(val progress: Float) : UploadState

    data object Ready : UploadState

    /** [message]: why, when known; a tap retries. */
    data class Failed(val message: String?) : UploadState
}

/**
 * A photo or file in the composer's strip: prepared on the phone ([file], and [thumbFile] for an image), uploaded to
 * the relay ([storageId], [thumbId]) as soon as it was attached.
 */
data class DraftAttachment(
    val id: String,
    val kind: AttachmentKind,
    val name: String,
    val mimeType: String = AttachmentRules.OCTET_STREAM,
    val size: Long = 0,
    val width: Int? = null,
    val height: Int? = null,
    val file: String? = null,
    val thumbFile: String? = null,
    val storageId: String? = null,
    val thumbId: String? = null,
    val state: UploadState = UploadState.Preparing,
) {
    val ready: Boolean get() = state == UploadState.Ready && storageId != null

    /** What goes with the prompt (and its optimistic bubble), once uploaded. */
    fun outgoing(): OutgoingAttachment? = storageId?.let {
        OutgoingAttachment(it, thumbId, name, mimeType, size, kind, width, height, file, thumbFile)
    }
}

/** An uploaded attachment on its way with a prompt: the relay's ids, and the phone's own copies for its bubble. */
data class OutgoingAttachment(
    val storageId: String,
    val thumbId: String?,
    val name: String,
    val mimeType: String,
    val size: Long,
    val kind: AttachmentKind,
    val width: Int?,
    val height: Int?,
    val localFile: String? = null,
    val localThumb: String? = null,
) {
    /** `commands:sendPrompt`'s / `sessions:create`'s `attachments` entry (numbers as Doubles, absent keys left out). */
    fun args(): Map<String, Any?> = buildMap {
        put("storageId", storageId)
        thumbId?.let { put("thumbId", it) }
        put("name", name)
        width?.let { put("width", it.toDouble()) }
        height?.let { put("height", it.toDouble()) }
    }
}

/** An image or file to show: a URL (relay `https:`, the phone's `file:`, or the demo's `demo:`) and its cache key. */
data class FileRef(val url: String, val cacheKey: String)

/** Why an attachment cannot be opened: only on its computer (attached there), or no longer on the relay. */
enum class Unavailable { OnComputer, Gone }

/** An attachment as the transcript shows it, from the relay or from the phone's own copies. */
data class ShownAttachment(
    val key: String,
    val kind: AttachmentKind,
    val name: String,
    val mimeType: String,
    val size: Long,
    val width: Int?,
    val height: Int?,
    /** What a preview loads (the thumbnail, else the image). */
    val preview: FileRef?,
    /** The image or file itself. */
    val full: FileRef?,
    val unavailable: Unavailable? = null,
) {
    val isImage: Boolean get() = kind == AttachmentKind.Image

    /** Width over height, when known. */
    val aspect: Float? get() = if (width != null && height != null && width > 0 && height > 0) width.toFloat() / height else null
}

fun Attachment.shown(index: Int): ShownAttachment {
    val kind = if (isImage) AttachmentKind.Image else AttachmentKind.File
    val full = url?.let { FileRef(it, storageId ?: "url:$it") }
    val preview = thumbUrl?.let { FileRef(it, thumbId ?: "url:$it") } ?: full
    return ShownAttachment(
        key = storageId ?: "local:$index:$name",
        kind = kind,
        name = name,
        mimeType = mimeType,
        size = size,
        width = width,
        height = height,
        preview = if (kind == AttachmentKind.Image) preview else null,
        full = full,
        unavailable = when {
            full != null -> null
            storageId == null -> Unavailable.OnComputer
            else -> Unavailable.Gone
        },
    )
}

/** The phone's own copy while the prompt is on its way: the same cache keys the relay's URLs use once it arrives. */
fun OutgoingAttachment.shown(): ShownAttachment {
    val full = localFile?.let { FileRef(File(it).toURI().toString(), storageId) }
    val preview = localThumb?.let { FileRef(File(it).toURI().toString(), thumbId ?: "$storageId:thumb") } ?: full
    return ShownAttachment(
        key = storageId,
        kind = kind,
        name = name,
        mimeType = mimeType,
        size = size,
        width = width,
        height = height,
        preview = if (kind == AttachmentKind.Image) preview else null,
        full = full,
    )
}
