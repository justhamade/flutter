/*
 * This file is part of wger Workout Manager <https://github.com/wger-project>.
 * Copyright (c) 2026 wger Team
 *
 * wger Workout Manager is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

import 'dart:io';

import 'package:health/health.dart';
import 'package:logging/logging.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:wger/helpers/shared_preferences.dart';
import 'package:wger/models/body_weight/weight_entry.dart';
import 'package:wger/models/measurements/measurement_entry.dart';
import 'package:wger/providers/base_provider.dart';
import 'package:wger/providers/health_sync_config.dart';
import 'package:wger/providers/health_sync_workout.dart';
import 'package:wger/providers/wger_base_riverpod.dart';

part 'health_sync.g.dart';

/// Overall state of the health sync system.
///
/// Holds both the master enabled toggle and per-data-type states
/// so the UI can show granular status for each sync type.
class HealthSyncState {
  final bool isEnabled;
  final bool isSyncing;
  final bool pushInProgress;
  final int lastSyncCount;

  /// Per-data-type state map, keyed by [SyncDataType].
  /// Built from persisted prefs on startup.
  final Map<SyncDataType, SyncTypeState> typeStates;

  const HealthSyncState({
    this.isEnabled = false,
    this.isSyncing = false,
    this.pushInProgress = false,
    this.lastSyncCount = 0,
    this.typeStates = const {},
  });

  HealthSyncState copyWith({
    bool? isEnabled,
    bool? isSyncing,
    bool? pushInProgress,
    int? lastSyncCount,
    Map<SyncDataType, SyncTypeState>? typeStates,
  }) {
    return HealthSyncState(
      isEnabled: isEnabled ?? this.isEnabled,
      isSyncing: isSyncing ?? this.isSyncing,
      pushInProgress: pushInProgress ?? this.pushInProgress,
      lastSyncCount: lastSyncCount ?? this.lastSyncCount,
      typeStates: typeStates ?? this.typeStates,
    );
  }
}

const double kgToLb = 2.20462;

/// All health data types we request permissions for.
///
/// Order follows Apple's recommended grouping — weight/body comp first,
/// then workout/activity data.
List<HealthDataType> get _allRequestedDataTypes => [
      HealthDataType.WEIGHT,
      HealthDataType.BODY_FAT_PERCENTAGE,
      HealthDataType.WAIST_CIRCUMFERENCE,
      HealthDataType.LEAN_BODY_MASS,
      HealthDataType.WORKOUT,
    ];

/// Data types we want WRITE access to (push direction).
List<HealthDataType> get _allWriteDataTypes => [
      HealthDataType.WEIGHT,
      HealthDataType.BODY_FAT_PERCENTAGE,
      HealthDataType.WAIST_CIRCUMFERENCE,
    ];

@Riverpod(keepAlive: true)
class HealthSyncNotifier extends _$HealthSyncNotifier {
  final _logger = Logger('HealthSyncNotifier');
  late final Health _health;
  late final WgerBaseProvider _baseProvider;
  late final WorkoutSyncService _workoutSync;

  static const _weightEntryUrl = 'weightentry';
  static const _measurementUrl = 'measurement';

  @override
  HealthSyncState build() {
    _health = Health();
    _baseProvider = ref.read(wgerBaseProvider);
    _workoutSync = WorkoutSyncService(_health, _baseProvider);

    // Load persisted sync preference on startup
    _loadPersistedState();

    return const HealthSyncState();
  }

  Future<void> _loadPersistedState() async {
    final enabled = await PreferenceHelper.instance.getHealthSyncEnabled();
    if (enabled) {
      // Load per-type states
      final typeStates = <SyncDataType, SyncTypeState>{};
      for (final type in allSyncDataTypes) {
        typeStates[type] = await loadTypeState(type);
      }
      state = state.copyWith(isEnabled: true, typeStates: typeStates);
    }
  }

  /// Check if the health platform is available on this device.
  Future<bool> isAvailable() async {
    if (Platform.isAndroid) {
      await _health.configure();
      final status = await _health.getHealthConnectSdkStatus();
      return status == HealthConnectSdkStatus.sdkAvailable;
    }
    // iOS always has HealthKit available
    return Platform.isIOS;
  }

  // ───────── Enable / Disable ─────────

  /// Enable health sync: request permissions for all types,
  /// save preference, trigger initial sync.
  Future<int> enableSync({bool isMetric = true}) async {
    _logger.info('Enabling health sync');

    await _health.configure();

    // Determine which READ types are needed based on enabled types + direction
    final readTypes = <HealthDataType>[];
    final writeTypes = <HealthDataType>[];
    for (final type in allSyncDataTypes) {
      final typeState = state.typeStates[type] ?? const SyncTypeState();
      if (!typeState.enabled) continue;

      switch (typeState.direction) {
        case SyncDirection.pull:
          readTypes.add(_healthTypeFor(type));
        case SyncDirection.push:
          writeTypes.add(_healthTypeFor(type));
        case SyncDirection.bidirectional:
          readTypes.add(_healthTypeFor(type));
          writeTypes.add(_healthTypeFor(type));
      }
    }

    // Always include weight READ (legacy default)
    if (!readTypes.contains(HealthDataType.WEIGHT)) {
      readTypes.add(HealthDataType.WEIGHT);
    }

    // Request READ permissions
    if (readTypes.isNotEmpty) {
      final authorized = await _health.requestAuthorization(
        readTypes,
        permissions: [HealthDataAccess.READ],
      );
      if (!authorized) {
        _logger.warning('Health READ permissions not granted');
        return 0;
      }
    }

    // Request WRITE permissions
    if (writeTypes.isNotEmpty) {
      final writeAuthorized = await _health.requestAuthorization(
        writeTypes,
        permissions: [HealthDataAccess.WRITE],
      );
      if (!writeAuthorized) {
        _logger.warning('Health WRITE permissions not granted');
        // Continue anyway — partial permissions are OK
      }
    }

    // Request access to historical data (older than 30 days) on Android
    if (Platform.isAndroid) {
      await _health.requestHealthDataHistoryAuthorization();
    }

    await PreferenceHelper.instance.setHealthSyncEnabled(true);
    state = state.copyWith(isEnabled: true);

    return syncAll(isMetric: isMetric);
  }

  /// Disable health sync: clear all preferences.
  Future<void> disableSync() async {
    _logger.info('Disabling health sync');
    await PreferenceHelper.instance.clearHealthSyncPreferences();
    state = const HealthSyncState();
  }

  // ───────── Orchestrator ─────────

  /// Sync ALL enabled data types in the configured direction.
  ///
  /// Calls type-specific sync methods, aggregates results.
  /// If [isMetric] is false, converts kg values to lb.
  Future<int> syncAll({bool isMetric = true}) async {
    if (state.isSyncing) return 0;
    state = state.copyWith(isEnabled: true, isSyncing: true);

    int totalCount = 0;
    try {
      for (final type in allSyncDataTypes) {
        final typeState = state.typeStates[type] ?? const SyncTypeState();
        if (!typeState.enabled) continue;

        switch (type) {
          case SyncDataType.weight:
            totalCount += await _syncWeightPull(isMetric: isMetric);
            if (typeState.direction == SyncDirection.push ||
                typeState.direction == SyncDirection.bidirectional) {
              totalCount += await _syncWeightPush();
            }
case SyncDataType.bodyFat:
              totalCount += await _syncMeasurementPull(
                SyncDataType.bodyFat,
                HealthDataType.BODY_FAT_PERCENTAGE,
                isMetric: false,
              );
              if (typeState.direction == SyncDirection.push ||
                  typeState.direction == SyncDirection.bidirectional) {
                totalCount += await _syncMeasurementPush(
                  SyncDataType.bodyFat,
                  HealthDataType.BODY_FAT_PERCENTAGE,
                );
              }
            case SyncDataType.waist:
              totalCount += await _syncMeasurementPull(
                SyncDataType.waist,
                HealthDataType.WAIST_CIRCUMFERENCE,
                isMetric: isMetric,
              );
              if (typeState.direction == SyncDirection.push ||
                  typeState.direction == SyncDirection.bidirectional) {
                totalCount += await _syncMeasurementPush(
                  SyncDataType.waist,
                  HealthDataType.WAIST_CIRCUMFERENCE,
                );
              }
            case SyncDataType.leanMass:
              totalCount += await _syncMeasurementPull(
                SyncDataType.leanMass,
                HealthDataType.LEAN_BODY_MASS,
                isMetric: isMetric,
              );
              if (typeState.direction == SyncDirection.push ||
                  typeState.direction == SyncDirection.bidirectional) {
                totalCount += await _syncMeasurementPush(
                  SyncDataType.leanMass,
                  HealthDataType.LEAN_BODY_MASS,
                );
              }
          case SyncDataType.workouts:
              if (typeState.direction == SyncDirection.pull ||
                  typeState.direction == SyncDirection.bidirectional) {
                totalCount += await _workoutSync.pullWorkouts(isMetric: isMetric);
              }
              if (typeState.direction == SyncDirection.push ||
                  typeState.direction == SyncDirection.bidirectional) {
                totalCount += await _workoutSync.pushWorkouts();
              }
        }
      }
    } catch (e) {
      _logger.warning('Health sync orchestrator failed: $e');
    }

    state = state.copyWith(isSyncing: false, lastSyncCount: totalCount);
    return totalCount;
  }

  // ───────── Weight Pull (Apple Health → wger) ─────────

  Future<int> _syncWeightPull({List<WeightEntry>? existingEntries, bool isMetric = true}) async {
    final prefs = PreferenceHelper.instance;
    final lastSyncStr = await prefs.getLastHealthSyncTimestamp();
    final startTime = lastSyncStr != null ? DateTime.parse(lastSyncStr) : DateTime(2000);
    final endTime = DateTime.now();

    _logger.info('Syncing weight data from $startTime to $endTime');

    List<HealthDataPoint> dataPoints;
    try {
      dataPoints = await _health.getHealthDataFromTypes(
        types: [HealthDataType.WEIGHT],
        startTime: startTime,
        endTime: endTime,
      );
    } catch (e) {
      _logger.warning('Failed to read weight data from health platform: $e');
      return 0;
    }
    dataPoints = _health.removeDuplicates(dataPoints);

    if (dataPoints.isEmpty) {
      _logger.info('No new weight data from health platform');
      return 0;
    }

    _logger.info('Found ${dataPoints.length} weight data points');

    // Build dedup set from existing entries
    final existingTimestamps = existingEntries != null
        ? {
            for (final e in existingEntries)
              DateTime(e.date.year, e.date.month, e.date.day, e.date.hour, e.date.minute),
          }
        : <DateTime>{};

    int syncedCount = 0;
    DateTime? latestSynced;

    for (final point in dataPoints) {
      try {
        final value = (point.value as NumericHealthValue).numericValue;
        final weightKg = value.toDouble();
        final timestamp = point.dateFrom;

        final weight = isMetric ? weightKg : weightKg * kgToLb;
        final weightRounded = (weight * 100).roundToDouble() / 100;

        final normalizedTimestamp = DateTime(
          timestamp.year,
          timestamp.month,
          timestamp.day,
          timestamp.hour,
          timestamp.minute,
        );
        if (existingTimestamps.contains(normalizedTimestamp)) {
          _logger.fine('Skipping duplicate weight entry for $timestamp');
          continue;
        }

        final entry = WeightEntry(weight: weightRounded, date: timestamp);
        await _baseProvider.post(
          entry.toJson(),
          _baseProvider.makeUrl(_weightEntryUrl),
        );

        syncedCount++;
        if (latestSynced == null || timestamp.isAfter(latestSynced)) {
          latestSynced = timestamp;
        }
      } catch (e) {
        _logger.warning('Failed to sync weight entry: $e');
      }
    }

    if (latestSynced != null) {
      await prefs.setLastHealthSyncTimestamp(latestSynced.toIso8601String());
      // Also update per-type timestamp
      await prefs.setTypeLastSyncTimestamp(
        syncDataTypeToPrefKey(SyncDataType.weight),
        latestSynced.toIso8601String(),
      );
    }

    _logger.info('Synced $syncedCount weight entries');
    // Update type state
    _updateTypeState(SyncDataType.weight, syncedCount: syncedCount);
    return syncedCount;
  }

  // ───────── Weight Push (wger → Apple Health) ─────────

  /// Push all new wger weight entries to Apple Health.
  ///
  /// Reads entries from the wger backend that haven't been pushed yet
  /// (tracked via a set of pushed entry IDs in SharedPreferences) and
  /// writes them to Apple Health Kit via the `health` package.
  Future<int> _syncWeightPush() async {
    if (!Platform.isIOS) {
      _logger.info('Weight push only supported on iOS');
      return 0;
    }

    final prefs = PreferenceHelper.instance;
    final enabled = await prefs.getHealthSyncEnabled();
    if (!enabled) return 0;

    // Ensure WRITE permission
    final hasPerms = await _health.hasPermissions(
      [HealthDataType.WEIGHT],
      permissions: [HealthDataAccess.WRITE],
    );
    if (hasPerms != true) {
      _logger.warning('No WRITE permission for weight — skipping push');
      return 0;
    }

    // Load set of already-pushed entry IDs
    final pushedIdsStr = await prefs.getTypeLastSyncTimestamp('weight_pushed_ids');
    final pushedIds = pushedIdsStr != null
        ? pushedIdsStr.split(',').where((s) => s.isNotEmpty).map(int.parse).toSet()
        : <int>{};

    _logger.info('Pushing weight entries to Apple Health (${pushedIds.length} already pushed)');

    int pushCount = 0;
    try {
      // Fetch all existing weight entries from wger
      final data = await _baseProvider.fetchPaginated(
        _baseProvider.makeUrl(
          _weightEntryUrl,
          query: {'ordering': '-date', 'limit': '200'},
        ),
      );

      for (final entryJson in data) {
        final entry = WeightEntry.fromJson(entryJson);
        if (entry.id == null || pushedIds.contains(entry.id!)) continue;

        final weightKg = entry.weight.toDouble();
        final timestamp = entry.date;
        final endTime = timestamp.add(const Duration(seconds: 1));

        try {
          await _health.writeHealthData(
            value: weightKg,
            type: HealthDataType.WEIGHT,
            startTime: timestamp,
            endTime: endTime,
          );
          pushedIds.add(entry.id!);
          pushCount++;
        } catch (e) {
          _logger.warning('Failed to push weight entry ${entry.id}: $e');
        }
      }

      // Persist pushed IDs
      await prefs.setTypeLastSyncTimestamp(
        'weight_pushed_ids',
        pushedIds.join(','),
      );

      _logger.info('Pushed $pushCount weight entries to Apple Health');
    } catch (e) {
      _logger.warning('Weight push failed: $e');
    }

    return pushCount;
  }

  /// Push a single weight entry to Apple Health immediately (write-through).
  ///
  /// Called after the user saves a new weight entry in the app.
  /// Safe to call even if sync is disabled — checks internally.
  Future<bool> pushWeightEntryToHealth(WeightEntry entry) async {
    if (!Platform.isIOS || entry.id == null) return false;

    try {
      // Check if health sync is enabled
      final prefs = PreferenceHelper.instance;
      final enabled = await prefs.getHealthSyncEnabled();
      if (!enabled) return false;

      // Check direction allows push
      final typeState = state.typeStates[SyncDataType.weight] ?? const SyncTypeState();
      if (typeState.direction == SyncDirection.pull) return false;

      // Ensure WRITE permission
      final hasPerms = await _health.hasPermissions(
        [HealthDataType.WEIGHT],
        permissions: [HealthDataAccess.WRITE],
      );
      if (hasPerms != true) return false;

      final weightKg = entry.weight.toDouble();
      final timestamp = entry.date;
      final endTime = timestamp.add(const Duration(seconds: 1));

      await _health.writeHealthData(
        value: weightKg,
        type: HealthDataType.WEIGHT,
        startTime: timestamp,
        endTime: endTime,
      );

      // Track as pushed
      final pushedStr = await prefs.getTypeLastSyncTimestamp('weight_pushed_ids');
      final pushedIds = pushedStr != null
          ? pushedStr.split(',').where((s) => s.isNotEmpty).map(int.parse).toSet()
          : <int>{};
      pushedIds.add(entry.id!);
      await prefs.setTypeLastSyncTimestamp('weight_pushed_ids', pushedIds.join(','));

      _logger.info('Pushed weight entry ${entry.id} to Apple Health (write-through)');
      return true;
    } catch (e) {
      _logger.warning('Write-through weight push failed: $e');
      return false;
    }
  }

  // ───────── Body Measurement Pull (Apple Health → wger) ─────────

  Future<int> _syncMeasurementPull(
    SyncDataType syncType,
    HealthDataType healthType, {
    bool isMetric = true,
  }) async {
    final prefs = PreferenceHelper.instance;
    final typeKey = syncDataTypeToPrefKey(syncType);
    final lastSyncStr = await prefs.getTypeLastSyncTimestamp(typeKey);
    final startTime = lastSyncStr != null ? DateTime.parse(lastSyncStr) : DateTime(2000);
    final endTime = DateTime.now();

    _logger.info('Syncing ${syncDataTypeDisplayName(syncType)} from $startTime to $endTime');

    // Check READ permission
    final hasPerms = await _health.hasPermissions(
      [healthType],
      permissions: [HealthDataAccess.READ],
    );
    if (hasPerms != true) {
      _logger.warning('No READ permission for $healthType — skipping');
      return 0;
    }

    List<HealthDataPoint> dataPoints;
    try {
      dataPoints = await _health.getHealthDataFromTypes(
        types: [healthType],
        startTime: startTime,
        endTime: endTime,
      );
    } catch (e) {
      _logger.warning('Failed to read $healthType: $e');
      return 0;
    }
    dataPoints = _health.removeDuplicates(dataPoints);

    if (dataPoints.isEmpty) {
      _logger.info('No new ${syncDataTypeDisplayName(syncType)} data from health platform');
      return 0;
    }

    _logger.info('Found ${dataPoints.length} ${syncDataTypeDisplayName(syncType)} data points');

    // Get the wger measurement category ID
    final categoryId = syncDataTypeToMeasurementCategory(syncType);

    int syncedCount = 0;
    DateTime? latestSynced;

    for (final point in dataPoints) {
      try {
        final value = (point.value as NumericHealthValue).numericValue.toDouble();
        final timestamp = point.dateFrom;

        // Unit conversion if applicable
        final displayValue = isMetric ? value : value * kgToLb;
        final valueRounded = (displayValue * 100).roundToDouble() / 100;

        if (categoryId != null) {
          // POST to measurement endpoint with known category
          final body = {
            'category': categoryId,
            'value': valueRounded,
            'date': '${timestamp.year.toString().padLeft(4, '0')}-'
                '${timestamp.month.toString().padLeft(2, '0')}-'
                '${timestamp.day.toString().padLeft(2, '0')}',
            'notes': 'Synced from Apple Health',
          };
          await _baseProvider.post(body, _baseProvider.makeUrl(_measurementUrl));
        } else {
          // No standard category — log as notes for lean mass
          _logger.info('No measurement category for ${syncDataTypeDisplayName(syncType)}, '
              'value=$valueRounded on $timestamp');
        }

        syncedCount++;
        if (latestSynced == null || timestamp.isAfter(latestSynced)) {
          latestSynced = timestamp;
        }
      } catch (e) {
        _logger.warning('Failed to sync ${syncDataTypeDisplayName(syncType)} entry: $e');
      }
    }

    if (latestSynced != null) {
      await prefs.setTypeLastSyncTimestamp(typeKey, latestSynced.toIso8601String());
    }

    _logger.info('Synced $syncedCount ${syncDataTypeDisplayName(syncType)} entries');
    _updateTypeState(syncType, syncedCount: syncedCount);
    return syncedCount;
  }

  // ───────── Body Measurement Push (wger → Apple Health) ─────────

  /// Push all new measurement entries from wger to Apple Health.
  Future<int> _syncMeasurementPush(
    SyncDataType syncType,
    HealthDataType healthType,
  ) async {
    if (!Platform.isIOS) return 0;

    final prefs = PreferenceHelper.instance;
    final enabled = await prefs.getHealthSyncEnabled();
    if (!enabled) return 0;

    // Ensure WRITE permission
    final hasPerms = await _health.hasPermissions(
      [healthType],
      permissions: [HealthDataAccess.WRITE],
    );
    if (hasPerms != true) {
      _logger.warning('No WRITE permission for $healthType — skipping push');
      return 0;
    }

    final typeKey = syncDataTypeToPrefKey(syncType);
    final pushedKey = '${typeKey}_pushed_ids';
    final pushedStr = await prefs.getTypeLastSyncTimestamp(pushedKey);
    final pushedIds = pushedStr != null
        ? pushedStr.split(',').where((s) => s.isNotEmpty).map(int.parse).toSet()
        : <int>{};

    _logger.info('Pushing ${syncDataTypeDisplayName(syncType)} to Apple Health');

    final categoryId = syncDataTypeToMeasurementCategory(syncType);
    int pushCount = 0;
    try {
      final query = categoryId != null
          ? {'category': categoryId.toString(), 'limit': '200'}
          : {'limit': '200'};

      final data = await _baseProvider.fetchPaginated(
        _baseProvider.makeUrl(_measurementUrl, query: query),
      );

      for (final entryJson in data) {
        final entry = MeasurementEntry.fromJson(entryJson);
        if (entry.id == null || pushedIds.contains(entry.id!)) continue;

        final value = entry.value.toDouble();
        final timestamp = entry.date;
        final endTime = timestamp.add(const Duration(seconds: 1));

        try {
          await _health.writeHealthData(
            value: value,
            type: healthType,
            startTime: timestamp,
            endTime: endTime,
          );
          pushedIds.add(entry.id!);
          pushCount++;
        } catch (e) {
          _logger.warning('Failed to push ${syncDataTypeDisplayName(syncType)} '
              'entry ${entry.id}: $e');
        }
      }

      await prefs.setTypeLastSyncTimestamp(pushedKey, pushedIds.join(','));

      _logger.info('Pushed $pushCount ${syncDataTypeDisplayName(syncType)} entries');
    } catch (e) {
      _logger.warning('Measurement push failed: $e');
    }

    return pushCount;
  }

  /// Push a single measurement entry to Apple Health immediately (write-through).
  Future<bool> pushMeasurementToHealth(MeasurementEntry entry) async {
    if (!Platform.isIOS || entry.id == null) return false;

    // Only push body composition types that map to Apple Health
    final syncType = syncDataTypeFromMeasurementCategory(entry.category);
    if (syncType == null) return false;

    try {
      final prefs = PreferenceHelper.instance;
      final enabled = await prefs.getHealthSyncEnabled();
      if (!enabled) return false;

      final typeState = state.typeStates[syncType] ?? const SyncTypeState();
      if (typeState.direction == SyncDirection.pull) return false;

      final healthType = _healthTypeFor(syncType);

      final hasPerms = await _health.hasPermissions(
        [healthType],
        permissions: [HealthDataAccess.WRITE],
      );
      if (hasPerms != true) return false;

      final value = entry.value.toDouble();
      final timestamp = entry.date;
      final endTime = timestamp.add(const Duration(seconds: 1));

      await _health.writeHealthData(
        value: value,
        type: healthType,
        startTime: timestamp,
        endTime: endTime);

      final typeKey = syncDataTypeToPrefKey(syncType);
      final pushedKey = '${typeKey}_pushed_ids';
      final pushedStr = await prefs.getTypeLastSyncTimestamp(pushedKey);
      final pushedIds = pushedStr != null
          ? pushedStr.split(',').where((s) => s.isNotEmpty).map(int.parse).toSet()
          : <int>{};
      pushedIds.add(entry.id!);
      await prefs.setTypeLastSyncTimestamp(pushedKey, pushedIds.join(','));

      return true;
    } catch (e) {
      _logger.warning('Measurement write-through push failed: $e');
      return false;
    }
  }

  // ───────── Helpers ─────────

  /// Update the per-type state in [typeStates].
  void _updateTypeState(SyncDataType type, {int syncedCount = 0}) {
    final current = state.typeStates[type] ?? const SyncTypeState();
    final updated = current.copyWith(
      lastSyncCount: current.lastSyncCount + syncedCount,
      lastSyncTimestamp: DateTime.now(),
    );
    final newMap = Map<SyncDataType, SyncTypeState>.from(state.typeStates);
    newMap[type] = updated;
    state = state.copyWith(typeStates: newMap);
  }

  /// Update an individual type's enabled/direction and persist.
  Future<void> updateTypeConfig(
    SyncDataType type, {
    bool? enabled,
    SyncDirection? direction,
  }) async {
    final current = state.typeStates[type] ?? const SyncTypeState();
    final updated = current.copyWith(
      enabled: enabled ?? current.enabled,
      direction: direction ?? current.direction,
    );
    final newMap = Map<SyncDataType, SyncTypeState>.from(state.typeStates);
    newMap[type] = updated;
    state = state.copyWith(typeStates: newMap);
    await saveTypeState(type, updated);
  }

  /// Map [SyncDataType] to [HealthDataType] from the `health` package.
  static HealthDataType _healthTypeFor(SyncDataType type) {
    switch (type) {
      case SyncDataType.weight:
        return HealthDataType.WEIGHT;
      case SyncDataType.bodyFat:
        return HealthDataType.BODY_FAT_PERCENTAGE;
      case SyncDataType.waist:
        return HealthDataType.WAIST_CIRCUMFERENCE;
      case SyncDataType.leanMass:
        return HealthDataType.LEAN_BODY_MASS;
      case SyncDataType.workouts:
        return HealthDataType.WORKOUT;
    }
  }
}