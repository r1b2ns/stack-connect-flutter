import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:stack_core_dart/stack_core_dart.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(sqfliteFfiInit);

  group('AccountRecord.allowsApp', () {
    const base = AccountRecord(
      id: 'a',
      kind: ServiceKind.appStoreConnect,
      label: 'A',
    );

    test('null allowlist => every app is allowed (unrestricted)', () {
      const record = base; // appsBundles defaults to null
      expect(record.appsBundles, isNull);
      expect(record.allowsApp('com.anything'), isTrue);
      expect(record.allowsApp('com.other'), isTrue);
    });

    test('empty allowlist => every app is allowed (unrestricted)', () {
      const record = AccountRecord(
        id: 'a',
        kind: ServiceKind.appStoreConnect,
        label: 'A',
        appsBundles: [],
      );
      expect(record.allowsApp('com.anything'), isTrue);
      expect(record.allowsApp('com.other'), isTrue);
    });

    test('non-empty allowlist => only listed bundle ids are allowed', () {
      const record = AccountRecord(
        id: 'a',
        kind: ServiceKind.appStoreConnect,
        label: 'A',
        appsBundles: ['a'],
      );
      expect(record.allowsApp('a'), isTrue);
      expect(record.allowsApp('b'), isFalse);
      expect(record.allowsApp('com.other'), isFalse);
    });
  });

  group('AccountRecord value equality', () {
    test('records with equal-valued allowlists compare equal', () {
      const one = AccountRecord(
        id: 'a',
        kind: ServiceKind.appStoreConnect,
        label: 'A',
        appsBundles: ['x', 'y'],
      );
      final two = AccountRecord(
        id: 'a',
        kind: ServiceKind.appStoreConnect,
        label: 'A',
        appsBundles: ['x', 'y'].toList(),
      );
      expect(one, equals(two));
      expect(one.hashCode, equals(two.hashCode));
    });

    test('records with differing allowlists are not equal', () {
      const one = AccountRecord(
        id: 'a',
        kind: ServiceKind.appStoreConnect,
        label: 'A',
        appsBundles: ['x'],
      );
      const two = AccountRecord(
        id: 'a',
        kind: ServiceKind.appStoreConnect,
        label: 'A',
        appsBundles: ['x', 'y'],
      );
      expect(one, isNot(equals(two)));
    });

    test('null vs empty allowlist are not equal (distinct persisted state)',
        () {
      const withNull = AccountRecord(
        id: 'a',
        kind: ServiceKind.appStoreConnect,
        label: 'A',
      );
      const withEmpty = AccountRecord(
        id: 'a',
        kind: ServiceKind.appStoreConnect,
        label: 'A',
        appsBundles: [],
      );
      expect(withNull, isNot(equals(withEmpty)));
    });
  });

  group('SqliteAccountsStore round-trip', () {
    late SqliteAccountsStore store;

    setUp(() async {
      store = await SqliteAccountsStore.open(databasePath: inMemoryDatabasePath);
    });

    tearDown(() => store.close());

    test('non-null allowlist round-trips through persistence', () async {
      await store.upsert(
        const AccountRecord(
          id: 'acct-1',
          kind: ServiceKind.appStoreConnect,
          label: 'Acme',
          appsBundles: ['com.a', 'com.b'],
        ),
      );

      final records = await store.all();
      expect(records, hasLength(1));
      expect(records.single.appsBundles, ['com.a', 'com.b']);
      expect(records.single.allowsApp('com.a'), isTrue);
      expect(records.single.allowsApp('com.c'), isFalse);
    });

    test('null allowlist reads back as null (unrestricted)', () async {
      await store.upsert(
        const AccountRecord(
          id: 'acct-2',
          kind: ServiceKind.appStoreConnect,
          label: 'NoScope',
        ),
      );

      final records = await store.all();
      expect(records.single.appsBundles, isNull);
      expect(records.single.allowsApp('anything'), isTrue);
    });

    test('empty allowlist round-trips as empty and stays unrestricted',
        () async {
      await store.upsert(
        const AccountRecord(
          id: 'acct-3',
          kind: ServiceKind.appStoreConnect,
          label: 'EmptyScope',
          appsBundles: [],
        ),
      );

      final records = await store.all();
      expect(records.single.appsBundles, isEmpty);
      expect(records.single.allowsApp('anything'), isTrue);
    });
  });

  group('SqliteAccountsStore v1->v2 migration', () {
    test('upgrading a v1 db adds apps_bundles; old rows read as null-scope',
        () async {
      sqfliteFfiInit();
      final factory = databaseFactoryFfi;

      // Open a v1-schema database (no apps_bundles column) and seed a row.
      final v1 = await factory.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: 1,
          singleInstance: false,
          onCreate: (db, _) => db.execute('''
            CREATE TABLE accounts (
              id    TEXT PRIMARY KEY,
              kind  TEXT NOT NULL,
              label TEXT NOT NULL,
              seq   INTEGER
            )
          '''),
        ),
      );
      await v1.insert('accounts', {
        'id': 'legacy',
        'kind': ServiceKind.appStoreConnect.name,
        'label': 'Legacy',
        'seq': 1,
      });
      final v1Columns =
          await v1.rawQuery('PRAGMA table_info(accounts)');
      expect(
        v1Columns.map((c) => c['name']),
        isNot(contains('apps_bundles')),
      );

      // Run the v1->v2 upgrade the same way SqliteAccountsStore.open does.
      await v1.execute(
        'ALTER TABLE accounts ADD COLUMN apps_bundles TEXT',
      );
      final v2Columns =
          await v1.rawQuery('PRAGMA table_info(accounts)');
      expect(v2Columns.map((c) => c['name']), contains('apps_bundles'));

      final rows = await v1.query('accounts');
      expect(rows.single['apps_bundles'], isNull);
      await v1.close();
    });
  });
}
