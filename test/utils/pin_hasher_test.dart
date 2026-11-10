import 'package:flutter_test/flutter_test.dart';
import 'package:ibiti_guardian/utils/pin_hasher.dart';

void main() {
  group('PinHasher', () {
    test('PBKDF2-HMAC-SHA256 matches the published test vectors', () {
      expect(PinHasher.pbkdf2Hex('password', 'salt', 1),
          '120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b');
      expect(PinHasher.pbkdf2Hex('password', 'salt', 2),
          'ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43');
      expect(PinHasher.pbkdf2Hex('password', 'salt', 4096),
          'c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a');
    });

    test('new hash verifies the right PIN only', () async {
      final stored = await PinHasher.hash('123456', 'salt1');
      expect(PinHasher.isLegacy(stored), isFalse);
      expect(await PinHasher.verify('123456', 'salt1', stored), isTrue);
      expect(await PinHasher.verify('123457', 'salt1', stored), isFalse);
    });

    test('legacy SHA-256 hash still verifies (upgrade path)', () async {
      final legacy = PinHasher.legacyHash('654321', 'abc');
      expect(PinHasher.isLegacy(legacy), isTrue);
      expect(await PinHasher.verify('654321', 'abc', legacy), isTrue);
      expect(await PinHasher.verify('000000', 'abc', legacy), isFalse);
    });
  });
}
