import 'dart:convert';

import '../models/blousab_message.dart';
import 'message_store.dart';
import 'pending_message_store.dart';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Android may deliver direct-reply text in a separate Flutter isolate.
/// Persist it first; the main app connection coordinator sends the outbox
/// when transport is available. This is not instant delivery when offline.
@pragma('vm:entry-point')
Future<void> blousabNotificationReplyBackground(NotificationResponse response) async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService.queueReplyFromResponse(response);
}

/// Local notifications for incoming Blousab messages.
/// Notifications require the app process and its Bluetooth/LAN listener to remain alive.
class NotificationService with WidgetsBindingObserver {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  static String? activeConversationId;
  static bool appInForeground = true;

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  final Set<String> _shownIds = <String>{};
  final Map<String, Set<int>> _messageIdsByConversation = <String, Set<int>>{};
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;
    const android = AndroidInitializationSettings('@android:drawable/sym_def_app_icon');
    const settings = InitializationSettings(android: android);
    await _plugin.initialize(settings,
      onDidReceiveNotificationResponse: (r) async => queueReplyFromResponse(r),
      onDidReceiveBackgroundNotificationResponse: blousabNotificationReplyBackground,
    );
    // Migrate old releases: never keep chat/file alerts in the in-app inbox.
    final prefs = await SharedPreferences.getInstance();
    final old = prefs.getStringList('blousab_notifications_v1') ?? <String>[];
    final other = old.where((row) {
      try { return jsonDecode(row)['type'] == 'share'; } catch (_) { return false; }
    }).toList();
    if (other.length != old.length) await prefs.setStringList('blousab_notifications_v1', other);
    WidgetsBinding.instance.addObserver(this);
    _initialized = true;
  }

  /// The reply action writes to the same durable message/outbox format as
  /// ChatScreen and never adds the reply to the notifications inbox.
  static Future<void> queueReplyFromResponse(NotificationResponse response) async {
    if (response.actionId != 'blousab_inline_reply') return;
    final body = response.input?.trim() ?? '';
    final conversation = response.payload ?? '';
    if (body.isEmpty || body.length > 4000 || !conversation.startsWith('dm_')) return;
    final prefs = await SharedPreferences.getInstance();
    final me = prefs.getString('wasl_user_id') ?? '';
    if (me.isEmpty || me.length > 256) return;
    final suffix = conversation.substring(3);
    final first = '${me}_';
    final last = '_$me';
    final peer = suffix.startsWith(first) ? suffix.substring(first.length)
        : suffix.endsWith(last) ? suffix.substring(0, suffix.length - last.length) : '';
    if (peer.isEmpty || peer == me || peer.length > 256) return;
    final pair = <String>[me, peer]..sort();
    if (conversation != 'dm_${pair[0]}_${pair[1]}') return;
    final now = DateTime.now();
    final id = '${now.microsecondsSinceEpoch}_${me}_reply';
    final senderName = prefs.getString('wasl_user_name') ?? 'مستخدم بلوساب';
    final message = BlousabMessage(id: id, conversationId: conversation,
      senderId: me, senderName: senderName, text: body,
      sentAt: now, isMine: true, deliveryStatus: 'pending');
    final raw = jsonEncode({
      'type': 'chat', 'id': id, 'conversationId': conversation,
      'senderId': me, 'senderName': senderName, 'recipientId': peer,
      'text': body, 'sentAt': now.toIso8601String(),
      'createdAt': now.toUtc().toIso8601String(),
      'relayEnabled': true, 'relayPath': <String>[], 'hopCount': 0,
    });
    await MessageStore().saveMessage(message);
    await PendingMessageStore.instance.enqueue({
      'messageId': id, 'conversationId': conversation,
      'payload': raw, 'wifiMode': prefs.getString('blousab_connection_mode') == 'wifi',
      'isCommunity': false, 'bluetoothAddress': null, 'wifiAddress': null,
    });
  }

  Future<void> requestPermission() async {
    if (!_initialized) await initialize();
    final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await android?.requestNotificationsPermission();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    appInForeground = state == AppLifecycleState.resumed;
  }

  Future<void> clearConversation(String conversationId) async {
    if (!_initialized) return;
    // Only dismiss THIS chat's Android alerts; preserve other conversations
    // and unrelated app notifications.
    final prefs = await SharedPreferences.getInstance();
    final key = 'blousab_system_alert_ids_$conversationId';
    final ids = <int>{
      ...(_messageIdsByConversation.remove(conversationId) ?? <int>{}),
      for (final raw in prefs.getStringList(key) ?? <String>[])
        if (int.tryParse(raw) != null) int.parse(raw),
    };
    for (final id in ids) { await _plugin.cancel(id); }
    await prefs.remove(key);
  }

  Future<void> handleIncomingPayload(String raw, {required String currentUserId}) async {
    try {
      final dynamic value = jsonDecode(raw);
      if (value is! Map) return;
      final type = value['type']?.toString() ?? '';
      if (type == 'profile_card' || type == 'profile_update' || type == 'hello' || type == 'hello_ack') return;
      if (type != 'chat' && type != 'file' && type != 'text') return;
      final recipientId = value['recipientId']?.toString() ?? '';
      if (recipientId != currentUserId && recipientId != '*') return;
      final senderId = value['senderId']?.toString() ?? '';
      if (senderId.isEmpty || senderId == currentUserId) return;
      final conversationId = value['conversationId']?.toString() ?? '';
      if (appInForeground && activeConversationId != null && activeConversationId == conversationId) return;
      final id = value['id']?.toString() ?? '${senderId}_${value['sentAt']}_${value['text']}';
      if (!_shownIds.add(id)) return;
      if (_shownIds.length > 500) _shownIds.remove(_shownIds.first);
      bool notificationsEnabled = true;
      try {
        final enabledPrefs = await SharedPreferences.getInstance();
        notificationsEnabled = enabledPrefs.getBool('blousab_notifications_enabled') ?? true;
      } catch (_) {}
      // Chat messages must NEVER enter the permanent in-app notifications
      // inbox. Only transient Android system notifications are generated.
      final senderName = value['senderName']?.toString().trim();
      final title = (senderName == null || senderName.isEmpty) ? 'رسالة جديدة' : senderName;
      final body = type == 'file' ? '📎 أرسل ملفًا' : (value['text']?.toString() ?? 'رسالة جديدة');
      final notificationId = id.hashCode & 0x7fffffff;
      if (!notificationsEnabled) return;
      _messageIdsByConversation.putIfAbsent(conversationId, () => <int>{}).add(notificationId);
      // Persist only Android alert IDs, NEVER message content or inbox records.
      final prefs = await SharedPreferences.getInstance();
      final key = 'blousab_system_alert_ids_$conversationId';
      final oldIds = prefs.getStringList(key) ?? <String>[];
      oldIds.add(notificationId.toString());
      await prefs.setStringList(key, oldIds.length > 100 ? oldIds.sublist(oldIds.length - 100) : oldIds);
      await _plugin.show(
        notificationId,
        title,
        body.isEmpty ? 'رسالة جديدة' : body,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'blousab_messages',
            'رسائل بلوساب',
            channelDescription: 'إشعارات الرسائل الجديدة في بلوساب',
            importance: Importance.max,
            priority: Priority.high,
            category: AndroidNotificationCategory.message,
            actions: <AndroidNotificationAction>[
              AndroidNotificationAction('blousab_inline_reply', 'رد',
                inputs: <AndroidNotificationActionInput>[
                  AndroidNotificationActionInput(label: 'اكتب ردك'),
                ],
                showsUserInterface: false,
                allowGeneratedReplies: true,
              ),
            ],
            icon: '@android:drawable/sym_def_app_icon',
          ),
        ),
        payload: conversationId,
      );
    } catch (_) {
      // A malformed packet should never interrupt message reception.
    }
  }
}
