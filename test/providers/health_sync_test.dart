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

import 'package:flutter_test/flutter_test.dart';
import 'package:wger/providers/health_sync.dart';
import 'package:wger/providers/health_sync_config.dart';

/// Mirrors the conversion logic in HealthSyncNotifier.syncOnAppOpen
double _convertWeight(double weightKg, {required bool isMetric}) {
  return isMetric ? weightKg : weightKg * kgToLb;
}

void main() {
  group('Health sync constants', () {
    test('kgToLb conversion factor is correct', () {
      // 1 kg = 2.20462 lb
      expect(kgToLb, closeTo(2.20462, 0.00001));
    });
  });

  group('Weight unit conversion', () {
    test('kg value is converted to lb correctly', () {
      const weightKg = 85.0;
      final weightLb = (weightKg * kgToLb * 100).roundToDouble() / 100;
      expect(weightLb, closeTo(187.39, 0.01));
    });

    test('kg value stays as-is when metric', () {
      const weightKg = 85.0;
      final weight = _convertWeight(weightKg, isMetric: true);
      expect(weight, 85.0);
    });

    test('kg value is converted when imperial', () {
      const weightKg = 85.0;
      final weight = _convertWeight(weightKg, isMetric: false);
      expect(weight, closeTo(187.39, 0.01));
    });

    test('conversion rounds to 2 decimal places', () {
      const weightKg = 85.12345;
      final weight = weightKg * kgToLb;
      final rounded = (weight * 100).roundToDouble() / 100;
      // 85.12345 * 2.20462 = 187.66...
      expect(rounded.toString().split('.').last.length, lessThanOrEqualTo(2));
    });
  });

  group('HealthSyncState', () {
    test('default state has sync disabled', () {
      const state = HealthSyncState();
      expect(state.isEnabled, false);
      expect(state.isSyncing, false);
      expect(state.pushInProgress, false);
      expect(state.lastSyncCount, 0);
      expect(state.typeStates, isEmpty);
    });

    test('copyWith updates individual fields', () {
      const state = HealthSyncState();
      final updated = state.copyWith(isEnabled: true, lastSyncCount: 5);
      expect(updated.isEnabled, true);
      expect(updated.isSyncing, false);
      expect(updated.lastSyncCount, 5);
    });

    test('copyWith updates pushInProgress and typeStates', () {
      const state = HealthSyncState();
      final typeStates = {SyncDataType.weight: const SyncTypeState(enabled: true)};
      final updated = state.copyWith(pushInProgress: true, typeStates: typeStates);
      expect(updated.pushInProgress, true);
      expect(updated.typeStates, containsPair(SyncDataType.weight, isA<SyncTypeState>()));
    });
  });

  group('SyncDataType', () {
    test('allSyncDataTypes contains all types', () {
      expect(allSyncDataTypes.length, 5);
      expect(allSyncDataTypes, containsAll([
        SyncDataType.weight,
        SyncDataType.bodyFat,
        SyncDataType.waist,
        SyncDataType.leanMass,
        SyncDataType.workouts,
      ]));
    });

    test('syncDataTypeDisplayName returns human-readable names', () {
      expect(syncDataTypeDisplayName(SyncDataType.weight), 'Body Weight');
      expect(syncDataTypeDisplayName(SyncDataType.bodyFat), 'Body Fat %');
      expect(syncDataTypeDisplayName(SyncDataType.waist), 'Waist Circumference');
      expect(syncDataTypeDisplayName(SyncDataType.leanMass), 'Lean Body Mass');
      expect(syncDataTypeDisplayName(SyncDataType.workouts), 'Workouts');
    });

    test('syncDataTypeToPrefKey returns valid keys', () {
      expect(syncDataTypeToPrefKey(SyncDataType.weight), 'weight');
      expect(syncDataTypeToPrefKey(SyncDataType.bodyFat), 'bodyFat');
      expect(syncDataTypeToPrefKey(SyncDataType.workouts), 'workouts');
    });

    test('syncDataTypeToHealthType returns valid HealthDataType names', () {
      expect(syncDataTypeToHealthType(SyncDataType.weight), 'WEIGHT');
      expect(syncDataTypeToHealthType(SyncDataType.bodyFat), 'BODY_FAT_PERCENTAGE');
      expect(syncDataTypeToHealthType(SyncDataType.workouts), 'WORKOUT');
    });
  });

  group('SyncDirection', () {
    test('syncDirectionFromString maps correctly', () {
      expect(syncDirectionFromString('pull'), SyncDirection.pull);
      expect(syncDirectionFromString('push'), SyncDirection.push);
      expect(syncDirectionFromString('bidirectional'), SyncDirection.bidirectional);
      expect(syncDirectionFromString('unknown'), SyncDirection.pull);
    });

    test('syncDirectionToString maps correctly', () {
      expect(syncDirectionToString(SyncDirection.pull), 'pull');
      expect(syncDirectionToString(SyncDirection.push), 'push');
      expect(syncDirectionToString(SyncDirection.bidirectional), 'bidirectional');
    });
  });

  group('SyncTypeState', () {
    test('default state has pull direction and no timestamp', () {
      const state = SyncTypeState();
      expect(state.enabled, true);
      expect(state.direction, SyncDirection.pull);
      expect(state.lastSyncTimestamp, isNull);
      expect(state.lastSyncCount, 0);
    });

    test('copyWith updates fields', () {
      const state = SyncTypeState();
      final updated = state.copyWith(
        enabled: false,
        direction: SyncDirection.bidirectional,
        lastSyncCount: 10,
      );
      expect(updated.enabled, false);
      expect(updated.direction, SyncDirection.bidirectional);
      expect(updated.lastSyncCount, 10);
    });
  });

  group('Measurement category mapping', () {
    test('bodyFat maps to category 13', () {
      expect(syncDataTypeToMeasurementCategory(SyncDataType.bodyFat), 13);
    });

    test('waist maps to category 2', () {
      expect(syncDataTypeToMeasurementCategory(SyncDataType.waist), 2);
    });

    test('leanMass has no standard category', () {
      expect(syncDataTypeToMeasurementCategory(SyncDataType.leanMass), isNull);
    });

    test('bodyCompDataTypes contains correct types', () {
      expect(bodyCompDataTypes, containsAll([
        SyncDataType.bodyFat,
        SyncDataType.waist,
        SyncDataType.leanMass,
      ]));
      expect(bodyCompDataTypes.length, 3);
    });
  });
}
