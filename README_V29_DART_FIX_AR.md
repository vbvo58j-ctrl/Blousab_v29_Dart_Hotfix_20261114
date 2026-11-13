# إصلاح أخطاء بناء Blousab v29 من صور 2026-11-14

هذه نسخة **تصحيح مصدر** وليست APK تم بناؤه. تمت معالجة أخطاء Dart الظاهرة في الصور المرفقة:

1. `lib/screens/public_feed_screen.dart:378`: استخدام `BlousabTimeText(time: r['createdAt'])` الموجود في المشروع بدلاً من استدعاء `_time` غير الموجود، مع الحفاظ على التنسيق العربي للوقت.
2. `lib/services/chat_inbox_router.dart:259`: استدعاء الدالة الاختيارية بـ `onProgress?.call((index + 1) / total)`.
3. `lib/services/chat_inbox_router.dart:278`: استدعاء الدالة الاختيارية بـ `onProgress?.call(1)`.

## اختبار البناء

على جهاز مثبت به Flutter، في مجلد المشروع شغّل `flutter pub get` ثم `flutter analyze` ثم `flutter build apk --release`، أو `RUN_ACCEPTANCE.ps1` في Windows (يفحص أيضًا البناء Debug).

**تنبيه:** فحوص Python الساكنة لا تثبت نجاح إنشاء APK أو عمل التطبيق على الأجهزة. إذا ظهر خطأ إضافي أرسل السجل الجديد؛ يمكن أن تظهر أخطاء متسلسلة بعد إزالة العوائق الأولى.
