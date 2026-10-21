import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/router/app_router.dart';

void main() {
  group('shell destination', () {
    test('maps every top-level route', () {
      expect(shellDestinationFor('/library'), ShellDestination.library);
      expect(shellDestinationFor('/reader/7'), ShellDestination.reader);
      expect(shellDestinationFor('/ai-chat'), ShellDestination.aiChat);
      expect(shellDestinationFor('/search'), ShellDestination.search);
      expect(shellDestinationFor('/settings'), ShellDestination.settings);
      // Unknown / empty locations fall back to the library.
      expect(shellDestinationFor('/'), ShellDestination.library);
      expect(shellDestinationFor(''), ShellDestination.library);
    });

    test('the library is the only destination without a back affordance', () {
      expect(titleBarInfoFor('/library'), (title: '智阅', showBack: false));
      expect(titleBarInfoFor('/reader/1'), (title: '阅读器', showBack: true));
      expect(titleBarInfoFor('/reader/1', bookTitle: '量子计算'),
          (title: '量子计算', showBack: true));
      expect(titleBarInfoFor('/settings'), (title: '设置', showBack: true));
      expect(titleBarInfoFor('/search'), (title: '全文搜索', showBack: true));
      expect(titleBarInfoFor('/ai-chat'), (title: 'AI 对话', showBack: true));
    });

    test('a null / empty book title still keeps the reader back button', () {
      expect(titleBarInfoFor('/reader/9', bookTitle: null).showBack, isTrue);
      expect(titleBarInfoFor('/reader/9', bookTitle: '').showBack, isTrue);
      expect(titleBarInfoFor('/reader/9', bookTitle: '  ').title, '阅读器');
    });
  });
}
