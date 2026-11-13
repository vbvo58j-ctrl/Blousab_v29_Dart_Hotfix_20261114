import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/blousab_message.dart';
import 'bluetooth_classic_service.dart';
import 'community_store.dart';
import 'local_network_service.dart';
import 'message_store.dart';
import 'notification_service.dart';
import 'pending_message_store.dart';
import 'relay_policy.dart';
import 'relay_queue_store.dart';

class InboxChange {
  const InboxChange(this.conversationId, this.type, this.messageId);
  final String conversationId;
  final String type;
  final String messageId;
}

/// One receiver for ALL conversations while the Flutter engine is alive.
/// Intermediaries never read or save other users' chat content. Their job is
/// bounded store-and-forward; friend/block status does not control relaying.
/// Not a background Android service and not end-to-end encryption.
class ChatInboxRouter {
  ChatInboxRouter._();
  static final ChatInboxRouter instance = ChatInboxRouter._();
  final _changes = StreamController<InboxChange>.broadcast();
  Stream<InboxChange> get changes => _changes.stream;
  final MessageStore _store = MessageStore();
  final CommunityStore _communities = CommunityStore();
  String _me = '';
  bool _forwarding = false;
  bool _resending = false;
  Timer? _retryTimer;
  final Map<String, Completer<void>> _chunkWaiters = <String, Completer<void>>{};
  Future<void> _fileWrites = Future<void>.value();

  void start(String userId) {
    if (userId.isEmpty) return;
    _me = userId;
    _retryTimer ??= Timer.periodic(const Duration(seconds: 25), (_) {
      unawaited(retryRelays());
      unawaited(retryPendingMessages());
    });
    unawaited(retryRelays());
    unawaited(retryPendingMessages());
  }

  static String directId(String first, String second) {
    final ids = <String>[first, second]..sort();
    return 'dm_${ids[0]}_${ids[1]}';
  }

  Future<void> accept(String raw, String? address) async {
    if (_me.isEmpty || utf8.encode(raw).length > RelayPolicy.maxPacketBytes) return;
    Map<String, dynamic> data;
    try {
      final parsed = jsonDecode(raw);
      if (parsed is! Map) return;
      data = Map<String, dynamic>.from(parsed);
    } catch (_) { return; }
    final type = data['type']?.toString() ?? '';
    if (!const {'chat', 'text', 'file', 'file_chunk', 'file_chunk_ack', 'file_done', 'delivery_ack', 'read_ack'}.contains(type)) return;
    final sender = data['senderId']?.toString() ?? '';
    final recipient = data['recipientId']?.toString() ?? '';
    final conversation = data['conversationId']?.toString() ?? '';
    final id = data['id']?.toString() ?? '';
    if (sender.isEmpty || sender == _me || sender.length > 256 ||
        recipient.isEmpty || recipient.length > 256 || conversation.isEmpty) return;
    final isCommunity = !conversation.startsWith('dm_');
    if (!isCommunity && conversation != directId(sender, recipient)) return;
    if (isCommunity && recipient != '*') return;

    if (recipient != _me && recipient != '*') {
      // Relay ONLY; no chat persistence or visible notification. No friendship
      // checks, no blocking checks, no attempt to present forwarded messages.
      await _offerRelay(data, raw);
      return;
    }

    // Community packets must originate from an approved participant.
    if (isCommunity) {
      final community = await _communities.findById(conversation);
      if (community == null || !community.members.any((m) =>
          m.id == sender && m.status.name == 'approved')) {
        // An intermediate relay does not need membership, friendship, or
        // permission to view this group. It only forwards a bounded packet.
        await _offerRelay(data, raw);
        return;
      }
    }

    if (type == 'file_chunk_ack' || type == 'file_done') {
      if (recipient != _me || isCommunity) return;
      final ackFor = data['ackFor']?.toString() ?? '';
      if (ackFor.isEmpty) return;
      final waiter = _chunkWaiters[ackFor];
      if (waiter != null && !waiter.isCompleted) waiter.complete();
      if (type == 'file_done') {
        await _store.markDelivered(conversation, ackFor);
        _changes.add(InboxChange(conversation, 'delivery_ack', ackFor));
      }
      return;
    }
    if (type == 'delivery_ack' || type == 'read_ack') {
      final ackFor = data['ackFor']?.toString() ?? '';
      if (ackFor.isEmpty || recipient != _me || isCommunity) return;
      final originals = await _store.getMessages(conversation);
      if (!originals.any((m) => m.id == ackFor && m.isMine && m.senderId == _me)) return;
      if (type == 'delivery_ack') {
        await _store.markDelivered(conversation, ackFor);
        await PendingMessageStore.instance.remove(ackFor);
        await RelayQueueStore.instance.remove(ackFor);
      } else {
        await _store.markRead(conversation, ackFor);
      }
      _changes.add(InboxChange(conversation, type, ackFor));
      return;
    }
    if (type == 'file_chunk') {
      if (recipient != _me || isCommunity) return;
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('blousab_blocked_peer_$sender') ?? false) return;
      await _receiveChunk(data, address);
      return;
    }
    if (recipient == '*' && isCommunity == false) return;
    if (id.isEmpty || id.length > 160) return;
    if (recipient == _me) {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('blousab_blocked_peer_$sender') ?? false) return;
      // Physical-address binding only when we know the peer. Relay nodes can
      // legitimately have different addresses; claimed sender always must
      // match the canonical conversation and recipient.
      if (address != null && !address.startsWith('lan:')) {
        final boundId = prefs.getString('blousab_peer_id_$address');
        if (boundId != null && boundId.isNotEmpty && boundId != sender &&
            data['hopCount'] == null && data['relayPath'] == null) return;
      }
    }
    final originals = await _store.getMessages(conversation);
    if (originals.any((m) => m.id == id)) {
      await _sendAck(conversation, id, sender, address, 'delivery_ack');
      return;
    }
    String body = data['text']?.toString() ?? '';
    String? attachment;
    String? name;
    if (type == 'file') {
      name = data['fileName']?.toString() ?? 'ملف';
      final encoded = data['data']?.toString() ?? '';
      if (encoded.isEmpty || encoded.length > 760000) return;
      try {
        final wire = base64Decode(encoded);
        if (wire.length > 550000) return;
        final bytes = await _decodeBounded(wire, data['compressed'] == 'gzip', 4 * 1024 * 1024);
        if (bytes == null || bytes.isEmpty) return;
        final expected = data['sha256']?.toString() ?? '';
        if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(expected) ||
            sha256.convert(bytes).toString() != expected) return;
        final dir = await getApplicationDocumentsDirectory();
        final safeName = name.replaceAll(RegExp(r'[^\w.\- ()\u0600-\u06FF]'), '_');
        final file = File('${dir.path}/received_${id.hashCode}_$safeName');
        await file.writeAsBytes(bytes, flush: true);
        attachment = file.path;
        body = '📎 $name';
      } catch (_) { return; }
    }
    if (body.trim().isEmpty) return;
    final message = BlousabMessage(
      id: id, conversationId: conversation, senderId: sender,
      senderName: data['senderName']?.toString() ?? 'مستخدم بلوساب',
      text: body, sentAt: DateTime.tryParse(data['sentAt']?.toString() ?? '')?.toLocal() ?? DateTime.now(),
      isMine: false, attachmentName: name, attachmentPath: attachment,
    );
    await _store.saveMessage(message);
    // A new DM auto-appears in the chats list even if no ChatScreen was open.
    if (!isCommunity) await _ensureConversation(conversation, sender, message.senderName, address);
    _changes.add(InboxChange(conversation, 'message', id));
    if (recipient == _me) {
      await _sendAck(conversation, id, sender, address, 'delivery_ack');
    }
    await NotificationService.instance.handleIncomingPayload(raw, currentUserId: _me);
    if (recipient == '*') await _offerRelay(data, raw);
  }

  Future<void> _ensureConversation(String id, String peerId, String name, String? address) async {
    final prefs = await SharedPreferences.getInstance();
    final rows = prefs.getStringList('blousab_direct_chats_v1') ?? <String>[];
    if (rows.any((r) { try { return jsonDecode(r)['conversationId'] == id; } catch (_) { return false; } })) return;
    rows.insert(0, jsonEncode({'conversationId': id, 'peerId': peerId,
      'peerName': name, 'peerAddress': address ?? ''}));
    await prefs.setStringList('blousab_direct_chats_v1', rows.take(100).toList());
  }

  /// Sends file pieces in bounded frames with per-piece acknowledgement.
  /// Only a verified target conversation may receive the content. Compression
  /// is adaptive: JPEG/MP4/APK may already be packed better than gzip.
  Future<void> sendFile({required File file, required String fileName,
      required String conversationId, required String userName,
      String? bluetoothAddress, String? wifiAddress,
      void Function(double)? onProgress}) async {
    final peer = _otherUserInDirect(conversationId);
    if (peer == null) throw StateError('هوية المستلم غير صالحة.');
    final length = await file.length();
    if (length <= 0 || length > 50 * 1024 * 1024) {
      throw StateError('يجب ألا يزيد حجم الملف عن 50 ميغابايت.');
    }
    final digest = (await sha256.bind(file.openRead()).first).toString();
    final transferId = sha256.convert(utf8.encode('${DateTime.now().microsecondsSinceEpoch}|$_me|$fileName')).toString().substring(0, 32);
    const chunkSize = 32 * 1024;
    final total = (length / chunkSize).ceil();
    final safeName = fileName.replaceAll(RegExp(r'[^\w.\- ()\u0600-\u06FF]'), '_');
    final outgoing = BlousabMessage(
      id: transferId, conversationId: conversationId, senderId: _me,
      senderName: userName, text: '📎 $safeName', sentAt: DateTime.now(),
      isMine: true, deliveryStatus: 'pending', attachmentName: safeName,
      attachmentPath: file.path,
    );
    await _store.saveMessage(outgoing);
    _changes.add(InboxChange(conversationId, 'message', transferId));
    final reader = await file.open();
    try {
      for (var index = 0; index < total; index++) {
        final bytes = await reader.read(chunkSize);
        if (bytes.isEmpty) throw StateError('فشل قراءة جزء من الملف.');
        final zipped = gzip.encode(bytes);
        final useGzip = zipped.length + 24 < bytes.length;
        final payloadBytes = useGzip ? zipped : bytes;
        final chunkId = '${transferId}_$index';
        final created = DateTime.now().toUtc().toIso8601String();
        final payload = jsonEncode({
          'type': 'file_chunk', 'id': chunkId, 'transferId': transferId,
          'conversationId': conversationId, 'senderId': _me, 'senderName': userName,
          'recipientId': peer, 'createdAt': created, 'sentAt': created,
          'relayEnabled': true, 'hopCount': 0, 'relayPath': <String>[],
          'fileName': safeName, 'size': length, 'count': total, 'index': index,
          'sha256': digest, 'chunkSha256': sha256.convert(bytes).toString(),
          'encoding': useGzip ? 'gzip' : 'raw', 'data': base64Encode(payloadBytes),
        });
        final ack = Completer<void>();
        _chunkWaiters[chunkId] = ack;
        try {
          var received = false;
          for (var attempt = 0; attempt < 4 && !received; attempt++) {
            await _sendFileFrame(payload, peer, bluetoothAddress, wifiAddress);
            try { await ack.future.timeout(const Duration(seconds: 5)); received = true; }
            on TimeoutException { /* The same chunkId makes retries idempotent. */ }
          }
          if (!received) throw StateError('لم يصل تأكيد استلام الجزء ${index + 1} من $total.');
        } finally { _chunkWaiters.remove(chunkId); }
        onProgress?.call((index + 1) / total);
      }
    } finally { await reader.close(); }
    // Last per-chunk ACK means bytes are stored. Wait for final SHA256 check.
    final finalAck = Completer<void>();
    _chunkWaiters[transferId] = finalAck;
    try {
      // If the final notification raced ahead, state may already be delivered.
      final rows = await _store.getMessages(conversationId);
      if (!rows.any((m) => m.id == transferId && m.isDelivered)) {
        try { await finalAck.future.timeout(const Duration(seconds: 12)); }
        on TimeoutException {
          final refreshed = await _store.getMessages(conversationId);
          if (!refreshed.any((m) => m.id == transferId && m.isDelivered)) {
            throw StateError('اكتملت الأجزاء لكن لم يصل تأكيد التحقق النهائي.');
          }
        }
      }
    } finally { _chunkWaiters.remove(transferId); }
    onProgress?.call(1);
  }

  String? _otherUserInDirect(String conversation) {
    if (_me.isEmpty || !conversation.startsWith('dm_')) return null;
    final suffix = conversation.substring(3);
    final before = '${_me}_';
    final after = '_$_me';
    final id = suffix.startsWith(before) ? suffix.substring(before.length)
        : suffix.endsWith(after) ? suffix.substring(0, suffix.length - after.length) : '';
    return id.isNotEmpty && id != _me && directId(_me, id) == conversation ? id : null;
  }

  Future<void> _sendFileFrame(String raw, String peer, String? bt, String? wifi) async {
    var sent = false;
    if (wifi != null && wifi.isNotEmpty) {
      try { await LocalNetworkService.instance.sendMessageToPeer(address: wifi, payload: raw); sent = true; } catch (_) {}
    }
    if (bt != null && bt.isNotEmpty) {
      try { await BluetoothClassicService.instance.sendMessage(address: bt, message: raw); sent = true; } catch (_) {}
    }
    if (!sent) await transmit(raw, recipientId: peer);
  }

  Future<void> _receiveChunk(Map<String, dynamic> packet, String? address) async {
    // Serialize filesystem updates: Bluetooth + LAN can deliver duplicates at
    // the same time. ACK only after the piece has been flushed to disk.
    final done = Completer<void>();
    _fileWrites = _fileWrites.then((_) async {
      try { await _writeChunk(packet, address); done.complete(); }
      catch (e) { done.completeError(e); }
    }).catchError((_) {});
    try { await done.future; } catch (_) { /* never ACK invalid bytes */ }
  }

  // Do not decompress untrusted gzip into unbounded memory (zip bombs).
  Future<List<int>?> _decodeBounded(List<int> wire, bool compressed, int maxSize) async {
    if (!compressed) return wire.length <= maxSize ? wire : null;
    final output = <int>[];
    try {
      await for (final part in gzip.decoder.bind(Stream<List<int>>.value(wire))) {
        if (output.length + part.length > maxSize) return null;
        output.addAll(part);
      }
      return output;
    } catch (_) { return null; }
  }

  Future<void> _writeChunk(Map<String, dynamic> d, String? address) async {
    final transfer = d['transferId']?.toString() ?? '';
    final id = d['id']?.toString() ?? '';
    final index = (d['index'] as num?)?.toInt() ?? -1;
    final count = (d['count'] as num?)?.toInt() ?? 0;
    final size = (d['size'] as num?)?.toInt() ?? 0;
    final expected = d['sha256']?.toString() ?? '';
    final chunkHash = d['chunkSha256']?.toString() ?? '';
    final name = d['fileName']?.toString() ?? '';
    final sender = d['senderId']?.toString() ?? '';
    final cid = d['conversationId']?.toString() ?? '';
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(transfer) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(expected) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(chunkHash) ||
        id != '${transfer}_$index' || index < 0 || count < 1 || count > 1600 ||
        index >= count || size <= 0 || size > 50 * 1024 * 1024 ||
        count != (size / (32 * 1024)).ceil() || name.isEmpty || name.length > 180) return;
    final encoded = d['data']?.toString() ?? '';
    if (encoded.isEmpty || encoded.length > 100000) return;
    final encodedBytes = base64Decode(encoded);
    final bytes = await _decodeBounded(encodedBytes, d['encoding'] == 'gzip', 32 * 1024);
    if (bytes == null || bytes.isEmpty ||
        bytes.length != (index == count - 1 ? size - index * 32 * 1024 : 32 * 1024) ||
        sha256.convert(bytes).toString() != chunkHash) return;
    final base = await getApplicationSupportDirectory();
    final parts = Directory('${base.path}/blousab_transfers/$transfer');
    await parts.create(recursive: true);
    final marker = File('${parts.path}/meta.json');
    final safeName = name.replaceAll(RegExp(r'[^\w.\- ()\u0600-\u06FF]'), '_');
    final meta = <String, dynamic>{'id': transfer, 'sha256': expected, 'size': size,
      'count': count, 'name': safeName, 'sender': sender, 'conversation': cid};
    if (await marker.exists()) {
      if (await marker.readAsString() != jsonEncode(meta)) return;
    } else { await marker.writeAsString(jsonEncode(meta), flush: true); }
    final piece = File('${parts.path}/$index.part');
    if (!await piece.exists()) await piece.writeAsBytes(bytes, flush: true);
    await _sendAck(cid, id, sender, address, 'file_chunk_ack');
    if (index != count - 1 && (await parts.list().where((e) => e.path.endsWith('.part')).length) < count) return;
    for (var i = 0; i < count; i++) { if (!await File('${parts.path}/$i.part').exists()) return; }
    final documents = await getApplicationDocumentsDirectory();
    final output = File('${documents.path}/received_${transfer}_$safeName');
    if (!await output.exists()) {
      final pending = File('${output.path}.part');
      final sink = pending.openWrite();
      try {
        for (var i = 0; i < count; i++) { await sink.addStream(File('${parts.path}/$i.part').openRead()); }
        await sink.flush();
      } finally { await sink.close(); }
      final computed = (await sha256.bind(pending.openRead()).first).toString();
      if (computed != expected || await pending.length() != size) {
        await pending.delete(); return;
      }
      await pending.rename(output.path);
    }
    final message = BlousabMessage(id: transfer, conversationId: cid, senderId: sender,
      senderName: d['senderName']?.toString() ?? 'مستخدم بلوساب',
      text: '📎 $safeName', sentAt: DateTime.now(), isMine: false,
      attachmentName: safeName, attachmentPath: output.path);
    await _store.saveMessage(message);
    await _ensureConversation(cid, sender, message.senderName, address);
    _changes.add(InboxChange(cid, 'message', transfer));
    await NotificationService.instance.handleIncomingPayload(jsonEncode({
      'type': 'file', 'senderId': sender, 'senderName': message.senderName,
      'recipientId': _me, 'conversationId': cid, 'id': transfer,
    }), currentUserId: _me);
    await _sendAck(cid, transfer, sender, address, 'file_done');
    // Keep completed segments only until final ACK; avoid deleting them before
    // receiver could acknowledge a repeated terminal piece after reconnect.
    // Periodic cleanup is needed for long-lived installations.
  }

  Future<void> _sendAck(String conversation, String id, String recipient, String? address, String type) async {
    final now = DateTime.now().toUtc().toIso8601String();
    final ack = jsonEncode({'type': type, 'id': '${type}_${id}_$_me',
      'ackFor': id, 'conversationId': conversation, 'senderId': _me,
      'recipientId': recipient, 'relayEnabled': true, 'hopCount': 0,
      'relayPath': <String>[], 'createdAt': now, 'sentAt': now});
    // Direct ACK first; opportunistic multi-hop fallback if required.
    try {
      if (address != null && address.isNotEmpty) {
        if (address.startsWith('lan:')) {
          await LocalNetworkService.instance.sendControlPacket(address: address, payload: ack);
        } else {
          await BluetoothClassicService.instance.sendMessage(address: address, message: ack);
        }
      }
    } catch (_) {}
    await transmit(ack, recipientId: recipient);
  }

  Future<void> transmit(String raw, {required String recipientId}) async {
    var sent = false;
    try { sent = await LocalNetworkService.instance.trySendViaBestKnownRoute(
      recipientId: recipientId, payload: raw); } catch (_) {}
    if (!sent) {
      try { await LocalNetworkService.instance.broadcastMessage(raw); } catch (_) {}
      try { await BluetoothClassicService.instance.broadcastMessage(raw); } catch (_) {}
    }
  }

  Future<void> _offerRelay(Map<String, dynamic> decoded, String raw) async {
    if (decoded['relayEnabled'] != true || _me.isEmpty) return;
    if (decoded['senderId'] == _me) return;
    if (decoded['recipientId'] == _me) return;
    final prepared = RelayPolicy().acceptAndPrepareForward(raw, thisDeviceId: _me);
    if (prepared == null) return;
    final id = decoded['id']?.toString() ?? '';
    if (!await RelayQueueStore.instance.markSeen(id)) return;
    await RelayQueueStore.instance.enqueue(prepared);
    unawaited(retryRelays());
  }

  /// Recover conversations even when no individual ChatScreen is open.
  /// Device selection is NEVER guessed: packets have canonical recipient IDs
  /// and best-route/store-and-forward decides the transport hop.
  Future<void> retryPendingMessages() async {
    if (_resending || _me.isEmpty) return;
    _resending = true;
    try {
      final now = DateTime.now();
      for (final entry in await PendingMessageStore.instance.list()) {
        final payload = entry['payload']?.toString() ?? '';
        final messageId = entry['messageId']?.toString() ?? '';
        final cid = entry['conversationId']?.toString() ?? '';
        if (payload.isEmpty || messageId.isEmpty || cid.isEmpty ||
            !cid.startsWith('dm_')) continue;
        final recipient = _otherUserInDirect(cid);
        if (recipient == null) continue;
        final last = DateTime.tryParse(entry['lastAttemptAt']?.toString() ?? '');
        final attempts = (entry['attempts'] as num?)?.toInt() ?? 0;
        final delay = Duration(seconds: 5 * (1 << (attempts > 6 ? 6 : attempts)));
        if (last != null && now.difference(last) < delay) continue;
        await PendingMessageStore.instance.noteAttempt(messageId);
        try { await transmit(payload, recipientId: recipient); } catch (_) {}
      }
    } finally { _resending = false; }
  }

  Future<void> retryRelays() async {
    if (_forwarding || _me.isEmpty) return;
    _forwarding = true;
    try {
      for (final row in await RelayQueueStore.instance.list()) {
        final id = row['id']?.toString() ?? '';
        final raw = row['payload']?.toString() ?? '';
        final attempts = (row['attempts'] as num?)?.toInt() ?? 0;
        if (id.isEmpty || raw.isEmpty || attempts >= 30) continue;
        final last = DateTime.tryParse(row['lastAttemptAt']?.toString() ?? '');
        if (last != null && DateTime.now().difference(last) < Duration(seconds: 5 * (1 << (attempts > 6 ? 6 : attempts)))) continue;
        await RelayQueueStore.instance.noteAttempt(id);
        try {
          final packet = jsonDecode(raw);
          final target = packet['recipientId']?.toString() ?? '';
          if (target.isNotEmpty) await transmit(raw, recipientId: target);
        } catch (_) {}
      }
    } finally { _forwarding = false; }
  }
}
