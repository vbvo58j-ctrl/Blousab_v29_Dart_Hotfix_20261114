"""Fast source-level guards for the three Flutter build errors reported in v29.
These checks do not replace flutter analyze or an Android APK build.
"""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
router = (root / 'lib/services/chat_inbox_router.dart').read_text(encoding='utf-8')
feed = (root / 'lib/screens/public_feed_screen.dart').read_text(encoding='utf-8')
clock = (root / 'lib/widgets/blousab_time.dart').read_text(encoding='utf-8')
checks = {
    'PROGRESS_CALLBACK_NULL_SAFE_CALLS': (
        'onProgress?.call((index + 1) / total);' in router
        and 'onProgress?.call(1);' in router
        and re.search(r'onProgress\?\.\s*\(', router) is None
    ),
    'FRIEND_REQUEST_TIME_WIDGET': (
        "subtitle: BlousabTimeText(time: r['createdAt'])" in feed
        and "import '../widgets/blousab_time.dart';" in feed
        and 'class BlousabTimeText' in clock
        and re.search(r'\b_time\s*\(', feed) is None
    ),
}
for label, ok in checks.items():
    print(('PASS' if ok else 'FAIL') + ': ' + label)
print('NOTE: Source guards only. A real Flutter analyze/build is still required.')
sys.exit(0 if all(checks.values()) else 1)
