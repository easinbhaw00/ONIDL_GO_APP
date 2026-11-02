import 'package:flutter_test/flutter_test.dart';
import 'package:onidl_go/main.dart';

void main() {
  group('ONIDL Go search result model', () {
    test('keeps source, license page and download URL separate', () {
      const item = FreeSearchItem(
        title: 'Public domain sample',
        url: 'https://example.org/file.mp4',
        source: 'Internet Archive',
        details: 'Public domain item',
        detailsUrl: 'https://archive.org/details/example',
        size: 1024,
      );

      expect(item.title, 'Public domain sample');
      expect(item.url, startsWith('https://'));
      expect(item.detailsUrl, contains('/details/'));
      expect(item.size, 1024);
    });
  });
}
