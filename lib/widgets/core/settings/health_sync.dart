import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:provider/provider.dart' as provider;
import 'package:wger/l10n/generated/app_localizations.dart';
import 'package:wger/providers/body_weight.dart';
import 'package:wger/providers/health_sync.dart';
import 'package:wger/providers/health_sync_config.dart';
import 'package:wger/providers/user.dart';

class HealthSyncSettingsTile extends ConsumerStatefulWidget {
  const HealthSyncSettingsTile({super.key});

  @override
  ConsumerState<HealthSyncSettingsTile> createState() => _HealthSyncSettingsTileState();
}

class _HealthSyncSettingsTileState extends ConsumerState<HealthSyncSettingsTile> {
  bool? _isAvailable;

  @override
  void initState() {
    super.initState();
    _checkAvailability();
  }

  Future<void> _checkAvailability() async {
    final notifier = ref.read(healthSyncProvider.notifier);
    final available = await notifier.isAvailable();
    if (mounted) {
      setState(() => _isAvailable = available);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Hide entirely if platform check hasn't completed or is unavailable
    if (_isAvailable != true) {
      return const SizedBox.shrink();
    }

    final syncState = ref.watch(healthSyncProvider);
    final i18n = AppLocalizations.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Master toggle
        SwitchListTile(
          title: Text(i18n.healthSync),
          subtitle: Text(i18n.healthSyncDescription),
          value: syncState.isEnabled,
          onChanged: syncState.isSyncing
              ? null
              : (enabled) async {
                  final notifier = ref.read(healthSyncProvider.notifier);
                  if (enabled) {
                    final profile =
                        provider.Provider.of<UserProvider>(context, listen: false).profile;
                    final isMetric = profile?.isMetric ?? true;
                    final count = await notifier.enableSync(isMetric: isMetric);
                    if (context.mounted && count > 0) {
                      await provider.Provider.of<BodyWeightProvider>(context, listen: false)
                          .fetchAndSetEntries();
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(i18n.healthSyncSuccess(count))),
                        );
                      }
                    }
                  } else {
                    await notifier.disableSync();
                  }
                },
        ),

        // Per-type toggles (only visible when sync is enabled)
        if (syncState.isEnabled) ...[
          // Show permissions warning if types are missing
          _MissingPermissionsBanner(),

          const Divider(height: 1, indent: 16, endIndent: 16),
          Padding(
            padding: const EdgeInsets.only(left: 16, top: 8, bottom: 4),
            child: Text(
              'Sync Types',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                  ),
            ),
          ),
          ...allSyncDataTypes.map((type) => _SyncTypeTile(type: type)),
          // Sync now button
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: syncState.isSyncing
                    ? null
                    : () async {
                        final notifier = ref.read(healthSyncProvider.notifier);
                        final profile =
                            provider.Provider.of<UserProvider>(context, listen: false).profile;
                        final isMetric = profile?.isMetric ?? true;
                        final count = await notifier.syncAll(isMetric: isMetric);
                        if (context.mounted && count > 0) {
                          await provider.Provider.of<BodyWeightProvider>(context, listen: false)
                              .fetchAndSetEntries();
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Synced $count entries'),
                              ),
                            );
                          }
                        }
                      },
                icon: syncState.isSyncing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync),
                label: Text(syncState.isSyncing ? 'Syncing...' : 'Sync Now'),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _MissingPermissionsBanner extends ConsumerStatefulWidget {
  @override
  ConsumerState<_MissingPermissionsBanner> createState() =>
      _MissingPermissionsBannerState();
}

class _MissingPermissionsBannerState
    extends ConsumerState<_MissingPermissionsBanner> {
  List<SyncDataType>? _missing;
  bool _isRequesting = false;

  @override
  void initState() {
    super.initState();
    _checkPermissions();
  }

  Future<void> _checkPermissions() async {
    final notifier = ref.read(healthSyncProvider.notifier);
    final missing = await notifier.getMissingPermissions();
    if (mounted) {
      setState(() => _missing = missing);
    }
  }

  Future<void> _requestMissing() async {
    setState(() => _isRequesting = true);
    try {
      final notifier = ref.read(healthSyncProvider.notifier);
      final count = await notifier.requestMissingPermissions(
        isMetric: provider.Provider.of<UserProvider>(context, listen: false)
                .profile
                ?.isMetric ??
            true,
      );
      if (count > 0) {
        await provider.Provider.of<BodyWeightProvider>(context, listen: false)
            .fetchAndSetEntries();
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Synced $count entries')),
          );
        }
      }
      await _checkPermissions();
    } catch (_) {
      // Best effort
    }
    if (mounted) setState(() => _isRequesting = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_missing == null || _missing!.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final errorColor = theme.colorScheme.errorContainer;
    final onError = theme.colorScheme.onErrorContainer;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: errorColor,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.warning_amber_rounded, size: 18, color: onError),
              const SizedBox(width: 8),
              Text(
                'Missing Health Permissions',
                style: theme.textTheme.labelLarge?.copyWith(color: onError),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${_missing!.length} data type(s) need permission.',
            style: theme.textTheme.bodySmall?.copyWith(color: onError),
          ),
          const SizedBox(height: 4),
          Text(
            'Tap "Request Permissions" to re-show the Health prompt.\n'
            'Or go to: Settings → Health → Data Access → wger',
            style: theme.textTheme.bodySmall?.copyWith(
              color: onError.withValues(alpha: 0.8),
              fontSize: 11,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _isRequesting ? null : _requestMissing,
                  icon: _isRequesting
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh, size: 16),
                  label: Text(_isRequesting ? 'Requesting...' : 'Request Permissions'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SyncTypeTile extends ConsumerWidget {
  final SyncDataType type;

  const _SyncTypeTile({required this.type});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final syncState = ref.watch(healthSyncProvider);
    final typeState = syncState.typeStates[type] ?? const SyncTypeState();
    final i18n = AppLocalizations.of(context);

    final directionLabel = switch (typeState.direction) {
      SyncDirection.pull => '→ wger',
      SyncDirection.push => '→ Health',
      SyncDirection.bidirectional => '⇄',
    };

    final subtitle = typeState.enabled
        ? '$directionLabel  ·  ${typeState.lastSyncCount} entries'
        : 'Off';

    return ListTile(
      dense: true,
      leading: Icon(
        _iconForType(type),
        size: 20,
      ),
      title: Text(syncDataTypeDisplayName(type)),
      subtitle: Text(subtitle),
      trailing: Switch(
        value: typeState.enabled,
        onChanged: syncState.isSyncing
            ? null
            : (value) async {
                await ref.read(healthSyncProvider.notifier).updateTypeConfig(
                      type,
                      enabled: value,
                    );
              },
      ),
      onLongPress: syncState.isSyncing
          ? null
          : () => _showDirectionPicker(context, ref, type, typeState),
    );
  }

  IconData _iconForType(SyncDataType type) {
    switch (type) {
      case SyncDataType.weight:
        return Icons.monitor_weight;
      case SyncDataType.bodyFat:
        return Icons.percent;
      case SyncDataType.waist:
        return Icons.straighten;
      case SyncDataType.leanMass:
        return Icons.fitness_center;
      case SyncDataType.workouts:
        return Icons.directions_run;
    }
  }

  Future<void> _showDirectionPicker(
    BuildContext context,
    WidgetRef ref,
    SyncDataType type,
    SyncTypeState current,
  ) async {
    final direction = await showModalBottomSheet<SyncDirection>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                '${syncDataTypeDisplayName(type)} Sync Direction',
                style: Theme.of(ctx).textTheme.titleMedium,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.arrow_downward),
              title: const Text('Pull (Health → wger)'),
              subtitle: const Text('Import data from Apple Health into wger'),
              selected: current.direction == SyncDirection.pull,
              onTap: () => Navigator.pop(ctx, SyncDirection.pull),
            ),
            ListTile(
              leading: const Icon(Icons.arrow_upward),
              title: const Text('Push (wger → Health)'),
              subtitle: const Text('Export wger data to Apple Health'),
              selected: current.direction == SyncDirection.push,
              onTap: () => Navigator.pop(ctx, SyncDirection.push),
            ),
            ListTile(
              leading: const Icon(Icons.swap_vert),
              title: const Text('Bidirectional'),
              subtitle: const Text('Sync both directions'),
              selected: current.direction == SyncDirection.bidirectional,
              onTap: () => Navigator.pop(ctx, SyncDirection.bidirectional),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );

    if (direction != null && direction != current.direction) {
      await ref.read(healthSyncProvider.notifier).updateTypeConfig(
            type,
            direction: direction,
          );
    }
  }
}