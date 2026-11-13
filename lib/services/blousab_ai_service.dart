import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_mediapipe/flutter_gemma_mediapipe.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// حجم نموذج Blousab AI. الأحجام تقريبية وليست مواصفات نهائية؛ الحجم الفعلي
/// واستهلاك الذاكرة يعتمدان على النموذج وإعدادات التشغيل.
class BlousabAiTier {
  const BlousabAiTier({
    required this.id,
    required this.label,
    required this.approxGb,
    required this.description,
    this.downloadUrl = '',
    this.sha256Hex = '',
  });

  final String id;
  final String label;
  final double approxGb;
  final String description;

  /// رابط ملف النموذج لهذا الحجم. اتركه فارغًا حتى تحدد مصدر النموذج؛
  /// عندها يعرض التطبيق رسالة واضحة بدل أن يبدأ تنزيلًا وهميًا.
  final String downloadUrl;

  /// بصمة SHA-256 المتوقعة للملف (للتحقق من سلامته بعد التنزيل).
  final String sha256Hex;

  int get approxBytes => (approxGb * 1024 * 1024 * 1024).round();
  String get sizeLabel => approxGb < 1 ? '${(approxGb * 1024).round()} MB' : '${approxGb.toStringAsFixed(approxGb == approxGb.roundToDouble() ? 0 : 1)} GB';
}

/// نماذج حقيقية عامة (لا تحتاج حساب Hugging Face) بصيغة MediaPipe .task وتعمل دون إنترنت.
/// المصدر: litert-community على Hugging Face (Qwen2.5 Instruct، ترخيص Apache-2.0).
/// تُتحقق سلامة الملف بمقارنة SHA-256 المحسوب مع البصمة التي يعلنها الخادم نفسه (x-linked-etag).
const List<BlousabAiTier> blousabAiTiers = <BlousabAiTier>[
  BlousabAiTier(
    id: 'light',
    label: 'خفيف',
    approxGb: 0.55,
    description: 'Qwen2.5 0.5B — سريع وخفيف، مناسب لمعظم الهواتف',
    downloadUrl:
        'https://huggingface.co/litert-community/Qwen2.5-0.5B-Instruct/resolve/main/Qwen2.5-0.5B-Instruct_multi-prefill-seq_q8_ekv1280.task',
  ),
  BlousabAiTier(
    id: 'balanced',
    label: 'متوازن',
    approxGb: 1.6,
    description: 'Qwen2.5 1.5B — إجابات أفضل، يحتاج هاتفاً بذاكرة 4 GB أو أكثر',
    downloadUrl:
        'https://huggingface.co/litert-community/Qwen2.5-1.5B-Instruct/resolve/main/Qwen2.5-1.5B-Instruct_multi-prefill-seq_q8_ekv1280.task',
  ),
];

enum BlousabAiStatus { notLoaded, downloading, ready }

class BlousabAiMemoryInfo {
  const BlousabAiMemoryInfo({required this.totalRam, required this.availRam, required this.freeStorage});
  final int totalRam;
  final int availRam;
  final int freeStorage;
}

class BlousabAiCancelled implements Exception {
  @override
  String toString() => 'تم إلغاء التحميل';
}

class BlousabAiService {
  BlousabAiService._();
  static final BlousabAiService instance = BlousabAiService._();

  static const _channel = MethodChannel('com.blousab.messenger/device_info');
  static const _downloadChannel = MethodChannel('com.blousab.messenger/ai_download');
  static const _kDownloadId = 'blousab_ai_download_id_v2';
  static const _kExpectedHash = 'blousab_ai_expected_sha_v2';
  static const _kStatus = 'blousab_ai_status_v1';
  static const _kTier = 'blousab_ai_tier_v1';
  static const _kPath = 'blousab_ai_model_path_v1';

  final ValueNotifier<BlousabAiStatus> status = ValueNotifier<BlousabAiStatus>(BlousabAiStatus.notLoaded);
  final ValueNotifier<double> progress = ValueNotifier<double>(0);
  final ValueNotifier<String> progressText = ValueNotifier<String>('');
  String tierId = '';
  String modelPath = '';

  Timer? _downloadPoll;
  bool _completingDownload = false;
  final ValueNotifier<String> downloadError = ValueNotifier<String>('');
  bool _loadedOnce = false;
  bool _gemmaReady = false;
  bool _activated = false;
  InferenceModel? _model;
  InferenceChat? _chat;

  static const String _systemPrompt =
      'أنت Blousab AI، مساعد ذكاء اصطناعي محلي داخل تطبيق بلوساب يعمل دون إنترنت. '
      'أجب بنفس لغة المستخدم، وبإيجاز ووضوح، وإذا لم تعرف الإجابة فقل ذلك.';

  BlousabAiTier? get currentTier {
    for (final t in blousabAiTiers) {
      if (t.id == tierId) return t;
    }
    return null;
  }

  Future<void> load() async {
    if (_loadedOnce) return;
    _loadedOnce = true;
    final prefs = await SharedPreferences.getInstance();
    tierId = prefs.getString(_kTier) ?? '';
    modelPath = prefs.getString(_kPath) ?? '';
    final pendingId = prefs.getInt(_kDownloadId);
    if (pendingId != null) {
      status.value = BlousabAiStatus.downloading;
      progressText.value = 'جارٍ متابعة التنزيل…';
      _watchDownload(pendingId);
    } else if (prefs.getString(_kStatus) == 'ready' &&
        modelPath.isNotEmpty && await File(modelPath).exists()) {
      status.value = BlousabAiStatus.ready;
    } else {
      status.value = BlousabAiStatus.notLoaded;
      await prefs.setString(_kStatus, 'notLoaded');
    }
  }

  Future<BlousabAiMemoryInfo?> memoryInfo() async {
    try {
      final map = await _channel.invokeMapMethod<String, dynamic>('memoryInfo');
      if (map == null) return null;
      return BlousabAiMemoryInfo(
        totalRam: (map['totalRam'] as num?)?.toInt() ?? 0,
        availRam: (map['availRam'] as num?)?.toInt() ?? 0,
        freeStorage: (map['freeStorage'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return null;
    }
  }

  /// يعيد نصًا تحذيريًا إن كانت الموارد غير كافية، أو null إن كانت كافية.
  Future<({String? warning, bool blocking})> checkResources(BlousabAiTier tier) async {
    final info = await memoryInfo();
    if (info == null) return (warning: null, blocking: false);
    if (info.freeStorage > 0 && info.freeStorage < (tier.approxBytes * 1.15)) {
      return (warning: 'مساحة التخزين الحرة غير كافية لتنزيل النموذج «${tier.label}» (${tier.sizeLabel}).', blocking: true);
    }
    if (info.totalRam > 0 && info.totalRam < tier.approxBytes * 2.5) {
      return (
        warning: 'ذاكرة الجهاز (${(info.totalRam / 1073741824).toStringAsFixed(1)} GB) قد لا تكفي لتشغيل النموذج «${tier.label}» بسلاسة. يُنصح باختيار حجم أصغر.',
        blocking: false,
      );
    }
    return (warning: null, blocking: false);
  }

  Future<File> _targetFile(BlousabAiTier tier) async {
    final dir = await getApplicationSupportDirectory();
    final folder = Directory('${dir.path}/blousab_ai');
    if (!await folder.exists()) await folder.create(recursive: true);
    return File('${folder.path}/${tier.id}.task');
  }

  bool tierHasSource(BlousabAiTier tier) => tier.downloadUrl.trim().isNotEmpty;

  static final RegExp _hex64 = RegExp(r'^[0-9a-fA-F]{64}$');

  /// Android DownloadManager is owned by the OS, not by this Flutter route.
  /// It survives leaving the chat and a normal app process exit, and resumes
  /// eligible HTTP transfers after connectivity returns (server dependent).
  Future<void> downloadAndActivate(BlousabAiTier tier) async {
    await load();
    if (status.value == BlousabAiStatus.downloading) return;
    if (!tierHasSource(tier)) throw StateError('لم يُضبط مصدر تنزيل لهذا الحجم.');
    downloadError.value = '';
    progress.value = 0;
    progressText.value = 'جارٍ تجهيز رابط النموذج…';
    // Require a real integrity checksum: never activate an unverified model.
    final expected = await _expectedChecksum(tier);
    final prefs = await SharedPreferences.getInstance();
    final previous = prefs.getInt(_kDownloadId);
    if (previous != null) return; // a download is already owned by the OS
    final id = await _downloadChannel.invokeMethod<int>('start', {
      'url': tier.downloadUrl,
      'tier': tier.id,
    });
    if (id == null || id <= 0) throw StateError('تعذر بدء التنزيل.');
    tierId = tier.id;
    await prefs.setString(_kTier, tier.id);
    await prefs.setString(_kExpectedHash, expected);
    await prefs.setInt(_kDownloadId, id);
    await prefs.setString(_kStatus, 'downloading');
    status.value = BlousabAiStatus.downloading;
    _watchDownload(id);
  }

  Future<String> _expectedChecksum(BlousabAiTier tier) async {
    if (_hex64.hasMatch(tier.sha256Hex)) return tier.sha256Hex.toLowerCase();
    // Resolve metadata over TLS. This detects corruption, but a pinned hash
    // distributed with the app would additionally protect against compromise
    // of the origin. x-linked-etag is SHA256 for Hugging Face LFS objects.
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 25);
    try {
      var uri = Uri.parse(tier.downloadUrl);
      if (uri.scheme != 'https') throw StateError('يجب أن يكون رابط النموذج HTTPS.');
      for (var hop = 0; hop < 8; hop++) {
        final req = await client.openUrl('HEAD', uri);
        req.followRedirects = false;
        final res = await req.close();
        final hash = (res.headers.value('x-linked-etag') ?? '')
            .replaceAll('"', '').replaceFirst('W/', '').trim();
        final loc = res.headers.value('location');
        await res.drain<void>();
        if (_hex64.hasMatch(hash)) return hash.toLowerCase();
        if (loc == null || !(res.statusCode >= 300 && res.statusCode < 400)) break;
        uri = uri.resolve(loc);
        if (uri.scheme != 'https') throw StateError('تحويل النموذج إلى اتصال غير مشفر ممنوع.');
      }
      throw StateError('لا توجد بصمة SHA-256 موثوقة متاحة لهذا النموذج.');
    } finally { client.close(force: true); }
  }

  void _watchDownload(int id) {
    _downloadPoll?.cancel();
    // Timer remains alive when the AI route is popped; Android manages the
    // actual transfer even when no Dart isolate is running.
    _downloadPoll = Timer.periodic(const Duration(seconds: 1), (_) => _pollDownload(id));
    unawaited(_pollDownload(id));
  }

  Future<void> _pollDownload(int id) async {
    if (_completingDownload) return;
    try {
      final row = await _downloadChannel.invokeMapMethod<String, dynamic>('status', {'id': id});
      if (row == null) return;
      final state = row['state']?.toString() ?? 'pending';
      final downloaded = (row['downloaded'] as num?)?.toInt() ?? 0;
      final size = (row['size'] as num?)?.toInt() ?? -1;
      if (size > 0) progress.value = (downloaded / size).clamp(0, 1).toDouble();
      final amount = '${(downloaded / 1048576).toStringAsFixed(0)} MB';
      progressText.value = switch (state) {
        'paused' => 'بانتظار الاتصال، سيُستأنف تلقائيًا • $amount',
        'pending' => 'في انتظار بدء التنزيل • $amount',
        'running' => size > 0 ? '$amount من ${(size / 1048576).toStringAsFixed(0)} MB' : amount,
        'success' => 'جارٍ التحقق من سلامة النموذج…',
        _ => 'تعذر التنزيل؛ يمكنك المحاولة مجددًا',
      };
      if (state == 'success') {
        _completingDownload = true;
        _downloadPoll?.cancel();
        try { await _finishDownload(id, row['path']?.toString() ?? ''); }
        catch (e) { await _failDownload(id, e.toString()); }
        finally { _completingDownload = false; }
      } else if (state == 'failed' || state == 'missing') {
        await _failDownload(id, 'فشل التنزيل (${row['reason'] ?? state}).');
      }
    } catch (_) {
      // Flutter can be detached while the OS continues the download.
      // Do not delete any partial bytes or mark a transient query failure.
    }
  }

  Future<void> _finishDownload(int id, String sourcePath) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getInt(_kDownloadId) != id || sourcePath.isEmpty) return;
    final tier = currentTier;
    if (tier == null) throw StateError('نوع النموذج غير معروف.');
    final original = File(sourcePath);
    if (!await original.exists()) throw StateError('ملف التنزيل غير موجود.');
    final expected = prefs.getString(_kExpectedHash) ?? '';
    if (!_hex64.hasMatch(expected)) throw StateError('بصمة التحقق غير موجودة.');
    final hash = (await sha256.bind(original.openRead()).first).toString();
    if (hash.toLowerCase() != expected.toLowerCase()) {
      throw StateError('فشل التحقق من SHA-256. الملف غير صالح.');
    }
    final target = await _targetFile(tier);
    final staged = File('${target.path}.verified');
    if (await staged.exists()) await staged.delete();
    // Download a .task directly. Archive extraction is only appropriate when
    // the source really provides a signed/verified .gz archive; zip-wrapping
    // already quantized .task models normally saves little or no bandwidth.
    if (tier.downloadUrl.toLowerCase().endsWith('.gz')) {
      final sink = staged.openWrite();
      try { await sink.addStream(gzip.decoder.bind(original.openRead())); await sink.flush(); }
      finally { await sink.close(); }
    } else {
      await original.copy(staged.path);
    }
    await _closeModel();
    if (await target.exists()) await target.delete();
    await staged.rename(target.path);
    modelPath = target.path;
    // AI replies always render inside the existing Blousab chat UI.
    await _activate();
    await prefs.setString(_kPath, target.path);
    await prefs.setString(_kStatus, 'ready');
    await prefs.remove(_kDownloadId);
    await prefs.remove(_kExpectedHash);
    progress.value = 1;
    progressText.value = 'اكتمل التحقق. النموذج جاهز.';
    status.value = BlousabAiStatus.ready;
    try { await _downloadChannel.invokeMethod('remove', {'id': id}); } catch (_) {}
  }

  Future<void> _failDownload(int id, String reason) async {
    _downloadPoll?.cancel();
    downloadError.value = reason;
    progressText.value = reason;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getInt(_kDownloadId) == id) {
      await prefs.remove(_kDownloadId);
      await prefs.remove(_kExpectedHash);
    }
    await prefs.setString(_kStatus, 'notLoaded');
    status.value = BlousabAiStatus.notLoaded;
    // A checksum failure must never be treated as a ready model.
  }

  Future<void> cancelDownload() async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getInt(_kDownloadId);
    if (id != null) {
      try { await _downloadChannel.invokeMethod('remove', {'id': id}); } catch (_) {}
      await prefs.remove(_kDownloadId);
      await prefs.remove(_kExpectedHash);
    }
    _downloadPoll?.cancel();
    status.value = BlousabAiStatus.notLoaded;
    progress.value = 0;
    progressText.value = 'أُلغي التنزيل بطلبك.';
    await prefs.setString(_kStatus, 'notLoaded');
  }

  // ------------------------------------------------------------ inference
  Future<void> _ensureGemma() async {
    if (_gemmaReady) return;
    await FlutterGemma.initialize(inferenceEngines: const [MediaPipeEngine()]);
    _gemmaReady = true;
  }

  Future<void> _activate() async {
    await _ensureGemma();
    await FlutterGemma.installModel(modelType: ModelType.qwen, fileType: ModelFileType.task)
        .fromFile(modelPath)
        .install();
    _activated = true;
  }

  Future<void> _ensureChat() async {
    if (_chat != null) return;
    if (!_activated) await _activate();
    _model ??= await FlutterGemma.getActiveModel(maxTokens: 1024, preferredBackend: PreferredBackend.cpu);
    _chat = await _model!.createChat(systemInstruction: _systemPrompt);
  }

  /// يبدأ محادثة جديدة (يُنسى السياق السابق داخل النموذج).
  Future<void> resetChat() async {
    try {
      await _chat?.session.close();
    } catch (_) {}
    _chat = null;
  }

  /// يولّد الرد تدريجيًا (كل عنصر في الـ Stream جزء جديد من النص).
  Stream<String> replyStream(String prompt) async* {
    try {
      await _ensureChat();
      await _chat!.addQueryChunk(Message.text(text: prompt, isUser: true));
      await for (final response in _chat!.generateChatResponseAsync()) {
        if (response is TextResponse) yield response.token;
      }
    } catch (e) {
      // سياق ممتلئ أو خطأ في المحرك: نبدأ جلسة جديدة في الرسالة التالية.
      await resetChat();
      rethrow;
    }
  }

  Future<void> _closeModel() async {
    await resetChat();
    try {
      await _model?.close();
    } catch (_) {}
    _model = null;
    _activated = false;
  }

  /// يحذف النموذج الحالي ويعيد المحادثة إلى حالة «غير محمّل».
  Future<void> deleteModel() async {
    await cancelDownload();
    await _closeModel();
    try {
      await FlutterGemma.clearActiveInferenceIdentity();
    } catch (_) {}
    if (modelPath.isNotEmpty) {
      try {
        final f = File(modelPath);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kStatus, 'notLoaded');
    await prefs.remove(_kPath);
    await prefs.remove(_kTier);
    modelPath = '';
    tierId = '';
    status.value = BlousabAiStatus.notLoaded;
  }
}
