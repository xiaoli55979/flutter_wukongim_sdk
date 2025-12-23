import 'dart:async';
import 'dart:collection';
import '../common/logs.dart';
import '../wkim.dart';

import '../type/const.dart';

/// 消息同步状态
enum SyncStatus {
  idle, // 空闲
  syncing, // 同步中
  completed, // 完成
  failed, // 失败
}

/// 同步任务
class SyncTask {
  final String channelId;
  final int channelType;
  final int startSeq;
  final int endSeq;
  final int batchSize;
  SyncStatus status = SyncStatus.idle;
  int retryCount = 0;
  DateTime? startTime;
  DateTime? endTime;

  SyncTask({
    required this.channelId,
    required this.channelType,
    required this.startSeq,
    required this.endSeq,
    required this.batchSize,
  });

  @override
  String toString() {
    return 'SyncTask{channel: $channelId:$channelType, seq: $startSeq-$endSeq, status: $status}';
  }
}

/// 智能消息同步管理器
class MessageSyncManager {
  static final MessageSyncManager _instance = MessageSyncManager._internal();
  static MessageSyncManager get shared => _instance;
  MessageSyncManager._internal();

  final Queue<SyncTask> _syncQueue = Queue<SyncTask>();
  final Map<String, SyncTask> _activeTasks = <String, SyncTask>{};
  Timer? _syncTimer;
  bool _isSyncing = false;
  int _totalSyncTasks = 0;
  int _completedSyncTasks = 0;

  /// 添加同步任务
  void addSyncTask(
      String channelId, int channelType, int startSeq, int endSeq) {
    final config = WKIM.shared.options.messageSyncConfig;

    // 将大任务拆分为小批次
    final totalMessages = endSeq - startSeq + 1;
    if (totalMessages <= config.batchSize) {
      final task = SyncTask(
        channelId: channelId,
        channelType: channelType,
        startSeq: startSeq,
        endSeq: endSeq,
        batchSize: config.batchSize,
      );
      _syncQueue.add(task);
      _totalSyncTasks++;
      Logs.message('添加同步任务: $task');
    } else {
      // 拆分为多个批次
      int currentSeq = startSeq;
      while (currentSeq <= endSeq) {
        final batchEndSeq =
            (currentSeq + config.batchSize - 1).clamp(currentSeq, endSeq);
        final task = SyncTask(
          channelId: channelId,
          channelType: channelType,
          startSeq: currentSeq,
          endSeq: batchEndSeq,
          batchSize: config.batchSize,
        );
        _syncQueue.add(task);
        _totalSyncTasks++;
        currentSeq = batchEndSeq + 1;
      }
      Logs.message(
          '拆分同步任务: $channelId:$channelType, 总计 ${_syncQueue.length} 个批次');
    }

    _startSyncProcess();
  }

  /// 开始同步流程
  void _startSyncProcess() {
    if (_isSyncing) return;

    _isSyncing = true;
    WKIM.shared.connectionManager.setConnectionStatus(WKConnectStatus.syncMsg);

    Logs.message('开始消息同步流程，总任务数: $_totalSyncTasks');
    _processSyncQueue();
  }

  /// 处理同步队列
  void _processSyncQueue() {
    final config = WKIM.shared.options.messageSyncConfig;

    // 控制并发数量
    while (_activeTasks.length < config.maxConcurrentSync &&
        _syncQueue.isNotEmpty) {
      final task = _syncQueue.removeFirst();
      _executeTask(task);
    }

    // 如果没有活跃任务且队列为空，同步完成
    if (_activeTasks.isEmpty && _syncQueue.isEmpty) {
      _completeSyncProcess();
      return;
    }

    // 继续处理队列
    _syncTimer = Timer(Duration(milliseconds: config.syncInterval), () {
      _processSyncQueue();
    });
  }

  /// 执行同步任务
  void _executeTask(SyncTask task) async {
    final taskKey = '${task.channelId}_${task.channelType}_${task.startSeq}';
    _activeTasks[taskKey] = task;

    task.status = SyncStatus.syncing;
    task.startTime = DateTime.now();

    Logs.message('执行同步任务: $task');

    try {
      // 调用实际的消息同步逻辑
      await _syncChannelMessages(task);

      task.status = SyncStatus.completed;
      task.endTime = DateTime.now();
      _completedSyncTasks++;

      final duration = task.endTime!.difference(task.startTime!).inMilliseconds;
      Logs.message('同步任务完成: $task, 耗时: ${duration}ms');
    } catch (e) {
      Logs.error('同步任务失败: $task, 错误: $e');
      task.status = SyncStatus.failed;

      // 重试逻辑
      final config = WKIM.shared.options.messageSyncConfig;
      if (task.retryCount < config.syncRetryCount) {
        task.retryCount++;
        task.status = SyncStatus.idle;
        _syncQueue.addFirst(task); // 重新加入队列头部
        Logs.message('任务重试: $task, 第 ${task.retryCount} 次');
      } else {
        Logs.error('任务重试次数超限，放弃: $task');
        _completedSyncTasks++;
      }
    } finally {
      _activeTasks.remove(taskKey);
    }
  }

  /// 同步频道消息的具体实现
  Future<void> _syncChannelMessages(SyncTask task) async {
    final config = WKIM.shared.options.messageSyncConfig;

    // 创建超时控制
    final completer = Completer<void>();
    final timeoutTimer = Timer(Duration(seconds: config.syncTimeout), () {
      if (!completer.isCompleted) {
        completer.completeError('同步超时');
      }
    });

    try {
      // 这里调用实际的消息同步API
      // 注意：这里需要根据实际的API接口进行调整
      await WKIM.shared.messageManager.syncChannelMessages(
        task.channelId,
        task.channelType,
        task.startSeq,
        task.endSeq,
      );

      if (!completer.isCompleted) {
        completer.complete();
      }
    } catch (e) {
      if (!completer.isCompleted) {
        completer.completeError(e);
      }
    } finally {
      timeoutTimer.cancel();
    }

    return completer.future;
  }

  /// 完成同步流程
  void _completeSyncProcess() {
    _isSyncing = false;
    _syncTimer?.cancel();
    _syncTimer = null;

    Logs.message('消息同步完成，总计: $_totalSyncTasks, 完成: $_completedSyncTasks');

    // 重置计数器
    _totalSyncTasks = 0;
    _completedSyncTasks = 0;

    // 通知同步完成
    WKIM.shared.connectionManager
        .setConnectionStatus(WKConnectStatus.syncCompleted);
  }

  /// 停止同步
  void stopSync() {
    Logs.message('停止消息同步');
    _isSyncing = false;
    _syncTimer?.cancel();
    _syncTimer = null;
    _syncQueue.clear();
    _activeTasks.clear();
    _totalSyncTasks = 0;
    _completedSyncTasks = 0;
  }

  /// 获取同步进度
  double getSyncProgress() {
    if (_totalSyncTasks == 0) return 1.0;
    return _completedSyncTasks / _totalSyncTasks;
  }

  /// 获取同步状态
  bool get isSyncing => _isSyncing;

  /// 获取队列长度
  int get queueLength => _syncQueue.length;

  /// 获取活跃任务数
  int get activeTaskCount => _activeTasks.length;
}
