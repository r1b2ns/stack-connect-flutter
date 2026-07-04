import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../gateway/core_gateway.dart';
import 'package:stack_core_rust/stack_core_rust.dart';
import '../stores/accounts_store.dart';
import '../stores/blob_cache.dart';
import '../stores/store_providers.dart';
import 'connected_provider.dart';

/// The [BlobCache] `typeName` the core persists apps under.
///
/// Must match the Rust core's `BLOB_TYPE_APP` (`"app"`): apps are keyed by the
/// bare app id, with JSON `{id,name,bundleId,platform,accountId}`.
const String kAppBlobType = 'app';

/// Apps for a single account, offline-first.
///
/// `build` returns the apps cached in [blobCacheProvider] immediately (offline
/// read), then triggers a background sync that refreshes from the live provider
/// and re-emits. The UI therefore paints from cache without waiting on the
/// network, and updates once the refresh lands.
///
/// Because the core keys app blobs by the bare app id (not a composite), the
/// cache is shared across accounts; reads here filter by the `accountId` field
/// carried in each blob.
class AppsController extends FamilyAsyncNotifier<List<AppInfo>, String> {
  @override
  Future<List<AppInfo>> build(String accountId) async {
    final cached = await _readCache(accountId);
    // Refresh in the background; cached is emitted first, refreshed second.
    // ignore: discarded_futures
    Future.microtask(() => _refresh(accountId, emitLoading: false));
    return cached;
  }

  /// Forces a re-sync from the live provider, re-emitting on completion.
  Future<void> refresh() => _refresh(arg, emitLoading: true);

  /// Reads the cached apps for [accountId] from the blob cache.
  Future<List<AppInfo>> _readCache(String accountId) async {
    final cache = ref.read(blobCacheProvider);
    final blobs = await cache.fetchAll(kAppBlobType);
    final apps = <AppInfo>[];
    for (final blob in blobs) {
      final app = _decodeAppBlob(blob.json);
      if (app == null) continue;
      if (app.accountId != accountId) continue;
      apps.add(app.info);
    }
    return _applyAppsPermissions(accountId, apps);
  }

  /// Filters [apps] down to those the owning account's "Apps permissions"
  /// allowlist permits.
  ///
  /// Backward-compat contract (mirrors iOS): a null or empty allowlist means
  /// unrestricted, so all apps pass. If no account record is found for
  /// [accountId], the account is treated as unrestricted. Dormant until the
  /// core populates [AccountRecord.appsBundles].
  Future<List<AppInfo>> _applyAppsPermissions(
    String accountId,
    List<AppInfo> apps,
  ) async {
    final records = await ref.read(accountsStoreProvider).all();
    AccountRecord? record;
    for (final r in records) {
      if (r.id == accountId) {
        record = r;
        break;
      }
    }
    if (record == null) return apps;
    final owner = record;
    return apps
        .where((app) => owner.allowsApp(app.bundleId))
        .toList(growable: false);
  }

  /// Syncs via the connected provider, persisting each blob to the cache, then
  /// re-emits the refreshed apps. Sync failures surface as [AsyncError].
  Future<void> _refresh(String accountId, {required bool emitLoading}) async {
    if (emitLoading) state = const AsyncValue.loading();
    state = await AsyncValue.guard(() async {
      final gateway = ref.read(coreGatewayProvider);
      final cache = ref.read(blobCacheProvider);
      final provider =
          await ref.read(connectedProviderProvider(accountId).future);
      final service = gateway.makeSyncService(provider, accountId);
      final fetched = await gateway.syncApps(
        service,
        persist: (typeName, id, json) => cache.save(typeName, id, json),
      );
      // The shared blob cache still persists every fetched blob (the persist
      // callback above ran for all of them); scoping is applied per-account
      // on emit so a restricted account never surfaces apps it can't see.
      return _applyAppsPermissions(accountId, fetched);
    });
  }
}

/// The apps controller the UI slice consumes, keyed by `accountId`.
final appsControllerProvider = AsyncNotifierProvider.family<AppsController,
    List<AppInfo>, String>(AppsController.new);

/// An app blob decoded from the cache: the [AppInfo] plus its owning account.
class _CachedApp {
  const _CachedApp({required this.info, required this.accountId});

  final AppInfo info;
  final String accountId;
}

_CachedApp? _decodeAppBlob(String json) {
  final dynamic raw = jsonDecode(json);
  if (raw is! Map<String, dynamic>) return null;
  final id = raw['id'];
  final name = raw['name'];
  final bundleId = raw['bundleId'];
  final accountId = raw['accountId'];
  if (id is! String || name is! String || bundleId is! String) return null;
  if (accountId is! String) return null;
  final platform = raw['platform'];
  return _CachedApp(
    info: AppInfo(
      id: id,
      name: name,
      bundleId: bundleId,
      platform: platform is String ? platform : null,
    ),
    accountId: accountId,
  );
}
