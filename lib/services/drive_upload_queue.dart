import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import 'google_drive_service.dart';

const _driveUploadTaskName = 'pilahFotoDriveUpload';
const _driveUploadBatchesKey = 'pilah_drive_upload_batches';

class DriveUploadBatchResult {
  final String id;
  final List<String> uploadedAssetIds;
  final List<String> stagedPaths;
  final int failedCount;
  final int missingDestinationCount;

  const DriveUploadBatchResult({
    required this.id,
    required this.uploadedAssetIds,
    required this.stagedPaths,
    required this.failedCount,
    required this.missingDestinationCount,
  });
}

class DriveUploadQueue {
  static final SharedPreferencesAsync _preferences = SharedPreferencesAsync();

  static String createBatchId() =>
      'batch_${DateTime.now().microsecondsSinceEpoch}';

  static String createTaskId(String batchId, int sequence) =>
      '${batchId}_$sequence';

  static Future<void> enqueue({
    required String batchId,
    required String taskId,
    required String assetId,
    required String targetLabel,
    required String accountEmail,
    required String sourcePath,
    required String fileName,
    required String parentId,
  }) async {
    final job = <String, dynamic>{
      'batchId': batchId,
      'assetId': assetId,
      'targetLabel': targetLabel,
      'accountEmail': accountEmail,
      'sourcePath': sourcePath,
      'fileName': fileName,
      'parentId': parentId,
      'status': 'queued',
    };
    await _registerJob(batchId, taskId);
    await _preferences.setString(_jobKey(taskId), jsonEncode(job));

    try {
      await Workmanager().registerOneOffTask(
        'pilahfoto-drive-$batchId',
        _driveUploadTaskName,
        inputData: {...job, 'taskId': taskId},
        constraints: Constraints(networkType: NetworkType.connected),
        existingWorkPolicy: ExistingWorkPolicy.append,
        foregroundServiceConfig: ForegroundServiceConfig(
          notificationTitle: 'PilahFoto',
          notificationText: 'Uploading media to Google Drive',
          notificationChannelName: 'Drive uploads',
          foregroundServiceType: ForegroundServiceType.dataSync,
        ),
      );
    } catch (error) {
      await _setJobStatus(taskId, 'failed', error.toString());
      rethrow;
    }
  }

  static Future<void> recordFailure({
    required String batchId,
    required String taskId,
    required String assetId,
    required String targetLabel,
    required String error,
  }) async {
    final job = <String, dynamic>{
      'batchId': batchId,
      'assetId': assetId,
      'targetLabel': targetLabel,
      'status': 'failed',
      'error': error,
    };
    await _registerJob(batchId, taskId);
    await _preferences.setString(_jobKey(taskId), jsonEncode(job));
  }

  static Future<void> _registerJob(String batchId, String taskId) async {
    final batch = await _readBatch(batchId);
    final jobIds = List<String>.from(batch['jobIds'] as List? ?? const []);
    if (!jobIds.contains(taskId)) jobIds.add(taskId);
    batch
      ..['jobIds'] = jobIds
      ..['sealed'] = false;
    await _preferences.setString(_batchKey(batchId), jsonEncode(batch));

    final batchIds =
        await _preferences.getStringList(_driveUploadBatchesKey) ?? [];
    if (!batchIds.contains(batchId)) {
      await _preferences.setStringList(_driveUploadBatchesKey, [
        ...batchIds,
        batchId,
      ]);
    }
  }

  static Future<void> sealBatch(String batchId) async {
    final batch = await _readBatch(batchId);
    batch['sealed'] = true;
    await _preferences.setString(_batchKey(batchId), jsonEncode(batch));
  }

  static Future<List<DriveUploadBatchResult>> getReadyBatches() async {
    final batchIds =
        await _preferences.getStringList(_driveUploadBatchesKey) ?? [];
    final ready = <DriveUploadBatchResult>[];

    for (final batchId in batchIds) {
      final batch = await _readBatch(batchId);
      if (batch['sealed'] != true || batch['deleteStatus'] != 'waiting') {
        continue;
      }

      final jobs = <Map<String, dynamic>>[];
      final jobIds = List<String>.from(batch['jobIds'] as List? ?? const []);
      for (final taskId in jobIds) {
        final encodedJob = await _preferences.getString(_jobKey(taskId));
        if (encodedJob == null) {
          jobs.add({'status': 'failed'});
        } else {
          jobs.add(Map<String, dynamic>.from(jsonDecode(encodedJob) as Map));
        }
      }

      if (jobs.any(
        (job) => job['status'] != 'uploaded' && job['status'] != 'failed',
      )) {
        continue;
      }

      ready.add(
        DriveUploadBatchResult(
          id: batchId,
          uploadedAssetIds: jobs
              .where((job) => job['status'] == 'uploaded')
              .map((job) => job['assetId'] as String)
              .toSet()
              .toList(),
          stagedPaths: jobs
              .map((job) => job['sourcePath'])
              .whereType<String>()
              .toList(),
          failedCount: jobs.where((job) => job['status'] == 'failed').length,
          missingDestinationCount: jobs
              .where(
                (job) =>
                    job['status'] == 'failed' &&
                    (job['error'] as String? ?? '').contains(
                      'Destination folder not found.',
                    ),
              )
              .length,
        ),
      );
    }
    return ready;
  }

  static Future<bool> markDeletionRequested(String batchId) async {
    final batch = await _readBatch(batchId);
    if (batch['deleteStatus'] != 'waiting') return false;
    batch['deleteStatus'] = 'requested';
    await _preferences.setString(_batchKey(batchId), jsonEncode(batch));
    return true;
  }

  static Future<void> completeBatch(String batchId) async {
    final batch = await _readBatch(batchId);
    batch['deleteStatus'] = 'complete';
    await _preferences.setString(_batchKey(batchId), jsonEncode(batch));
  }

  static Future<void> _setJobStatus(
    String taskId,
    String status, [
    String? error,
  ]) async {
    final encodedJob = await _preferences.getString(_jobKey(taskId));
    if (encodedJob == null) {
      throw StateError('Drive upload queue job $taskId was not found.');
    }
    final job = Map<String, dynamic>.from(jsonDecode(encodedJob) as Map)
      ..['status'] = status;
    if (error != null) job['error'] = error;
    await _preferences.setString(_jobKey(taskId), jsonEncode(job));
  }

  static Future<Map<String, dynamic>> _readBatch(String batchId) async {
    final encodedBatch = await _preferences.getString(_batchKey(batchId));
    if (encodedBatch == null) {
      return {'jobIds': <String>[], 'sealed': false, 'deleteStatus': 'waiting'};
    }
    return Map<String, dynamic>.from(jsonDecode(encodedBatch) as Map);
  }

  static String _batchKey(String batchId) =>
      'pilah_drive_upload_batch_$batchId';
  static String _jobKey(String taskId) => 'pilah_drive_upload_job_$taskId';
}

@pragma('vm:entry-point')
void driveUploadCallbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    if (taskName != _driveUploadTaskName) return false;

    final taskId = inputData?['taskId'] as String?;
    final sourcePath = inputData?['sourcePath'] as String?;
    final fileName = inputData?['fileName'] as String?;
    final parentId = inputData?['parentId'] as String?;
    final accountEmail = inputData?['accountEmail'] as String?;
    if (taskId == null ||
        sourcePath == null ||
        fileName == null ||
        parentId == null ||
        accountEmail == null) {
      debugPrint('[DriveUpload] WorkManager task is missing required data.');
      return false;
    }

    final service = GoogleDriveService();
    var terminal = false;
    try {
      await DriveUploadQueue._setJobStatus(taskId, 'uploading');
      final account = await service.restoreSession();
      if (!service.isConnected || account?.email != accountEmail) {
        throw StateError(
          'Reconnect Google Drive as $accountEmail before retrying this upload.',
        );
      }

      var uploadedFile = await service.findUploadedFileByTaskId(taskId);
      if (uploadedFile == null) {
        await service.validateDestinationFolder(parentId);
        uploadedFile = await service.uploadFile(
          file: File(sourcePath),
          fileName: fileName,
          parentId: parentId,
          idempotencyKey: taskId,
        );
      }
      if (uploadedFile.id == null) {
        throw StateError('Google Drive did not return an uploaded file ID.');
      }

      await DriveUploadQueue._setJobStatus(taskId, 'uploaded');
      terminal = true;
      return true;
    } catch (error, stackTrace) {
      debugPrint('[DriveUpload] Upload $taskId failed: $error\n$stackTrace');
      try {
        await DriveUploadQueue._setJobStatus(
          taskId,
          'failed',
          error.toString(),
        );
        terminal = true;
        return true;
      } catch (recordError, recordStackTrace) {
        debugPrint(
          '[DriveUpload] Could not record failure for $taskId: '
          '$recordError\n$recordStackTrace',
        );
        return false;
      }
    } finally {
      service.close();
      if (terminal) {
        try {
          final stagedFile = File(sourcePath);
          if (await stagedFile.exists()) await stagedFile.delete();
        } on FileSystemException catch (error) {
          debugPrint('[DriveUpload] Could not remove staged file: $error');
        }
      }
    }
  });
}
