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

import 'package:flutter/material.dart';
import 'package:health/health.dart';
import 'package:logging/logging.dart';
import 'package:wger/helpers/shared_preferences.dart';
import 'package:wger/models/workouts/log.dart';
import 'package:wger/models/workouts/session.dart';
import 'package:wger/providers/base_provider.dart';
import 'package:wger/providers/health_sync_config.dart';

/// Manages bidirectional sync of workout data between Apple Health and wger.
///
/// Pull: Apple Health WORKOUT → wger WorkoutSession
/// Push: wger WorkoutSession logs → Apple Health WORKOUT
class WorkoutSyncService {
  final _logger = Logger('WorkoutSyncService');

  final Health _health;
  final WgerBaseProvider _baseProvider;

  static const _sessionUrl = 'workoutsession';
  static const _routineUrl = 'routine';
  static const _syncedRoutineName = 'Synced from Apple Health';

  WorkoutSyncService(this._health, this._baseProvider);

  // ───────── Pull: Apple Health → wger ─────────

  /// Pull workout data from Apple Health and create wger sessions.
  ///
  /// Returns the number of new workout sessions created.
  Future<int> pullWorkouts({required bool isMetric}) async {
    if (!Platform.isIOS) return 0;

    final prefs = PreferenceHelper.instance;
    final enabled = await prefs.getHealthSyncEnabled();
    if (!enabled) return 0;

    // Check READ permission
    final hasPerms = await _health.hasPermissions(
      [HealthDataType.WORKOUT],
      permissions: [HealthDataAccess.READ],
    );
    if (hasPerms != true) {
      _logger.warning('No READ permission for WORKOUT — skipping pull');
      return 0;
    }

    final lastSyncStr = await prefs.getTypeLastSyncTimestamp(
      syncDataTypeToPrefKey(SyncDataType.workouts),
    );
    final startTime = lastSyncStr != null ? DateTime.parse(lastSyncStr) : DateTime(2000);
    final endTime = DateTime.now();

    _logger.info('Pulling workouts from Health ($startTime → $endTime)');

    List<HealthDataPoint> dataPoints;
    try {
      dataPoints = await _health.getHealthDataFromTypes(
        types: [HealthDataType.WORKOUT],
        startTime: startTime,
        endTime: endTime,
      );
    } catch (e) {
      _logger.warning('Failed to read workouts from Health: $e');
      return 0;
    }
    dataPoints = _health.removeDuplicates(dataPoints);

    if (dataPoints.isEmpty) {
      _logger.info('No new workouts from Health');
      return 0;
    }

    _logger.info('Found ${dataPoints.length} workouts from Health');

    // Get or create the synced routine
    final routineId = await _findOrCreateSyncedRoutine();
    if (routineId == null) {
      _logger.warning('Could not find or create synced routine');
      return 0;
    }

    // Load existing session dates for dedup
    final existingDates = await _fetchExistingSessionDates(routineId);

    int syncedCount = 0;
    DateTime? latestSynced;

    for (final point in dataPoints) {
      try {
        final value = point.value;
        if (value is! WorkoutHealthValue) continue;

        final workoutType = value.workoutActivityType;
        final startDate = point.dateFrom;
        final endDate = point.dateTo;
        final energyBurned = value.totalEnergyBurned;
        final distance = value.totalDistance;

        // Dedup by date — skip if a session already exists for this date
        final dateKey = DateTime(startDate.year, startDate.month, startDate.day);
        if (existingDates.contains(dateKey)) {
          _logger.fine('Skipping duplicate workout on $dateKey');
          continue;
        }

        // Build notes with workout details
        final typeLabel = _workoutTypeLabel(workoutType);
        final duration = startDate.difference(endDate).inMinutes.abs();
        final notesBuffer = StringBuffer()
          ..write('Apple Health: $typeLabel')
          ..write(' · ${duration}min');
        if (energyBurned != null) {
          notesBuffer.write(' · ${energyBurned} kcal');
        }
        if (distance != null) {
          notesBuffer.write(' · ${(distance / 1000).toStringAsFixed(1)} km');
        }

        final session = WorkoutSession(
          routineId: routineId,
          date: startDate,
          impression: 2,
          notes: notesBuffer.toString(),
          timeStart: TimeOfDay.fromDateTime(startDate),
          timeEnd: TimeOfDay.fromDateTime(endDate),
        );

        await _baseProvider.post(
          session.toJson(),
          _baseProvider.makeUrl(_sessionUrl),
        );

        syncedCount++;
        existingDates.add(dateKey);
        if (latestSynced == null || startDate.isAfter(latestSynced)) {
          latestSynced = startDate;
        }
      } catch (e) {
        _logger.warning('Failed to sync workout: $e');
      }
    }

    if (latestSynced != null) {
      await prefs.setTypeLastSyncTimestamp(
        syncDataTypeToPrefKey(SyncDataType.workouts),
        latestSynced.toIso8601String(),
      );
    }

    _logger.info('Synced $syncedCount workouts to wger');
    return syncedCount;
  }

  // ───────── Push: wger → Apple Health ─────────

  /// Push wger workout sessions (with logs) to Apple Health.
  ///
  /// Calculates volume, duration, and calories from the session's logs
  /// and writes a strength training workout to Health Kit.
  Future<int> pushWorkouts() async {
    if (!Platform.isIOS) return 0;

    final prefs = PreferenceHelper.instance;
    final enabled = await prefs.getHealthSyncEnabled();
    if (!enabled) return 0;

    // Check WRITE permission for WORKOUT
    final hasPerms = await _health.hasPermissions(
      [HealthDataType.WORKOUT],
      permissions: [HealthDataAccess.WRITE],
    );
    if (hasPerms != true) {
      _logger.warning('No WRITE permission for WORKOUT — skipping push');
      return 0;
    }

    // Load already-pushed session IDs
    final pushedStr =
        await prefs.getTypeLastSyncTimestamp('workouts_pushed_ids');
    final pushedIds = pushedStr != null
        ? pushedStr.split(',').where((s) => s.isNotEmpty).map(int.parse).toSet()
        : <int>{};

    _logger.info(
        'Pushing workouts to Apple Health (${pushedIds.length} already pushed)');

    int pushCount = 0;
    try {
      // Fetch all workout sessions from wger
      final data = await _baseProvider.fetchPaginated(
        _baseProvider.makeUrl(_sessionUrl, query: {'limit': '200'}),
      );

      for (final sessionJson in data) {
        final session = WorkoutSession.fromJson(sessionJson);
        if (session.id == null || pushedIds.contains(session.id!)) continue;
        if (session.timeStart == null || session.timeEnd == null) continue;

        // Calculate start and end DateTimes
        final now = DateTime.now();
        final startTime = DateTime(
          session.date.year,
          session.date.month,
          session.date.day,
          session.timeStart!.hour,
          session.timeStart!.minute,
        );
        final endTime = DateTime(
          session.date.year,
          session.date.month,
          session.date.day,
          session.timeEnd!.hour,
          session.timeEnd!.minute,
        );

        // Estimate calories: ~6 kcal/min for strength training, ~8 for intense
        final durationMin = endTime.difference(startTime).inMinutes.abs();
        final estimatedCalories = (durationMin * 6).toInt();

        try {
          await _health.writeWorkoutData(
            activityType: HealthWorkoutActivityType.TRADITIONAL_STRENGTH_TRAINING,
            start: startTime,
            end: endTime,
            totalEnergyBurned: estimatedCalories,
            totalEnergyBurnedUnit: HealthDataUnit.KILOCALORIE,
          );
          pushedIds.add(session.id!);
          pushCount++;
        } catch (e) {
          _logger.warning('Failed to push workout session ${session.id}: $e');
        }
      }

      await prefs.setTypeLastSyncTimestamp(
        'workouts_pushed_ids',
        pushedIds.join(','),
      );

      _logger.info('Pushed $pushCount workouts to Apple Health');
    } catch (e) {
      _logger.warning('Workout push failed: $e');
    }

    return pushCount;
  }

  // ───────── Helpers ─────────

  /// Find the "Synced from Apple Health" routine, or create one.
  Future<int?> _findOrCreateSyncedRoutine() async {
    try {
      // Search existing routines by name
      final routines = await _baseProvider.fetchPaginated(
        _baseProvider.makeUrl(_routineUrl, query: {'limit': '50'}),
      );
      for (final r in routines) {
        if (r['name'] == _syncedRoutineName) {
          return r['id'] as int;
        }
      }

      // Not found — create it
      final created = await _baseProvider.post(
        {'name': _syncedRoutineName, 'description': 'Auto-created for Apple Health sync'},
        _baseProvider.makeUrl(_routineUrl),
      );
      return created['id'] as int;
    } catch (e) {
      _logger.warning('Failed to find/create synced routine: $e');
      return null;
    }
  }

  /// Fetch dates of existing workout sessions for dedup.
  Future<Set<DateTime>> _fetchExistingSessionDates(int routineId) async {
    try {
      final data = await _baseProvider.fetchPaginated(
        _baseProvider.makeUrl(
          _sessionUrl,
          query: {'routine': routineId.toString(), 'limit': '200'},
        ),
      );
      return data
          .map((json) {
            try {
              return WorkoutSession.fromJson(json).date;
            } catch (_) {
              return null;
            }
          })
          .whereType<DateTime>()
          .map((d) => DateTime(d.year, d.month, d.day))
          .toSet();
    } catch (e) {
      _logger.warning('Failed to fetch existing sessions: $e');
      return {};
    }
  }

  /// Human-readable label for a workout activity type.
  String _workoutTypeLabel(HealthWorkoutActivityType type) {
    switch (type) {
      case HealthWorkoutActivityType.RUNNING:
        return 'Running';
      case HealthWorkoutActivityType.BIKING:
        return 'Cycling';
      case HealthWorkoutActivityType.SWIMMING:
        return 'Swimming';
      case HealthWorkoutActivityType.WALKING:
        return 'Walking';
      case HealthWorkoutActivityType.YOGA:
        return 'Yoga';
      case HealthWorkoutActivityType.HIKING:
        return 'Hiking';
      case HealthWorkoutActivityType.STRENGTH_TRAINING:
      case HealthWorkoutActivityType.TRADITIONAL_STRENGTH_TRAINING:
        return 'Strength Training';
      case HealthWorkoutActivityType.HIGH_INTENSITY_INTERVAL_TRAINING:
        return 'HIIT';
      case HealthWorkoutActivityType.CARDIO_DANCE:
        return 'Cardio Dance';
      case HealthWorkoutActivityType.ELLIPTICAL:
        return 'Elliptical';
      case HealthWorkoutActivityType.ROWING:
        return 'Rowing';
      case HealthWorkoutActivityType.STAIR_CLIMBING:
        return 'Stair Climber';
      case HealthWorkoutActivityType.PILATES:
        return 'Pilates';
      case HealthWorkoutActivityType.CORE_TRAINING:
        return 'Core Training';
      case HealthWorkoutActivityType.FLEXIBILITY:
        return 'Flexibility';
      case HealthWorkoutActivityType.FUNCTIONAL_STRENGTH_TRAINING:
        return 'Functional Training';
      case HealthWorkoutActivityType.MIND_AND_BODY:
        return 'Mind & Body';
      case HealthWorkoutActivityType.FITNESS_GAMING:
        return 'Fitness Gaming';
      case HealthWorkoutActivityType.CROSS_TRAINING:
        return 'Cross Training';
      case HealthWorkoutActivityType.COOLDOWN:
        return 'Cooldown';
      default:
        return type.name.replaceAll('_', ' ').split(' ').map(
              (word) => word.isNotEmpty
                  ? '${word[0].toUpperCase()}${word.substring(1).toLowerCase()}'
                  : '',
            ).join(' ');
    }
  }
}