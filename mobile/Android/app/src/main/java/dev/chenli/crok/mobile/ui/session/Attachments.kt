package dev.chenli.crok.mobile.ui.session

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.Orientation
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.draggable
import androidx.compose.foundation.gestures.rememberDraggableState
import androidx.compose.foundation.gestures.rememberTransformableState
import androidx.compose.foundation.gestures.transformable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import androidx.core.net.toUri
import dev.chenli.crok.mobile.R
import dev.chenli.crok.mobile.data.AttachmentPick
import dev.chenli.crok.mobile.data.RelayFiles
import dev.chenli.crok.mobile.logic.AttachmentKind
import dev.chenli.crok.mobile.logic.AttachmentRules
import dev.chenli.crok.mobile.logic.DraftAttachment
import dev.chenli.crok.mobile.logic.FileRef
import dev.chenli.crok.mobile.logic.ShownAttachment
import dev.chenli.crok.mobile.logic.Unavailable
import dev.chenli.crok.mobile.logic.UploadState
import dev.chenli.crok.mobile.ui.common.CrokIcons
import dev.chenli.crok.mobile.ui.theme.CrokTheme
import java.io.File
import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToInt
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

// Photos and files in prompts (relay/DESIGN.md §5 "Photos and files in prompts"; Telegram's attach menu, media bubbles
// and photo viewer).

/** The app's language (observed, so a language change redraws the rows). */
@Composable
private fun currentLocale(): Locale = LocalConfiguration.current.locales[0] ?: Locale.ROOT

/** The FileProvider's authority (AndroidManifest.xml). */
private fun authority(context: Context) = "${context.packageName}.files"

// ---- Picking ----

/** What the attach menu opens: the photo picker, the camera (null when there is none), the document picker. */
class AttachLaunchers(val photos: () -> Unit, val camera: (() -> Unit)?, val files: () -> Unit)

/**
 * The system pickers for the composer: Photos (several images), Camera (one photo into the app's cache, through the
 * FileProvider; the camera permission is asked only when the app declares it) and Files (several, any type).
 */
@Composable
fun rememberAttachLaunchers(onPicked: (List<AttachmentPick>) -> Unit): AttachLaunchers {
    val context = LocalContext.current
    var pendingCapture by rememberSaveable { mutableStateOf<String?>(null) }
    val photos = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(AttachmentRules.MAX_COUNT)) { uris ->
        onPicked(uris.map { AttachmentPick(it, fromPhotos = true) })
    }
    val files = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        onPicked(uris.map { AttachmentPick(it, fromPhotos = false) })
    }
    val capture = rememberLauncherForActivityResult(ActivityResultContracts.TakePicture()) { taken ->
        val uri = pendingCapture
        pendingCapture = null
        if (taken && uri != null) onPicked(listOf(AttachmentPick(uri.toUri(), fromPhotos = true)))
    }
    val startCapture = {
        val dir = File(context.cacheDir, "camera").apply { mkdirs() }
        val file = File(dir, "capture-${System.currentTimeMillis()}.jpg")
        val uri = FileProvider.getUriForFile(context, authority(context), file)
        pendingCapture = uri.toString()
        runCatching { capture.launch(uri) }
    }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) startCapture()
    }
    val hasCamera = remember { context.packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY) }
    return AttachLaunchers(
        photos = { photos.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) },
        camera = if (!hasCamera) {
            null
        } else {
            {
                // An app that declares CAMERA must hold it for the camera app's intent; this one only asks then.
                if (declaresCamera(context) &&
                    ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED
                ) {
                    permission.launch(Manifest.permission.CAMERA)
                } else {
                    startCapture()
                }
            }
        },
        files = { files.launch(arrayOf("*/*")) },
    )
}

private fun declaresCamera(context: Context): Boolean = runCatching {
    @Suppress("DEPRECATION")
    context.packageManager.getPackageInfo(context.packageName, PackageManager.GET_PERMISSIONS)
        .requestedPermissions?.contains(Manifest.permission.CAMERA) == true
}.getOrDefault(false)

/** The paperclip after the Menu pill: Photos, Camera, Files. */
@Composable
fun AttachButton(launchers: AttachLaunchers?, enabled: Boolean, onOpenMenu: () -> Unit = {}) {
    val colors = CrokTheme.colors
    var open by remember { mutableStateOf(false) }
    val label = stringResource(R.string.attach)
    Box {
        IconButton(
            onClick = {
                onOpenMenu()
                open = true
            },
            enabled = enabled && launchers != null,
            modifier = Modifier.size(36.dp).testTag("attach-button").semantics { contentDescription = label },
        ) {
            Icon(CrokIcons.AttachFile, contentDescription = null, tint = if (enabled) colors.textSecondary else colors.textTertiary)
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            launchers ?: return@DropdownMenu
            AttachMenuItem(CrokIcons.Photo, stringResource(R.string.attach_photos)) {
                open = false
                launchers.photos()
            }
            launchers.camera?.let { camera ->
                AttachMenuItem(CrokIcons.Camera, stringResource(R.string.attach_camera)) {
                    open = false
                    camera()
                }
            }
            AttachMenuItem(CrokIcons.FileGlyph, stringResource(R.string.attach_files)) {
                open = false
                launchers.files()
            }
        }
    }
}

@Composable
private fun AttachMenuItem(icon: ImageVector, text: String, onClick: () -> Unit) {
    DropdownMenuItem(
        text = { Text(text) },
        leadingIcon = { Icon(icon, contentDescription = null, tint = CrokTheme.colors.accent) },
        onClick = onClick,
    )
}

// ---- The strip above the field ----

/** What is attached, in order, scrolling sideways: thumbnails and file chips, each with ✕, progress, or a retry. */
@Composable
fun AttachmentStrip(items: List<DraftAttachment>, onRemove: (String) -> Unit, onRetry: (String) -> Unit, modifier: Modifier = Modifier) {
    LazyRow(
        modifier.fillMaxWidth().testTag("attachment-strip"),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        contentPadding = PaddingValues(horizontal = 8.dp, vertical = 8.dp),
    ) {
        items(items, key = { it.id }) { item ->
            if (item.kind == AttachmentKind.Image) {
                ImageTile(item, onRemove, onRetry)
            } else {
                FileChip(item, onRemove, onRetry)
            }
        }
    }
}

@Composable
private fun ImageTile(item: DraftAttachment, onRemove: (String) -> Unit, onRetry: (String) -> Unit) {
    val colors = CrokTheme.colors
    val shape = RoundedCornerShape(12.dp)
    val failed = item.state is UploadState.Failed
    val retryLabel = stringResource(R.string.attach_failed)
    Box(Modifier.size(64.dp)) {
        Box(
            Modifier
                .size(64.dp)
                .clip(shape)
                .background(colors.card)
                .then(if (failed) Modifier.clickable(onClickLabel = retryLabel) { onRetry(item.id) } else Modifier),
            contentAlignment = Alignment.Center,
        ) {
            val local = (item.thumbFile ?: item.file)?.let { FileRef(File(it).toURI().toString(), "draft:${item.id}") }
            val picture = rememberFilePicture(local, maxSide = 192)
            if (picture != null) {
                Image(picture, contentDescription = item.name, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
            } else {
                Icon(CrokIcons.Photo, contentDescription = null, tint = colors.textTertiary)
            }
            StateOverlay(item.state, retryLabel)
        }
        RemoveBadge(Modifier.align(Alignment.TopEnd).padding(4.dp)) { onRemove(item.id) }
    }
}

@Composable
private fun FileChip(item: DraftAttachment, onRemove: (String) -> Unit, onRetry: (String) -> Unit) {
    val colors = CrokTheme.colors
    val failed = item.state is UploadState.Failed
    val retryLabel = stringResource(R.string.attach_failed)
    Box {
        Row(
            Modifier
                .height(64.dp)
                .widthIn(min = 120.dp, max = 220.dp)
                .clip(RoundedCornerShape(12.dp))
                .background(colors.card)
                .then(if (failed) Modifier.clickable(onClickLabel = retryLabel) { onRetry(item.id) } else Modifier)
                .padding(start = 10.dp, end = 30.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(Modifier.size(40.dp).clip(CircleShape).background(if (failed) colors.danger else colors.accent), contentAlignment = Alignment.Center) {
                when (val state = item.state) {
                    UploadState.Preparing -> CircularProgressIndicator(Modifier.size(22.dp), color = colors.onAccent, strokeWidth = 2.dp)
                    is UploadState.Uploading -> CircularProgressIndicator(
                        progress = { state.progress.coerceAtLeast(0.03f) },
                        modifier = Modifier.size(24.dp),
                        color = colors.onAccent,
                        strokeWidth = 2.dp,
                        trackColor = colors.onAccent.copy(alpha = 0.3f),
                    )
                    is UploadState.Failed -> Text("!", color = Color.White, fontSize = 18.sp, fontWeight = FontWeight.Bold)
                    UploadState.Ready -> Icon(CrokIcons.Document, contentDescription = null, tint = colors.onAccent, modifier = Modifier.size(20.dp))
                }
            }
            Spacer(Modifier.width(10.dp))
            Column(Modifier.weight(1f, fill = false)) {
                Text(
                    item.name.ifBlank { "…" },
                    color = colors.textPrimary,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.Medium,
                    maxLines = 1,
                    overflow = TextOverflow.MiddleEllipsis,
                )
                val line = when (item.state) {
                    is UploadState.Failed -> retryLabel
                    is UploadState.Uploading, UploadState.Preparing -> stringResource(R.string.attach_uploading)
                    UploadState.Ready -> AttachmentRules.fileLine(item.size, item.name, item.mimeType, currentLocale())
                }
                Text(line, color = if (failed) colors.danger else colors.textSecondary, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
        RemoveBadge(Modifier.align(Alignment.TopEnd).padding(4.dp)) { onRemove(item.id) }
    }
}

/** A progress ring (or a red "!" to retry) over an image tile. */
@Composable
private fun StateOverlay(state: UploadState, retryLabel: String) {
    if (state == UploadState.Ready) return
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.35f)), contentAlignment = Alignment.Center) {
        when (state) {
            UploadState.Preparing -> CircularProgressIndicator(Modifier.size(26.dp), color = Color.White, strokeWidth = 2.5.dp)
            is UploadState.Uploading -> CircularProgressIndicator(
                progress = { state.progress.coerceAtLeast(0.03f) },
                modifier = Modifier.size(28.dp),
                color = Color.White,
                strokeWidth = 2.5.dp,
                trackColor = Color.White.copy(alpha = 0.3f),
            )
            is UploadState.Failed -> Box(
                Modifier.size(28.dp).clip(CircleShape).background(CrokTheme.colors.danger).semantics { contentDescription = retryLabel },
                contentAlignment = Alignment.Center,
            ) {
                Text("!", color = Color.White, fontSize = 16.sp, fontWeight = FontWeight.Bold)
            }
            UploadState.Ready -> Unit
        }
    }
}

@Composable
private fun RemoveBadge(modifier: Modifier, onClick: () -> Unit) {
    val label = stringResource(R.string.attach_remove)
    Box(
        modifier
            .size(20.dp)
            .clip(CircleShape)
            .background(Color.Black.copy(alpha = 0.55f))
            .clickable(onClickLabel = label, role = Role.Button, onClick = onClick)
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        Icon(CrokIcons.Close, contentDescription = null, tint = Color.White, modifier = Modifier.size(14.dp))
    }
}

// ---- Pictures ----

/**
 * [ref] decoded for a box at most [maxSide] px on its longer side: at once from memory, a local file, the cache or the
 * demo, else after a download (null meanwhile).
 */
@Composable
fun rememberFilePicture(ref: FileRef?, maxSide: Int): ImageBitmap? {
    val context = LocalContext.current
    if (ref == null) return null
    val now = remember(ref, maxSide) {
        // The phone's own prepared copies and the demo's pictures decode right away (no flash of the placeholder, and
        // screenshots see them); the relay's, even cached, decode off the main thread so scrolling stays smooth.
        val local = ref.url.startsWith("file:") || ref.url.startsWith("demo:")
        (RelayFiles.bitmapInMemory(ref, maxSide) ?: if (local && maxSide <= 1080) RelayFiles.bitmapNow(context, ref, maxSide) else null)
            ?.asImageBitmap()
    }
    var loaded by remember(ref, maxSide) { mutableStateOf(now) }
    LaunchedEffect(ref, maxSide) {
        if (loaded == null) loaded = RelayFiles.bitmap(context, ref, maxSide)?.asImageBitmap()
    }
    return loaded
}

// ---- In the transcript ----

/** The phone's file opener (downloads with progress, then the system's viewer); provided by the session screen. */
val LocalFileOpener = compositionLocalOf<FileOpener?> { null }

/**
 * Opens a file of the transcript: downloads it into the cache (its row shows the progress), copies it under its own
 * name and hands it to the system's viewer through the FileProvider, or to Share when no app opens it.
 */
class FileOpener(private val context: Context, private val scope: CoroutineScope) {
    private val _progress = MutableStateFlow<Map<String, Float>>(emptyMap())
    val progress: StateFlow<Map<String, Float>> = _progress

    fun open(item: ShownAttachment) {
        val ref = item.full ?: return
        if (item.key in _progress.value) return
        _progress.update { it + (item.key to 0f) }
        scope.launch {
            val file = RelayFiles.fetch(context, ref) { p -> _progress.update { it + (item.key to p) } }
            _progress.update { it - item.key }
            if (file == null) {
                Toast.makeText(context, R.string.media_download_failed, Toast.LENGTH_SHORT).show()
                return@launch
            }
            val uri = withContext(Dispatchers.IO) { sharedCopy(context, file, item.name) } ?: return@launch
            val view = Intent(Intent.ACTION_VIEW).setDataAndType(uri, item.mimeType).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            try {
                context.startActivity(view)
            } catch (e: ActivityNotFoundException) {
                Toast.makeText(context, R.string.media_open_failed, Toast.LENGTH_SHORT).show()
                share(context, uri, item.mimeType)
            }
        }
    }
}

/** A copy of [file] named [name] that the FileProvider hands out (`cache/shared`). */
private fun sharedCopy(context: Context, file: File, name: String): Uri? = runCatching {
    val dir = File(context.cacheDir, "shared/${file.name.hashCode().toUInt()}").apply { mkdirs() }
    val safe = name.replace(Regex("[\\\\/:*?\"<>|\\u0000-\\u001f]"), "_").ifBlank { "file" }
    val copy = File(dir, safe)
    if (!copy.exists() || copy.length() != file.length()) file.copyTo(copy, overwrite = true)
    FileProvider.getUriForFile(context, authority(context), copy)
}.getOrNull()

private fun share(context: Context, uri: Uri, mime: String) {
    val send = Intent(Intent.ACTION_SEND).setType(mime).putExtra(Intent.EXTRA_STREAM, uri).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    runCatching { context.startActivity(Intent.createChooser(send, null)) }
}

/** The widest a single image or the grid may be in a bubble, and the tallest a single image may be. */
private val MediaWidth = 260.dp
private val MediaMaxHeight = 320.dp
private val MediaGap = 2.dp

/**
 * A prompt's media inside its bubble, above the text (Telegram's media with caption): one image whole, or a grid of
 * square crops two per row (the last one full width when the count is odd). [overlay] goes on the last image's
 * bottom-right corner (the time and ticks of a bubble without text).
 */
@Composable
fun BubbleImages(
    images: List<ShownAttachment>,
    shape: Shape,
    minWidth: Dp,
    onOpen: (Int) -> Unit,
    overlay: (@Composable () -> Unit)? = null,
) {
    val density = LocalDensity.current
    if (images.size == 1) {
        val image = images.first()
        val aspect = image.aspect ?: 1f
        var width = MediaWidth
        var height = MediaWidth / aspect
        if (height > MediaMaxHeight) {
            height = MediaMaxHeight
            width = (MediaMaxHeight * aspect).coerceIn(120.dp, MediaWidth)
        }
        width = width.coerceAtLeast(minWidth.coerceAtMost(MediaWidth))
        Box(Modifier.size(width, height).clip(shape)) {
            MediaTile(image, Modifier.fillMaxSize(), with(density) { maxOf(width, height).roundToPx() }) { onOpen(0) }
            overlay?.let { Box(Modifier.align(Alignment.BottomEnd).padding(6.dp)) { it() } }
        }
        return
    }
    val tile = (MediaWidth - MediaGap) / 2
    val rows = images.chunked(2)
    Column(Modifier.width(MediaWidth).clip(shape), verticalArrangement = Arrangement.spacedBy(MediaGap)) {
        rows.forEachIndexed { row, pair ->
            Row(horizontalArrangement = Arrangement.spacedBy(MediaGap)) {
                pair.forEachIndexed { column, image ->
                    val index = row * 2 + column
                    val wide = pair.size == 1
                    val modifier = if (wide) Modifier.size(MediaWidth, tile) else Modifier.size(tile)
                    Box(modifier) {
                        MediaTile(image, Modifier.fillMaxSize(), with(density) { (if (wide) MediaWidth else tile).roundToPx() }) { onOpen(index) }
                        if (overlay != null && index == images.lastIndex) Box(Modifier.align(Alignment.BottomEnd).padding(6.dp)) { overlay() }
                    }
                }
            }
        }
    }
}

@Composable
private fun MediaTile(image: ShownAttachment, modifier: Modifier, maxSidePx: Int, onClick: () -> Unit) {
    val colors = CrokTheme.colors
    val picture = rememberFilePicture(image.preview, maxSide = maxSidePx.coerceIn(96, 1080))
    Box(
        modifier
            .background(colors.textPrimary.copy(alpha = 0.08f))
            .clickable(onClickLabel = image.name, role = Role.Image, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        if (picture != null) {
            Image(picture, contentDescription = image.name, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
        } else {
            Icon(CrokIcons.Photo, contentDescription = image.name, tint = colors.textTertiary, modifier = Modifier.size(28.dp))
        }
    }
}

/**
 * A file in a bubble (or an image that cannot be shown): a round accent icon, the name and "1.2 MB · PDF"; dimmed with
 * "On <computer>" / "No longer available" when it cannot be opened. [textColor] / [metaColor]: the bubble's.
 */
@Composable
fun FileRow(item: ShownAttachment, computer: String, textColor: Color, metaColor: Color, modifier: Modifier = Modifier) {
    val colors = CrokTheme.colors
    val opener = LocalFileOpener.current
    val progress by (opener?.progress ?: remember { MutableStateFlow(emptyMap<String, Float>()) }).collectAsState()
    val downloading = progress[item.key]
    val available = item.unavailable == null && item.full != null
    Row(
        modifier
            .widthIn(min = 200.dp, max = MediaWidth)
            .then(if (available && opener != null) Modifier.clickable(onClickLabel = item.name) { opener.open(item) } else Modifier)
            .padding(vertical = 4.dp)
            .testTag("file-row"),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier.size(44.dp).clip(CircleShape).background(if (available) colors.accent else metaColor.copy(alpha = 0.3f)),
            contentAlignment = Alignment.Center,
        ) {
            if (downloading != null) {
                CircularProgressIndicator(
                    progress = { downloading.coerceAtLeast(0.03f) },
                    modifier = Modifier.size(26.dp),
                    color = colors.onAccent,
                    strokeWidth = 2.dp,
                    trackColor = colors.onAccent.copy(alpha = 0.3f),
                )
            } else {
                Icon(
                    if (item.isImage) CrokIcons.Photo else CrokIcons.Document,
                    contentDescription = null,
                    tint = if (available) colors.onAccent else textColor.copy(alpha = 0.6f),
                    modifier = Modifier.size(22.dp),
                )
            }
        }
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f, fill = false)) {
            Text(
                item.name.ifBlank { stringResource(if (item.isImage) R.string.attach_photo else R.string.attach_file) },
                color = textColor.copy(alpha = if (available) 1f else 0.6f),
                fontSize = 15.sp,
                fontWeight = FontWeight.Medium,
                maxLines = 1,
                overflow = TextOverflow.MiddleEllipsis,
            )
            val line = when (item.unavailable) {
                Unavailable.OnComputer -> stringResource(R.string.media_on_computer, computer)
                Unavailable.Gone -> stringResource(R.string.media_unavailable)
                null -> AttachmentRules.fileLine(item.size, item.name, item.mimeType, currentLocale())
            }
            Text(line, color = metaColor, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

// ---- The full-screen viewer ----

/** Which images the viewer shows, from which one. */
data class ViewerRequest(val images: List<ShownAttachment>, val start: Int)

/**
 * Telegram's photo viewer: black, the prompt's images side by side (swipe between them), pinch and double-tap to zoom,
 * swipe down or ✕ to close; Share and Save (to Pictures/Crok) at the bottom.
 */
@Composable
fun ImageViewer(request: ViewerRequest, onDismiss: () -> Unit) {
    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false),
    ) {
        ViewerContent(request, onDismiss)
    }
}

@Composable
fun ViewerContent(request: ViewerRequest, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val images = request.images
    val pager = rememberPagerState(initialPage = request.start.coerceIn(0, (images.size - 1).coerceAtLeast(0))) { images.size }
    var dragY by remember { mutableFloatStateOf(0f) }
    var zoomed by remember { mutableStateOf(false) }
    val closeDistance = with(LocalDensity.current) { 120.dp.toPx() }
    val legacySave = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        val image = images.getOrNull(pager.currentPage)
        if (granted && image != null) scope.launch { saveImage(context, image) }
    }
    Box(
        Modifier
            .fillMaxSize()
            .background(Color.Black.copy(alpha = (1f - abs(dragY) / (closeDistance * 3)).coerceIn(0.4f, 1f)))
            .testTag("image-viewer"),
    ) {
        HorizontalPager(
            state = pager,
            userScrollEnabled = !zoomed,
            modifier = Modifier
                .fillMaxSize()
                .offset { androidx.compose.ui.unit.IntOffset(0, dragY.roundToInt()) }
                .draggable(
                    orientation = Orientation.Vertical,
                    enabled = !zoomed,
                    state = rememberDraggableState { delta -> dragY += delta },
                    onDragStopped = { if (abs(dragY) > closeDistance) onDismiss() else dragY = 0f },
                ),
        ) { page ->
            ZoomableImage(images[page], onZoomed = { if (page == pager.currentPage) zoomed = it })
        }
        // Dark fades behind the controls, so they read on any picture.
        Box(Modifier.align(Alignment.TopCenter).fillMaxWidth().height(120.dp).background(Brush.verticalGradient(listOf(Color.Black.copy(alpha = 0.55f), Color.Transparent))))
        Box(Modifier.align(Alignment.BottomCenter).fillMaxWidth().height(160.dp).background(Brush.verticalGradient(listOf(Color.Transparent, Color.Black.copy(alpha = 0.6f)))))
        Row(
            Modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = 4.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconButton(onClick = onDismiss) {
                Icon(CrokIcons.Close, contentDescription = stringResource(R.string.media_close), tint = Color.White)
            }
            Spacer(Modifier.weight(1f))
            if (images.size > 1) {
                Text(
                    stringResource(R.string.media_count, pager.currentPage + 1, images.size),
                    color = Color.White,
                    fontSize = 16.sp,
                    fontWeight = FontWeight.SemiBold,
                )
            }
            Spacer(Modifier.weight(1f))
            Spacer(Modifier.width(48.dp))
        }
        val current = images.getOrNull(pager.currentPage)
        Column(Modifier.align(Alignment.BottomCenter).fillMaxWidth().navigationBarsPadding()) {
            current?.let {
                Text(
                    it.name,
                    color = Color.White.copy(alpha = 0.8f),
                    fontSize = 13.sp,
                    maxLines = 1,
                    overflow = TextOverflow.MiddleEllipsis,
                    modifier = Modifier.align(Alignment.CenterHorizontally).padding(horizontal = 24.dp),
                )
            }
            Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp), horizontalArrangement = Arrangement.SpaceBetween) {
                ViewerAction(CrokIcons.Share, stringResource(R.string.media_share)) {
                    val image = current ?: return@ViewerAction
                    scope.launch { shareImage(context, image) }
                }
                ViewerAction(CrokIcons.Download, stringResource(R.string.media_save)) {
                    val image = current ?: return@ViewerAction
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q &&
                        ContextCompat.checkSelfPermission(context, Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED
                    ) {
                        legacySave.launch(Manifest.permission.WRITE_EXTERNAL_STORAGE)
                    } else {
                        scope.launch { saveImage(context, image) }
                    }
                }
            }
        }
    }
}

@Composable
private fun ViewerAction(icon: ImageVector, label: String, onClick: () -> Unit) {
    TextButton(onClick = onClick) {
        Icon(icon, contentDescription = null, tint = Color.White, modifier = Modifier.size(20.dp))
        Spacer(Modifier.width(8.dp))
        Text(label, color = Color.White, fontSize = 15.sp)
    }
}

/** One image: its thumbnail at once, then the original; pinch and double-tap zoom, panning only while zoomed. */
@Composable
private fun ZoomableImage(image: ShownAttachment, onZoomed: (Boolean) -> Unit) {
    var scale by remember { mutableFloatStateOf(1f) }
    var offset by remember { mutableStateOf(Offset.Zero) }
    val preview = rememberFilePicture(image.preview, maxSide = 480)
    val full = rememberFilePicture(image.full, maxSide = 2048)
    val transform = rememberTransformableState { zoom, pan, _ ->
        scale = (scale * zoom).coerceIn(1f, 5f)
        offset = if (scale == 1f) Offset.Zero else offset + pan * scale
        onZoomed(scale > 1f)
    }
    Box(
        Modifier
            .fillMaxSize()
            .pointerInput(image.key) {
                detectTapGestures(onDoubleTap = { tap ->
                    if (scale > 1f) {
                        scale = 1f
                        offset = Offset.Zero
                    } else {
                        scale = 2.5f
                        offset = (Offset(size.width / 2f, size.height / 2f) - tap) * 1.5f
                    }
                    onZoomed(scale > 1f)
                })
            }
            .transformable(transform, canPan = { scale > 1f }),
        contentAlignment = Alignment.Center,
    ) {
        val picture = full ?: preview
        if (picture != null) {
            Image(
                picture,
                contentDescription = image.name,
                contentScale = ContentScale.Fit,
                modifier = Modifier
                    .fillMaxSize()
                    .graphicsLayer {
                        scaleX = scale
                        scaleY = scale
                        translationX = offset.x
                        translationY = offset.y
                    },
            )
        }
        if (full == null) CircularProgressIndicator(Modifier.size(36.dp), color = Color.White, strokeWidth = 3.dp)
    }
}

private suspend fun shareImage(context: Context, image: ShownAttachment) {
    val ref = image.full ?: image.preview ?: return
    val file = RelayFiles.fetch(context, ref) ?: return
    val uri = withContext(Dispatchers.IO) { sharedCopy(context, file, image.name) } ?: return
    share(context, uri, image.mimeType)
}

/** Into Pictures/Crok: MediaStore from Android 10 on, the public folder (with its permission) before. */
private suspend fun saveImage(context: Context, image: ShownAttachment) {
    val ref = image.full ?: return
    val saved = withContext(Dispatchers.IO) {
        val file = RelayFiles.fetch(context, ref) ?: return@withContext false
        runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val values = ContentValues().apply {
                    put(MediaStore.Images.Media.DISPLAY_NAME, image.name)
                    put(MediaStore.Images.Media.MIME_TYPE, image.mimeType)
                    put(MediaStore.Images.Media.RELATIVE_PATH, "${Environment.DIRECTORY_PICTURES}/Crok")
                    put(MediaStore.Images.Media.IS_PENDING, 1)
                }
                val resolver = context.contentResolver
                val uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values) ?: error("No MediaStore entry")
                resolver.openOutputStream(uri)?.use { out -> file.inputStream().use { it.copyTo(out) } } ?: error("No stream")
                resolver.update(uri, ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) }, null, null)
            } else {
                @Suppress("DEPRECATION")
                val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES), "Crok").apply { mkdirs() }
                val target = File(dir, image.name)
                file.copyTo(target, overwrite = true)
                MediaScannerConnection.scanFile(context, arrayOf(target.path), arrayOf(image.mimeType), null)
            }
            true
        }.getOrDefault(false)
    }
    Toast.makeText(context, if (saved) R.string.media_saved else R.string.media_save_failed, Toast.LENGTH_SHORT).show()
}

/** Provides the screen's [FileOpener] to the transcript's file rows. */
@Composable
fun ProvideFileOpener(content: @Composable () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val opener = remember(context) { FileOpener(context, scope) }
    CompositionLocalProvider(LocalFileOpener provides opener, content = content)
}
