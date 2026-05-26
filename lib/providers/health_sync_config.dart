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

import 'package:health/health.dart';
import 'package:wger/helpers/shared_preferences.dart';

/// Supported health data types for sync.
///
/// Each enum value maps to a [HealthDataType] from the `health` package
/// and one or more wger API models.
enum SyncDataType {
  /// Body weight → weightentry
  weight,

  /// Body fat percentage → measurement (category 13)
  bodyFat,

  /// Waist circumference → measurement (category 2)
  waist,

  /// Lean body mass → measurement (needs category)
  leanMass,

  /// Workout sessions → workoutsession + workoutlog
  workouts,
}

/// Sync direction for a data type.
enum SyncDirection {
  /// Read from Apple Health and write to wger
  pull,

  /// Read from wger and write to Apple Health
  push,

  /// Both directions
  bidirectional,
}

/// Runtime state for a single data type's sync configuration.
class SyncTypeState {
  final bool enabled;
  final SyncDirection direction;
  final DateTime? lastSyncTimestamp;
  final int lastSyncCount;

  const SyncTypeState({
    this.enabled = true,
    this.direction = SyncDirection.pull,
    this.lastSyncTimestamp,
    this.lastSyncCount = 0,
  });

  SyncTypeState copyWith({
    bool? enabled,
    SyncDirection? direction,
    DateTime? lastSyncTimestamp,
    int? lastSyncCount,
  }) {
    return SyncTypeState(
      enabled: enabled ?? this.enabled,
      direction: direction ?? this.direction,
      lastSyncTimestamp: lastSyncTimestamp ?? this.lastSyncTimestamp,
      lastSyncCount: lastSyncCount ?? this.lastSyncCount,
    );
  }
}

/// All sync data types in a consistent iteration order.
const allSyncDataTypes = [
  SyncDataType.weight,
  SyncDataType.bodyFat,
  SyncDataType.waist,
  SyncDataType.leanMass,
  SyncDataType.workouts,
];

/// Maps [SyncDataType] to a human-readable display name.
String syncDataTypeDisplayName(SyncDataType type) {
  switch (type) {
    case SyncDataType.weight:
      return 'Body Weight';
    case SyncDataType.bodyFat:
      return 'Body Fat %';
    case SyncDataType.waist:
      return 'Waist Circumference';
    case SyncDataType.leanMass:
      return 'Lean Body Mass';
    case SyncDataType.workouts:
      return 'Workouts';
  }
}

/// Maps [SyncDataType] to an icon name for the settings UI.
String syncDataTypeIcon(SyncDataType type) {
  switch (type) {
    case SyncDataType.weight:
      return 'monitor_weight';
    case SyncDataType.bodyFat:
      return 'percent';
    case SyncDataType.waist:
      return 'straighten';
    case SyncDataType.leanMass:
      return 'fitness_center';
    case SyncDataType.workouts:
      return 'fitness_center';
  }
}

/// Maps [SyncDataType] to a string key used in SharedPreferences.
String syncDataTypeToPrefKey(SyncDataType type) {
  switch (type) {
    case SyncDataType.weight:
      return 'weight';
    case SyncDataType.bodyFat:
      return 'bodyFat';
    case SyncDataType.waist:
      return 'waist';
    case SyncDataType.leanMass:
      return 'leanMass';
    case SyncDataType.workouts:
      return 'workouts';
  }
}

/// Maps a string from SharedPreferences back to [SyncDirection].
SyncDirection syncDirectionFromString(String value) {
  switch (value) {
    case 'push':
      return SyncDirection.push;
    case 'bidirectional':
      return SyncDirection.bidirectional;
    default:
      return SyncDirection.pull;
  }
}

/// Maps [SyncDirection] to a string for SharedPreferences.
String syncDirectionToString(SyncDirection direction) {
  switch (direction) {
    case SyncDirection.pull:
      return 'pull';
    case SyncDirection.push:
      return 'push';
    case SyncDirection.bidirectional:
      return 'bidirectional';
  }
}

/// Health data type identifier string used for Apple Health permissions.
///
/// Maps each [SyncDataType] to its corresponding [HealthDataType] name.
/// Actual [HealthDataType] values come from the `health` package.
String syncDataTypeToHealthType(SyncDataType type) {
  switch (type) {
    case SyncDataType.weight:
      return 'WEIGHT';
    case SyncDataType.bodyFat:
      return 'BODY_FAT_PERCENTAGE';
    case SyncDataType.waist:
      return 'WAIST_CIRCUMFERENCE';
    case SyncDataType.leanMass:
      return 'LEAN_BODY_MASS';
    case SyncDataType.workouts:
      return 'WORKOUT';
  }
}

/// Load per-type config from SharedPreferences into a [SyncTypeState].
Future<SyncTypeState> loadTypeState(SyncDataType type) async {
  final prefs = PreferenceHelper.instance;
  final key = syncDataTypeToPrefKey(type);
  final enabled = await prefs.getTypeSyncEnabled(key);
  final dirStr = await prefs.getTypeSyncDirection(key);
  final tsStr = await prefs.getTypeLastSyncTimestamp(key);
  final direction = syncDirectionFromString(dirStr);
  final timestamp = tsStr != null ? DateTime.tryParse(tsStr) : null;

  return SyncTypeState(
    enabled: enabled,
    direction: direction,
    lastSyncTimestamp: timestamp,
  );
}

/// Save per-type config to SharedPreferences.
Future<void> saveTypeState(SyncDataType type, SyncTypeState state) async {
  final prefs = PreferenceHelper.instance;
  final key = syncDataTypeToPrefKey(type);
  await prefs.setTypeSyncEnabled(key, state.enabled);
  await prefs.setTypeSyncDirection(key, syncDirectionToString(state.direction));
  if (state.lastSyncTimestamp != null) {
    await prefs.setTypeLastSyncTimestamp(key, state.lastSyncTimestamp!.toIso8601String());
  }
}

/// The set of data types that correspond to Apple Health body measurements.
const bodyCompDataTypes = {SyncDataType.bodyFat, SyncDataType.waist, SyncDataType.leanMass};

/// Additional health metrics that can be pulled into wger measurements.
///
/// Each entry defines the mapping from an Apple Health data type to a wger
/// measurement category (auto-created on first sync if it doesn't exist).
class HealthMetricDefinition {
  final HealthDataType healthType;
  final String displayName;
  final String categoryName;
  final String categoryUnit;
  final String iconName;

  const HealthMetricDefinition({
    required this.healthType,
    required this.displayName,
    required this.categoryName,
    required this.categoryUnit,
    required this.iconName,
  });
}

/// All supported additional health metrics.
const additionalHealthMetrics = [
  HealthMetricDefinition(
    healthType: HealthDataType.RESTING_HEART_RATE,
    displayName: 'Resting Heart Rate',
    categoryName: 'Resting Heart Rate',
    categoryUnit: 'bpm',
    iconName: 'favorite',
  ),
  HealthMetricDefinition(
    healthType: HealthDataType.STEPS,
    displayName: 'Steps',
    categoryName: 'Steps',
    categoryUnit: 'steps',
    iconName: 'directions_walk',
  ),
  HealthMetricDefinition(
    healthType: HealthDataType.ACTIVE_ENERGY_BURNED,
    displayName: 'Active Energy',
    categoryName: 'Active Energy',
    categoryUnit: 'kcal',
    iconName: 'local_fire_department',
  ),
  HealthMetricDefinition(
    healthType: HealthDataType.BLOOD_PRESSURE_SYSTOLIC,
    displayName: 'Blood Pressure (Systolic)',
    categoryName: 'Blood Pressure Systolic',
    categoryUnit: 'mmHg',
    iconName: 'monitor_heart',
  ),
  HealthMetricDefinition(
    healthType: HealthDataType.BLOOD_PRESSURE_DIASTOLIC,
    displayName: 'Blood Pressure (Diastolic)',
    categoryName: 'Blood Pressure Diastolic',
    categoryUnit: 'mmHg',
    iconName: 'monitor_heart',
  ),
  HealthMetricDefinition(
    healthType: HealthDataType.BODY_WATER_MASS,
    displayName: 'Body Water',
    categoryName: 'Body Water',
    categoryUnit: '%',
    iconName: 'water_drop',
  ),
];

/// The set of data types that have a wger measurement category mapping.
const measurementSyncDataTypes = {SyncDataType.bodyFat, SyncDataType.waist};

/// Measurement category IDs in wger for each supported sync type.
int? syncDataTypeToMeasurementCategory(SyncDataType type) {
  switch (type) {
    case SyncDataType.bodyFat:
      return 13; // Body fat %
    case SyncDataType.waist:
      return 2; // Waist circumference
    case SyncDataType.leanMass:
      return null; // No standard category — store in notes or custom
    default:
      return null;
  }
}

/// Map a wger measurement category ID back to the corresponding [SyncDataType].
///
/// Returns null if the category ID doesn't map to a supported sync type.
SyncDataType? syncDataTypeFromMeasurementCategory(int categoryId) {
  switch (categoryId) {
    case 13:
      return SyncDataType.bodyFat;
    case 2:
      return SyncDataType.waist;
    default:
      return null;
  }
}