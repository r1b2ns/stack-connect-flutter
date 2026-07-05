import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

// Loads the REAL host dylib and crosses the flutter_rust_bridge boundary, the
// same way the app does. This is the one test that would catch an FRB
// encode/decode misalignment in the `.scexport` path (the class of bug behind
// the "RangeError: Value not in range" import crash): a plain `cargo test`
// round-trip stays inside Rust and never exercises the SSE wire between the
// dylib and the generated Dart bindings.
import 'package:stack_core_dart/stack_core_dart.dart';

/// Absolute path to the host (macOS) dylib built with:
///   cargo build -p stack_core --features frb
/// (or `build/build-desktop.sh macos` for the release variant). Same convention
/// as [stack_core_dart_test.dart]; a device/CI matrix that bundles the library
/// would inject this path instead.
const _hostDylibPath =
    '/Users/rubensmachion/repos/Open/stack-connect-core/target/debug/libstack_core.dylib';

void main() {
  setUpAll(() async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(_hostDylibPath),
    );
  });

  tearDownAll(() {
    RustLib.dispose();
  });

  const gateway = FrbCoreGateway();
  const password = 'correct horse battery staple';

  /// Encrypts [account] and decrypts it back through the real FFI, asserting the
  /// round-trip preserves every `AccountExport` field. The decrypt is where the
  /// RangeError struck: a misaligned SSE wire reads a garbage length mid-struct.
  void expectRoundTrip(AccountExport account) {
    final Uint8List bytes =
        gateway.encryptScexport(account: account, password: password);
    expect(bytes.length, greaterThan(37), reason: 'v3 header + ciphertext');

    final decoded =
        gateway.decryptScexport(bytes: bytes, password: password);

    expect(decoded.name, account.name);
    expect(decoded.providerType, account.providerType);
    expect(decoded.appsBundles, account.appsBundles);
    expect(decoded.credentials, account.credentials);
  }

  test('apple export with appsBundles round-trips across the FRB boundary', () {
    expectRoundTrip(
      const AccountExport(
        name: 'Acme Team',
        providerType: 'apple',
        appsBundles: ['com.acme.one', 'com.acme.two'],
        credentials: {
          'issuerId': '69a6de70-1234-47e3-e053-5b8c7c11a4d1',
          'keyId': '2X9R4HXF34',
          'privateKeyP8':
              '-----BEGIN PRIVATE KEY-----\nMIGTAgEAMBM\n-----END PRIVATE KEY-----',
        },
      ),
    );
  });

  test('apple export WITHOUT appsBundles round-trips (None on the wire)', () {
    // The `appsBundles` field is `Option<Vec<String>>`; a null here exercises
    // the opt-list-None branch that a stale 3-field binding would misread.
    expectRoundTrip(
      const AccountExport(
        name: 'No Bundles',
        providerType: 'apple',
        appsBundles: null,
        credentials: {
          'issuerId': 'id',
          'keyId': 'kid',
          'privateKeyP8': 'pem',
        },
      ),
    );
  });

  test('non-apple export passes its credentials through unchanged', () {
    expectRoundTrip(
      const AccountExport(
        name: 'Firebase',
        providerType: 'firebase',
        appsBundles: null,
        credentials: {'serviceAccountJSON': '{"type":"service_account"}'},
      ),
    );
  });

  test('a multibyte-UTF8 name survives the SSE String length encoding', () {
    // SSE encodes String length in BYTES, not chars; a Rust/Dart disagreement
    // on that would desync the wire exactly here.
    expectRoundTrip(
      const AccountExport(
        name: 'Equipe Ação 日本語 🚀',
        providerType: 'apple',
        appsBundles: ['com.example.café'],
        credentials: {
          'issuerId': 'id',
          'keyId': 'kid',
          'privateKeyP8': 'pem',
        },
      ),
    );
  });
}
