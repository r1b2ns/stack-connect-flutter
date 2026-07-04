import 'dart:convert';
import 'dart:io' show Platform;

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
// See blob_cache.dart: the platform plugin's initialized `databaseFactory` is
// needed on mobile even though `sqflite_ffi` re-exports the same symbols.
// ignore: unnecessary_import
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:stack_core_rust/stack_core_rust.dart';

/// A connected-account record the host owns.
///
/// The Rust core has no notion of "the list of accounts"; it only connects a
/// single account on demand. The host persists which accounts exist, their
/// service [kind] and a user-facing [label]. Secrets live in the secure store,
/// not here (see `SecureCredentialStore`).
class AccountRecord {
  const AccountRecord({
    required this.id,
    required this.kind,
    required this.label,
    this.appsBundles,
  });

  final String id;
  final ServiceKind kind;
  final String label;

  /// Per-account "Apps permissions" allowlist of bundle ids.
  ///
  /// Backward-compat contract (mirrors iOS): `null` **or** empty means the
  /// account is unrestricted — every app is available. Only a non-empty list
  /// restricts visibility to the listed bundle ids. Use [allowsApp] as the
  /// single source of truth for this decision.
  ///
  /// Dormant until the Rust core exposes the field on `AccountExport`; the
  /// `.scexport` import path constructs [AccountRecord] with a null scope, so
  /// no restriction is applied today.
  final List<String>? appsBundles;

  /// Whether [bundleId] is visible under this account's allowlist.
  ///
  /// A null or empty [appsBundles] means "no restriction" (all apps allowed);
  /// a non-empty list allows only the bundle ids it contains.
  bool allowsApp(String bundleId) {
    final b = appsBundles;
    if (b == null || b.isEmpty) return true;
    return b.contains(bundleId);
  }

  @override
  int get hashCode => Object.hash(id, kind, label, _bundlesHash);

  int get _bundlesHash {
    final b = appsBundles;
    if (b == null) return 0;
    return Object.hashAll(b);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AccountRecord &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          kind == other.kind &&
          label == other.label &&
          _bundlesEqual(appsBundles, other.appsBundles);

  /// Value equality for the (nullable) bundle allowlist. List identity is not
  /// enough — two records with the same ids in the same order must compare
  /// equal regardless of instance.
  static bool _bundlesEqual(List<String>? a, List<String>? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return false;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Persists the host-owned list of connected accounts.
abstract interface class AccountsStore {
  /// All connected accounts, in insertion order.
  Future<List<AccountRecord>> all();

  /// Inserts or replaces [account] (keyed by [AccountRecord.id]).
  Future<void> upsert(AccountRecord account);

  /// Removes the account with [id], if present.
  Future<void> remove(String id);
}

/// SQLite-backed [AccountsStore].
///
/// Mirrors [SqliteBlobCache]'s platform handling: FFI on desktop/host/tests,
/// the platform plugin on mobile.
class SqliteAccountsStore implements AccountsStore {
  SqliteAccountsStore._(this._db);

  final Database _db;

  static const _table = 'accounts';

  /// Opens (or creates) the accounts database. Pass [databasePath] (`:memory:`
  /// in tests) to override the location.
  static Future<SqliteAccountsStore> open({String? databasePath}) async {
    final factory = _factoryForPlatform();
    final path = databasePath ?? await _defaultPath();
    final db = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 2,
        onCreate: (db, _) => db.execute('''
          CREATE TABLE $_table (
            id           TEXT PRIMARY KEY,
            kind         TEXT NOT NULL,
            label        TEXT NOT NULL,
            seq          INTEGER,
            apps_bundles TEXT
          )
        '''),
        onUpgrade: (db, oldV, newV) async {
          if (oldV < 2) {
            await db.execute(
              'ALTER TABLE $_table ADD COLUMN apps_bundles TEXT',
            );
          }
        },
      ),
    );
    return SqliteAccountsStore._(db);
  }

  static DatabaseFactory _factoryForPlatform() {
    if (Platform.isAndroid || Platform.isIOS) return databaseFactory;
    sqfliteFfiInit();
    return databaseFactoryFfi;
  }

  static Future<String> _defaultPath() async {
    final dir = await getApplicationDocumentsDirectory();
    return p.join(dir.path, 'accounts.db');
  }

  @override
  Future<List<AccountRecord>> all() async {
    final rows = await _db.query(_table, orderBy: 'seq ASC, rowid ASC');
    return rows
        .map(
          (r) => AccountRecord(
            id: r['id'] as String,
            kind: _kindFromName(r['kind'] as String),
            label: r['label'] as String,
            appsBundles: _decodeBundles(r['apps_bundles'] as String?),
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<void> upsert(AccountRecord account) async {
    await _db.insert(
      _table,
      {
        'id': account.id,
        'kind': account.kind.name,
        'label': account.label,
        'seq': DateTime.now().microsecondsSinceEpoch,
        'apps_bundles':
            account.appsBundles == null ? null : jsonEncode(account.appsBundles),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<void> remove(String id) async {
    await _db.delete(_table, where: 'id = ?', whereArgs: [id]);
  }

  /// Closes the underlying database.
  Future<void> close() => _db.close();

  static ServiceKind _kindFromName(String name) => ServiceKind.values.firstWhere(
        (k) => k.name == name,
        orElse: () => ServiceKind.appStoreConnect,
      );

  /// Decodes the persisted `apps_bundles` JSON column into the allowlist.
  ///
  /// Returns null when the column is null (unrestricted account) or when the
  /// stored value cannot be read as a list of strings (defensive: never crash
  /// on malformed data, treat it as unrestricted).
  static List<String>? _decodeBundles(String? raw) {
    if (raw == null) return null;
    final dynamic decoded = jsonDecode(raw);
    if (decoded is! List) return null;
    return decoded.whereType<String>().toList(growable: false);
  }
}
