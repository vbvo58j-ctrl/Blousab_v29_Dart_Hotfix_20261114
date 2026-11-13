"""Static source contracts + codec smoke vectors (not a Flutter/device test)."""
from pathlib import Path
from hashlib import sha256
import gzip, os, sys
R = Path(__file__).resolve().parents[1]
checks = {
    'AI_OS_RESUMABLE_DOWNLOAD': ('lib/services/blousab_ai_service.dart', ["_downloadChannel", "_watchDownload", "_expectedChecksum", "sha256.bind(original.openRead())"]),
    'ANDROID_DOWNLOAD_MANAGER': ('android/app/src/main/kotlin/com/plosap/myapp/MainActivity.kt', ['DownloadManager.Request', 'DownloadManager.STATUS_PAUSED', '.setAllowedOverMetered(true)']),
    'AI_CHAT_ROW_PROGRESS': ('lib/screens/communities_screen.dart', ['_aiRow()', 'BlousabAiStatus.downloading', 'LinearProgressIndicator']),
    'CENTRAL_ROUTER': ('lib/services/chat_inbox_router.dart', ['class ChatInboxRouter', 'directId(sender, recipient)', 'retryRelays()', 'retryPendingMessages()', '_receiveChunk(', '_decodeBounded(']),
    'TARGET_BINDING': ('lib/screens/chat_screen.dart', ['_acceptVerifiedConnection(', '_targetMatchesConnection(', 'blousab_peer_verified_$bt']),
    'ONE_GROUP_RECEIVER': ('lib/screens/communities_screen.dart', ['Messages and relay packets are handled exactly once', '_inboxChanges']),
    'SERIAL_MESSAGE_STORAGE': ('lib/services/message_store.dart', ['static Future<void> _writes', '=> _locked(() async {']),
    'FILE_CHUNK_SHA256_APK': ('lib/screens/chat_screen.dart', ['FileType.any', 'Icons.android_rounded', "const Text('تثبيت'"] ),
    'IN_APP_VIDEO_PREPARATION': ('lib/screens/media_editor.dart', ['_preparingPercent', 'VideoCompress.compressProgress$', "'جارٍ تجهيز الفيديو للنشر'", 'outputPath']),
    'FEED_STORY_ADAPTIVE_SYNC': ('lib/screens/public_feed_screen.dart', ['useGzip', 'expectedHash', 'sha256.convert(media)']),
    'STORY_BOUNDED_SYNC': ('lib/screens/stories_strip.dart', ['story_media_chunk', 'story_media_end', 'sha256.convert(media)']),
    'EPHEMERAL_MESSAGES_INLINE_REPLY': ('lib/services/notification_service.dart', ['_messageIdsByConversation', 'blousab_inline_reply', 'blousabNotificationReplyBackground', 'PendingMessageStore.instance.enqueue']),
    'TOAST_SUCCESS_FAILURE': ('lib/widgets/blousab_visuals.dart', ['Icons.check_rounded', 'Icons.close_rounded', 'Color(0xFFFF5C7A)']),
}
fail = 0
for label, (filename, needles) in checks.items():
    text = (R / filename).read_text()
    missing = [n for n in needles if n not in text]
    print(('FAIL' if missing else 'PASS'), label, (str(missing) if missing else ''))
    fail += bool(missing)
# Codec model only: exercise gzip/not-gzip 32 KiB chunking with hash checks.
for kind, payload in (('compressible', b'hello 123\n' * 10000), ('already_random', os.urandom(124_321))):
    zipped = gzip.compress(payload)
    wire = zipped if len(zipped) + 24 < len(payload) else payload
    pieces = [wire[i:i+32*1024] for i in range(0, len(wire), 32*1024)]
    restored = gzip.decompress(b''.join(pieces)) if wire is zipped else b''.join(pieces)
    match = sha256(restored).digest() == sha256(payload).digest()
    tampered = sha256(restored + b'!').digest() != sha256(payload).digest()
    ok = match and tampered
    print(('PASS' if ok else 'FAIL'), 'CODEC_VECTOR_' + kind)
    fail += not ok
print('INFO: Flutter, native Android, multi-device transport, UI and security remain UNTESTED by this script')
sys.exit(1 if fail else 0)
