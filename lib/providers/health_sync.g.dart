// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'health_sync.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(HealthSyncNotifier)
final healthSyncProvider = HealthSyncNotifierProvider._();

final class HealthSyncNotifierProvider
    extends $NotifierProvider<HealthSyncNotifier, HealthSyncState> {
  HealthSyncNotifierProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'healthSyncProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$healthSyncNotifierHash();

  @$internal
  @override
  HealthSyncNotifier create() => HealthSyncNotifier();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(HealthSyncState value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<HealthSyncState>(value),
    );
  }
}

String _$healthSyncNotifierHash() =>
    r'3d1741857ee5d3eff724056e8b4ec70c4ea1e82e';

abstract class _$HealthSyncNotifier extends $Notifier<HealthSyncState> {
  HealthSyncState build();
  @$mustCallSuper
  @override
  void runBuild() {
    final ref = this.ref as $Ref<HealthSyncState, HealthSyncState>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<HealthSyncState, HealthSyncState>,
              HealthSyncState,
              Object?,
              Object?
            >;
    element.handleCreate(ref, build);
  }
}
