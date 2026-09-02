package com.shoutsocial.share_handler

import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.content.pm.PackageManager
import android.provider.OpenableColumns
import android.util.Log
import android.webkit.MimeTypeMap

import androidx.annotation.NonNull
import androidx.core.app.Person
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.*
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InterruptedIOException
import java.util.Collections
import java.util.LinkedHashSet
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.RejectedExecutionException

private const val kEventsChannel = "com.shoutsocial.share_handler/sharedMediaStream"
private const val kMaxShareBytes = 2L * 1024L * 1024L * 1024L
private const val kMaxCacheBytes = 4L * 1024L * 1024L * 1024L
private const val kMaxAttachmentsPerShare = 128
private const val kMaxCacheFiles = 1024
private const val kMaxPendingMediaEvents = 16
// Cache paths are temporary; keep delivered files available across normal app sessions.
private const val kCacheFileRetentionMillis = 7L * 24L * 60L * 60L * 1000L
private const val kPartialCacheDirectoryName = ".partial"
private val kCacheLock = Any()
private val kCleanupExecutor = Executors.newSingleThreadExecutor()

/** ShareHandlerPlugin */
class ShareHandlerPlugin : FlutterPlugin, Messages.ShareHandlerApi, EventChannel.StreamHandler, ActivityAware,
  PluginRegistry.NewIntentListener {
  private var initialMedia: Messages.SharedMedia? = null
  private var initialMediaWasDelivered = false
  private var initialError: Throwable? = null
  private var eventChannel: EventChannel? = null
  private var eventSink: EventChannel.EventSink? = null

  private var binding: ActivityPluginBinding? = null
  private lateinit var applicationContext: Context
  private val ownProviderAuthorities: Set<String> by lazy {
    loadOwnProviderAuthorities()
  }
  private val mainHandler = Handler(Looper.getMainLooper())
  private var ioExecutor: ExecutorService? = null
  private var isEngineAttached = false
  private var engineGeneration = 0
  private var hasAttachedToActivity = false
  private var initialMediaWasRequestedBeforeActivity = false
  private var initialIntentGeneration = 0
  private var initialIntentFuture: Future<*>? = null
  private val pendingInitialResults = mutableListOf<Messages.Result<Messages.SharedMedia>>()
  private val pendingMediaEvents = mutableListOf<Messages.SharedMedia>()
  private val protectedCachePaths = Collections.synchronizedSet(mutableSetOf<String>())

  override fun onAttachedToEngine(@NonNull flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
    applicationContext = flutterPluginBinding.applicationContext
    isEngineAttached = true
    engineGeneration++
    hasAttachedToActivity = false
    initialMediaWasRequestedBeforeActivity = false
    initialIntentFuture = null
    ioExecutor = Executors.newSingleThreadExecutor()

    val messenger = flutterPluginBinding.binaryMessenger
    Messages.ShareHandlerApi.setup(messenger, this)

    eventChannel = EventChannel(messenger, kEventsChannel)
    eventChannel?.setStreamHandler(this)
  }

  override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
    Messages.ShareHandlerApi.setup(binding.binaryMessenger, null)
    this.binding?.removeOnNewIntentListener(this)
    this.binding = null
    eventChannel?.setStreamHandler(null)
    eventChannel = null
    eventSink = null
    if (initialMediaWasDelivered) {
      unprotectMediaFiles(initialMedia)
    } else {
      deleteMediaFilesAsync(initialMedia)
    }
    initialMedia = null
    initialMediaWasDelivered = false
    initialError = null
    pendingMediaEvents.forEach(::deleteMediaFilesAsync)
    pendingMediaEvents.clear()
    protectedCachePaths.clear()
    isEngineAttached = false
    engineGeneration++
    hasAttachedToActivity = false
    initialMediaWasRequestedBeforeActivity = false
    initialIntentGeneration++
    initialIntentFuture?.cancel(true)
    initialIntentFuture = null
    ioExecutor?.shutdownNow()
    ioExecutor = null
    pendingInitialResults.forEach { it.success(null) }
    pendingInitialResults.clear()
  }

//  override fun getInitialSharedMedia(result: Result<SharedMedia>?) {
//    result?.let { _result -> {
//      initialMedia?.let { _media -> _result.success(_media) }
//    } }
//  }

//  override fun recordSentMessage(media: SharedMedia) {
//    val packageName = applicationContext.packageName
//    val shortcutTarget = "$packageName.dynamic_share_target"
//    val shortcutBuilder = ShortcutInfoCompat.Builder(applicationContext, media.conversationIdentifier ?: "").setShortLabel(media.speakableGroupName ?: "Unknown")
//      .setIsConversation()
//      .setCategories(setOf(shortcutTarget))
//      .setIntent(Intent(Intent.ACTION_DEFAULT))
//      .setLongLived(true)
//
//    val personBuilder = Person.Builder()
//      .setKey(media.conversationIdentifier)
//      .setName(media.speakableGroupName)
//
//    media.imageFilePath?.let {
//      val bitmap = BitmapFactory.decodeFile(it)
//      val icon = IconCompat.createWithAdaptiveBitmap(bitmap)
//      shortcutBuilder.setIcon(icon)
//      personBuilder.setIcon(icon)
//    }
//
//    val person = personBuilder.build()
//    shortcutBuilder.setPerson(person)
//
//    val shortcut = shortcutBuilder.build()
//
//    ShortcutManagerCompat.addDynamicShortcuts(applicationContext, listOf(shortcut))
//  }

  override fun getInitialSharedMedia(result: Messages.Result<Messages.SharedMedia>?) {
    if (result == null) return
    if (!hasAttachedToActivity) {
      initialMediaWasRequestedBeforeActivity = true
      result.success(null)
      return
    }
    if (initialIntentFuture != null) {
      pendingInitialResults.add(result)
    } else {
      val error = initialError
      if (error != null) {
        result.error(error)
      } else {
        val media = initialMedia
        if (media != null) {
          initialMediaWasDelivered = true
          unprotectMediaFiles(media)
        }
        result.success(media)
      }
    }
  }

  override fun recordSentMessage(media: Messages.SharedMedia) {
    val packageName = applicationContext.packageName
    val intent = applicationContext.packageManager.getLaunchIntentForPackage(packageName)?.apply {
      action = Intent.ACTION_SEND
      putExtra("conversationIdentifier", media.conversationIdentifier)
    } ?: run {
      Log.e("ShareHandler", "Unable to find launch activity for $packageName")
      return
    }
    val shortcutTarget = "$packageName.dynamic_share_target"
    val shortcutBuilder = ShortcutInfoCompat.Builder(applicationContext, media.conversationIdentifier ?: "")
      .setShortLabel(media.speakableGroupName ?: "Unknown")
      .setIsConversation()
      .setCategories(setOf(shortcutTarget))
      .setIntent(intent)
      .setLongLived(true)

    val personBuilder = Person.Builder()
      .setKey(media.conversationIdentifier)
      .setName(media.speakableGroupName)

    media.imageFilePath?.let {
      val bitmap = BitmapFactory.decodeFile(it)
      val icon = IconCompat.createWithAdaptiveBitmap(bitmap)
      shortcutBuilder.setIcon(icon)
      personBuilder.setIcon(icon)
    }

    val person = personBuilder.build()
    shortcutBuilder.setPerson(person)

    val shortcut = shortcutBuilder.build()

    ShortcutManagerCompat.addDynamicShortcuts(applicationContext, listOf(shortcut))
  }

  override fun resetInitialSharedMedia() {
    initialIntentGeneration++
    initialIntentFuture?.cancel(true)
    initialIntentFuture = null
    if (initialMediaWasDelivered) {
      unprotectMediaFiles(initialMedia)
    } else {
      deleteMediaFilesAsync(initialMedia)
    }
    initialMedia = null
    initialMediaWasDelivered = false
    initialError = null
    pendingInitialResults.forEach { it.success(null) }
    pendingInitialResults.clear()
    consumeActivityShareIntent()
  }

  override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
    eventSink = events
    if (events != null) {
      pendingMediaEvents.forEach { media ->
        events.success(media.toMap())
        unprotectMediaFiles(media)
      }
      pendingMediaEvents.clear()
    }
  }

  override fun onCancel(arguments: Any?) {
    eventSink = null
  }

  override fun onAttachedToActivity(binding: ActivityPluginBinding) {
    this.binding = binding
    binding.addOnNewIntentListener(this)
    val isFirstActivity = !hasAttachedToActivity
    val initial = isFirstActivity && !initialMediaWasRequestedBeforeActivity
    hasAttachedToActivity = true

    val flags: Int = binding.activity.intent.flags
    if ((flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0) {
      // The activity was launched from history
      Log.w("ShareHandler", "Skipping share: activity was launched from history")
      if (initial) handleIntent(Intent(), true)
    } else {
      handleIntent(binding.activity.intent, initial)
    }
  }

  override fun onDetachedFromActivityForConfigChanges() {
    binding?.removeOnNewIntentListener(this)
    binding = null
  }

  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
    this.binding = binding
    binding.addOnNewIntentListener(this)
  }

  override fun onDetachedFromActivity() {
    binding?.removeOnNewIntentListener(this)
    binding = null
  }

  override fun onNewIntent(intent: Intent): Boolean {
    if (!isShareIntent(intent)) return false
    handleIntent(intent, false)
    return true
  }

  private fun isShareIntent(intent: Intent): Boolean {
    return intent.action == Intent.ACTION_SEND || intent.action == Intent.ACTION_SEND_MULTIPLE
  }

  private fun handleIntent(intent: Intent, initial: Boolean) {
    val initialGeneration = if (initial) ++initialIntentGeneration else 0
    val taskEngineGeneration = engineGeneration
    if (initial) {
      initialIntentFuture?.cancel(true)
      initialIntentFuture = null
    }
    if (!isShareIntent(intent)) {
      if (initial) completeIntent(null, null, true, initialGeneration, taskEngineGeneration)
      return
    }

    val intentSnapshot = Intent(intent)

    val executor = ioExecutor
    if (executor == null) {
      completeIntent(
        null,
        IllegalStateException("Share handler is detached"),
        initial,
        initialGeneration,
        taskEngineGeneration,
      )
      return
    }

    val task = Runnable {
      var media: Messages.SharedMedia? = null
      var error: Throwable? = null
      try {
        media = mediaFromIntent(intentSnapshot)
      } catch (throwable: Throwable) {
        error = throwable
        Log.e("ShareHandler", "Error parsing shared content", throwable)
      }
      mainHandler.post {
        completeIntent(media, error, initial, initialGeneration, taskEngineGeneration)
      }
    }

    try {
      if (initial) {
        initialIntentFuture = executor.submit(task)
      } else {
        executor.execute(task)
      }
    } catch (exception: RejectedExecutionException) {
      completeIntent(null, exception, initial, initialGeneration, taskEngineGeneration)
    }
  }

  private fun completeIntent(
    media: Messages.SharedMedia?,
    error: Throwable?,
    initial: Boolean,
    initialGeneration: Int,
    taskEngineGeneration: Int,
  ) {
    if (!isEngineAttached || taskEngineGeneration != engineGeneration) {
      deleteMediaFilesAsync(media)
      return
    }

    if (initial) {
      if (initialGeneration != initialIntentGeneration) {
        deleteMediaFilesAsync(media)
        return
      }
      initialIntentFuture = null
      if (initialMediaWasDelivered) {
        unprotectMediaFiles(initialMedia)
      } else {
        deleteMediaFilesAsync(initialMedia)
      }
      initialMedia = media
      initialMediaWasDelivered = false
      protectMediaFiles(media)
      initialError = error
      val results = pendingInitialResults.toList()
      pendingInitialResults.clear()
      if (error == null && media != null && results.isNotEmpty()) {
        initialMediaWasDelivered = true
        unprotectMediaFiles(media)
      }
      results.forEach { result ->
        if (error != null) result.error(error) else result.success(media)
      }
      return
    }

    if (error != null) {
      eventSink?.error("share-error", error.message, Log.getStackTraceString(error))
      return
    }
    if (media == null) return

    val sink = eventSink
    if (sink != null) {
      sink.success(media.toMap())
    } else {
      if (pendingMediaEvents.size >= kMaxPendingMediaEvents) {
        deleteMediaFilesAsync(pendingMediaEvents.removeAt(0))
      }
      protectMediaFiles(media)
      pendingMediaEvents.add(media)
    }
  }

  private fun mediaFromIntent(intent: Intent): Messages.SharedMedia? {
    val attachments = attachmentsFromIntent(intent)
    val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
    val conversationIdentifier = intent.getStringExtra("android.intent.extra.shortcut.ID")
      ?: intent.getStringExtra("conversationIdentifier")

    if (attachments.isEmpty() && text == null && conversationIdentifier == null) return null

    val mediaBuilder = Messages.SharedMedia.Builder()
    if (attachments.isNotEmpty()) mediaBuilder.setAttachments(attachments)
    text?.let { mediaBuilder.setContent(it) }
    conversationIdentifier?.let { mediaBuilder.setConversationIdentifier(it) }
    return mediaBuilder.build()
  }

  private fun attachmentsFromIntent(intent: Intent): List<Messages.SharedAttachment> = synchronized(kCacheLock) {
    val uris = sharedUrisFromIntent(intent)
    if (uris.isEmpty()) return@synchronized emptyList()
    if (uris.size > kMaxAttachmentsPerShare) {
      throw IOException("Share contains more than $kMaxAttachmentsPerShare attachments")
    }

    val cacheDirectory = shareCacheDirectory()
    val cacheFiles = cacheFilesAfterPruning(cacheDirectory)
    if (cacheFiles.size + uris.size > kMaxCacheFiles) {
      throw IOException("Share cache file limit is exhausted")
    }
    val cacheBytes = cacheFiles.sumOf { file -> file.length() }
    val availableCacheBytes = (kMaxCacheBytes - cacheBytes).coerceAtLeast(0L)
    if (availableCacheBytes == 0L) {
      throw IOException("Share cache quota is exhausted")
    }

    val attachments = mutableListOf<Messages.SharedAttachment>()
    val budget = CopyBudget(minOf(kMaxShareBytes, availableCacheBytes))
    try {
      uris.forEach { uri -> attachments.add(attachmentForUri(uri, intent.type, budget)) }
    } catch (throwable: Throwable) {
      attachments.forEach { attachment -> deleteFinalizedAttachmentAfterFailure(File(attachment.path)) }
      throw throwable
    }
    attachments
  }

  private fun sharedUrisFromIntent(intent: Intent): List<Uri> {
    val uris = LinkedHashSet<Uri>()
    when (intent.action) {
      Intent.ACTION_SEND -> getParcelableStream(intent)?.let { addSharedUri(uris, it) }
      Intent.ACTION_SEND_MULTIPLE -> getParcelableStreams(intent)?.forEach { addSharedUri(uris, it) }
    }

    intent.clipData?.let { clipData ->
      for (index in 0 until clipData.itemCount) {
        clipData.getItemAt(index).uri?.let { addSharedUri(uris, it) }
      }
    }
    intent.data
      ?.let { addSharedUri(uris, it) }

    if (uris.isEmpty() && intent.type?.startsWith("text/") != true) {
      val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
      val textUri = text?.let(Uri::parse)
      textUri?.let { addSharedUri(uris, it) }
    }
    return uris.toList()
  }

  private fun addSharedUri(uris: MutableSet<Uri>, uri: Uri) {
    if (uri.scheme == ContentResolver.SCHEME_CONTENT && isExternalContentUri(uri)) {
      uris.add(uri)
    } else {
      Log.w("ShareHandler", "Ignoring shared URI with unsupported or untrusted authority")
    }
  }

  private fun isExternalContentUri(uri: Uri): Boolean {
    val authority = uri.authority ?: return false
    val normalizedAuthority = authority.substringAfterLast('@').lowercase()
    return normalizedAuthority !in ownProviderAuthorities
  }

  @Suppress("DEPRECATION")
  private fun loadOwnProviderAuthorities(): Set<String> {
    val packageInfo = applicationContext.packageManager.getPackageInfo(
      applicationContext.packageName,
      PackageManager.GET_PROVIDERS,
    )
    return packageInfo.providers
      ?.flatMap { provider -> provider.authority.orEmpty().split(';') }
      ?.filter(String::isNotEmpty)
      ?.map { authority -> authority.lowercase() }
      ?.toSet()
      ?: emptySet()
  }

  @Suppress("DEPRECATION")
  private fun getParcelableStream(intent: Intent): Uri? {
    return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
      intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
    } else {
      intent.getParcelableExtra(Intent.EXTRA_STREAM)
    }
  }

  @Suppress("DEPRECATION")
  private fun getParcelableStreams(intent: Intent): ArrayList<Uri>? {
    return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
      intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
    } else {
      intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)
    }
  }

  private fun attachmentForUri(
    uri: Uri,
    declaredMimeType: String?,
    budget: CopyBudget,
  ): Messages.SharedAttachment {
    val contentResolver = applicationContext.contentResolver
    val mimeType = contentResolver.getType(uri) ?: declaredMimeType
    val cacheDirectory = shareCacheDirectory()

    val fileName = safeFileName(contentResolver, uri, mimeType)
    val destinationFile = uniqueCachePath(cacheDirectory, fileName)
    val partialFile = uniqueCacheFile(partialCacheDirectory(cacheDirectory), destinationFile.name)
    var finalized = false

    try {
      throwIfCopyInterrupted()
      val inputStream = contentResolver.openInputStream(uri)
        ?: throw IOException("Unable to open shared URI: $uri")
      inputStream.use { input ->
        FileOutputStream(partialFile).use { output ->
          val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
          while (true) {
            throwIfCopyInterrupted()
            val bytesRead = input.read(buffer)
            throwIfCopyInterrupted()
            if (bytesRead < 0) break
            budget.remainingBytes -= bytesRead
            if (budget.remainingBytes < 0) {
              throw IOException("Shared content exceeds 2 GiB limit")
            }
            output.write(buffer, 0, bytesRead)
          }
        }
      }
      throwIfCopyInterrupted()
      if (destinationFile.exists() || !partialFile.renameTo(destinationFile)) {
        throw IOException("Unable to finalize shared attachment")
      }
      finalized = true

      return Messages.SharedAttachment.Builder()
        .setPath(destinationFile.absolutePath)
        .setType(getAttachmentType(mimeType))
        .build()
    } catch (throwable: Throwable) {
      if (!partialFile.delete() && partialFile.exists()) {
        Log.w("ShareHandler", "Unable to delete partial share attachment")
      }
      if (finalized) deleteFinalizedAttachmentAfterFailure(destinationFile)
      throw throwable
    }
  }

  private class CopyBudget(var remainingBytes: Long)

  private fun deleteFinalizedAttachmentAfterFailure(file: File) {
    try {
      if (!file.exists() || file.delete()) return

      val retryTimestamp =
        (System.currentTimeMillis() - kCacheFileRetentionMillis - 1L).coerceAtLeast(1L)
      val markedForRetry = file.setLastModified(retryTimestamp)
      if (markedForRetry) {
        Log.w(
          "ShareHandler",
          "Unable to delete finalized share attachment; marked it for cleanup retry",
        )
      } else {
        Log.w(
          "ShareHandler",
          "Unable to delete finalized share attachment or mark it for cleanup retry",
        )
      }
    } catch (exception: SecurityException) {
      Log.w("ShareHandler", "Unable to clean up finalized share attachment", exception)
    }
  }

  private fun shareCacheDirectory(): File {
    val directory = File(applicationContext.cacheDir, "share_handler")
    if (!directory.exists() && !directory.mkdirs()) {
      throw IOException("Unable to create share cache directory")
    }
    return directory.canonicalFile
  }

  private fun cacheFilesAfterPruning(cacheDirectory: File): List<File> {
    val partialDirectory = partialCacheDirectory(cacheDirectory)
    partialDirectory.listFiles()?.filter(File::isFile).orEmpty().forEach { file ->
      if (!file.delete()) Log.w("ShareHandler", "Unable to delete orphaned partial share file")
    }

    val expirationCutoff = System.currentTimeMillis() - kCacheFileRetentionMillis
    cacheDirectory.listFiles()?.filter(File::isFile).orEmpty().forEach { file ->
      val lastModified = file.lastModified()
      val isExpiredFile = lastModified > 0L && lastModified <= expirationCutoff
      if (isExpiredFile && file.absolutePath !in protectedCachePaths && !file.delete()) {
        Log.w("ShareHandler", "Unable to delete stale share cache file")
      }
    }
    val cacheFiles = cacheDirectory.listFiles()?.filter(File::isFile).orEmpty()
    val orphanedPartialFiles = partialDirectory.listFiles()?.filter(File::isFile).orEmpty()
    return cacheFiles + orphanedPartialFiles
  }

  private fun partialCacheDirectory(cacheDirectory: File): File {
    val directory = File(cacheDirectory, kPartialCacheDirectoryName)
    if (!directory.exists() && !directory.mkdirs()) {
      throw IOException("Unable to create partial share cache directory")
    }
    if (!directory.isDirectory) throw IOException("Partial share cache path is not a directory")
    val canonicalDirectory = directory.canonicalFile
    if (canonicalDirectory.parentFile != cacheDirectory.canonicalFile) {
      throw SecurityException("Partial share file escaped cache directory")
    }
    return canonicalDirectory
  }

  private fun safeFileName(contentResolver: ContentResolver, uri: Uri, mimeType: String?): String {
    val displayName = try {
      contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
        if (!cursor.moveToFirst()) return@use null
        val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
        if (nameIndex >= 0) cursor.getString(nameIndex) else null
      }
    } catch (exception: Exception) {
      Log.w("ShareHandler", "Unable to read display name for $uri", exception)
      null
    }

    val leafName = displayName
      ?.substringAfterLast('/')
      ?.substringAfterLast('\\')
      ?.map { character -> if (character.code < 32 || character.code == 127) '_' else character }
      ?.joinToString("")
      ?.trim()
      ?.takeUnless { it.isEmpty() || it == "." || it == ".." }

    var fileName = leafName ?: "shared_${System.currentTimeMillis()}"
    if (!fileName.contains('.')) {
      MimeTypeMap.getSingleton().getExtensionFromMimeType(mimeType)?.let { extension ->
        fileName += ".$extension"
      }
    }
    return truncateFileName(fileName)
  }

  private fun uniqueCachePath(cacheDirectory: File, fileName: String): File {
    val canonicalDirectory = cacheDirectory.canonicalFile
    val extension = File(fileName).extension
    val baseName = File(fileName).nameWithoutExtension.ifEmpty { "shared" }
    var suffix = 0

    while (true) {
      val candidateName = if (suffix == 0) {
        fileName
      } else if (extension.isEmpty()) {
        "${baseName}_$suffix"
      } else {
        "${baseName}_$suffix.$extension"
      }
      val candidate = File(canonicalDirectory, candidateName).canonicalFile
      if (candidate.parentFile != canonicalDirectory) {
        throw SecurityException("Shared file escaped cache directory")
      }
      if (!candidate.exists()) return candidate
      suffix++
    }
  }

  private fun uniqueCacheFile(cacheDirectory: File, fileName: String): File {
    while (true) {
      val candidate = uniqueCachePath(cacheDirectory, fileName)
      if (candidate.createNewFile()) return candidate
    }
  }

  private fun throwIfCopyInterrupted() {
    if (Thread.currentThread().isInterrupted) {
      throw InterruptedIOException("Shared attachment copy was cancelled")
    }
  }

  private fun protectMediaFiles(media: Messages.SharedMedia?) {
    media?.attachments?.forEach { attachment -> protectedCachePaths.add(attachment.path) }
  }

  private fun unprotectMediaFiles(media: Messages.SharedMedia?) {
    media?.attachments?.forEach { attachment -> protectedCachePaths.remove(attachment.path) }
  }

  private fun truncateFileName(fileName: String): String {
    val extensionIndex = fileName.lastIndexOf('.').takeIf { it > 0 } ?: fileName.length
    val extension = if (extensionIndex < fileName.length) {
      truncateUtf8(fileName.substring(extensionIndex), 32)
    } else {
      ""
    }
    val extensionBytes = extension.toByteArray(Charsets.UTF_8).size
    val baseName = truncateUtf8(fileName.substring(0, extensionIndex), 180 - extensionBytes)
    return baseName.ifEmpty { "shared" } + extension
  }

  private fun truncateUtf8(value: String, maxBytes: Int): String {
    val result = StringBuilder()
    var byteCount = 0
    var index = 0
    while (index < value.length) {
      val codePoint = value.codePointAt(index)
      val character = String(Character.toChars(codePoint))
      val characterBytes = character.toByteArray(Charsets.UTF_8).size
      if (byteCount + characterBytes > maxBytes) break
      result.append(character)
      byteCount += characterBytes
      index += Character.charCount(codePoint)
    }
    return result.toString()
  }

  private fun deleteMediaFilesAsync(media: Messages.SharedMedia?) {
    val paths = media?.attachments?.map { attachment -> attachment.path }.orEmpty()
    if (paths.isEmpty()) return
    paths.forEach { path -> protectedCachePaths.remove(path) }

    kCleanupExecutor.execute {
      synchronized(kCacheLock) {
        val cacheDirectory = try {
          shareCacheDirectory()
        } catch (_: IOException) {
          return@synchronized
        }
        paths.forEach { path ->
          try {
            val file = File(path).canonicalFile
            if (file.parentFile == cacheDirectory) deleteFinalizedAttachmentAfterFailure(file)
          } catch (_: IOException) {
            // Ignore cleanup failures for files that were never delivered.
          }
        }
      }
    }
  }

  private fun consumeActivityShareIntent() {
    val activity = binding?.activity ?: return
    val intent = activity.intent ?: return
    if (!isShareIntent(intent)) return

    activity.intent = Intent(intent).apply {
      action = null
      type = null
      data = null
      clipData = null
      removeExtra(Intent.EXTRA_STREAM)
      removeExtra(Intent.EXTRA_TEXT)
      removeExtra(Intent.EXTRA_SUBJECT)
      removeExtra(Intent.EXTRA_TITLE)
      removeExtra("android.intent.extra.shortcut.ID")
      removeExtra("conversationIdentifier")
    }
  }

  // Function to determine the attachment type using the MIME type
  private fun getAttachmentType(mimeType: String?): Messages.SharedAttachmentType {
    return when {
      mimeType?.startsWith("image") == true -> Messages.SharedAttachmentType.image
      mimeType?.startsWith("video") == true -> Messages.SharedAttachmentType.video
      mimeType?.startsWith("audio") == true -> Messages.SharedAttachmentType.audio
      else -> Messages.SharedAttachmentType.file
    }
  }
}
