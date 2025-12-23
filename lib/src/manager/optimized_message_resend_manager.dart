import 'dart:async';
import 'dart:collection';
import '../common/logs.dart';
import '../proto/packet.dart';
import '../type/const.dart';
import '../wkim.dart';

/// 消息优先级
enum MessagePriority {
  high, // 重要消息，立即重发
  normal, // 普通消息，正常重发
  low, // 低优先级消息，延迟重发
}

/// 优化后的发送中消息类
class OptimizedSendingMsg {
  final SendPacket sendPacket;
  int sendCount = 0;
  int lastSendTime = 0;
  final int createTime;
  bool isCanResend = true;
  final int maxRetryCount;
  final int retryInterval; // 毫秒
  final MessagePriority priority;
  String? failureReason;

  OptimizedSendingMsg(
    this.sendPacket, {
    this.maxRetryCount = 3,
    this.retryInterval = 2000,
    this.priority = MessagePriority.normal,
  }) : createTime = DateTime.now().millisecondsSinceEpoch {
    lastSendTime = createTime;
  }

  /// 是否可以重发
  bool canRetry() {
    if (!isCanResend) return false;
    if (sendCount >= maxRetryCount) return false;

    int now = DateTime.now().millisecondsSinceEpoch;
    return (now - lastSendTime) >= retryInterval;
  }

  /// 准备重发
  void prepareRetry() {
    sendCount++;
    lastSendTime = DateTime.now().millisecondsSinceEpoch;
  }

  /// 是否超时（基于最后一次发送时间）
  bool isTimeout(int timeoutMs) {
    int now = DateTime.now().millisecondsSinceEpoch;
    return (now - lastSendTime) > timeoutMs;
  }

  /// 获取单次发送超时时间
  int getSingleSendTimeout() {
    // 根据优先级设置单次发送超时时间
    switch (priority) {
      case MessagePriority.high:
        return 15000; // 高优先级15秒超时
      case MessagePriority.normal:
        return 20000; // 普通优先级20秒超时
      case MessagePriority.low:
        return 30000; // 低优先级30秒超时
    }
  }

  /// 是否整体超时（基于创建时间，用于最终放弃）
  bool isOverallTimeout() {
    int now = DateTime.now().millisecondsSinceEpoch;
    int maxOverallTime = retryInterval * maxRetryCount + 120000; // 重试时间 + 2分钟缓冲
    return (now - createTime) > maxOverallTime;
  }

  /// 标记为失败
  void markAsFailed(String reason) {
    isCanResend = false;
    failureReason = reason;
  }
}

/// 优化的消息重发管理器
class OptimizedMessageResendManager {
  static final OptimizedMessageResendManager _instance =
      OptimizedMessageResendManager._internal();
  static OptimizedMessageResendManager get shared => _instance;
  OptimizedMessageResendManager._internal();

  final LinkedHashMap<int, OptimizedSendingMsg> _sendingMsgMap =
      LinkedHashMap();

  // 备份队列，防止意外清空
  static LinkedHashMap<int, OptimizedSendingMsg>? _backupQueue;

  // 消息指纹缓存，用于检测重复消息（基于clientMsgNO）
  final Set<String> _messageFingerprints = <String>{};

  Timer? _resendTimer;
  Timer? _cleanupTimer;

  // 配置参数
  static const int defaultTimeoutMs = 120000; // 2分钟超时，给足够时间重试
  static const int resendCheckIntervalMs = 5000; // 5秒检查一次
  static const int cleanupIntervalMs = 60000; // 1分钟清理一次

  // 统计信息
  int _totalSentMessages = 0;
  int _totalResendMessages = 0;
  int _totalFailedMessages = 0;
  int _totalTimeoutMessages = 0;
  int _lastResendTime = 0;

  // 健康监控
  Timer? _healthMonitorTimer;
  int _lastHealthCheckTime = 0;

  bool _isStarted = false;

  /// 启动重发管理器
  void start() {
    if (_isStarted) {
      int currentCount = _sendingMsgMap.length;
      Logs.info('重发管理器已启动，跳过重复启动。当前队列: ${currentCount}条消息');
      return;
    }

    // 检查是否有备份队列需要恢复
    if (_sendingMsgMap.isEmpty &&
        _backupQueue != null &&
        _backupQueue!.isNotEmpty) {
      Logs.warn('检测到空队列但有备份，恢复${_backupQueue!.length}条消息');
      _sendingMsgMap.addAll(_backupQueue!);
      _backupQueue = null;
    }

    int currentCount = _sendingMsgMap.length;
    _startResendTimer();
    _startCleanupTimer();
    _startHealthMonitor();
    _isStarted = true;

    Logs.info('优化消息重发管理器已启动，当前队列: ${currentCount}条消息');

    // 如果有待发送消息，立即输出详情
    if (currentCount > 0) {
      Logs.info('启动时发现待发送消息:');
      _sendingMsgMap.forEach((clientSeq, msg) {
        Logs.info(
            '  - clientSeq: $clientSeq, sendCount: ${msg.sendCount}, priority: ${msg.priority.name}');
      });
    }
  }

  /// 停止重发管理器
  void stop() {
    int currentCount = _sendingMsgMap.length;
    _stopResendTimer();
    _stopCleanupTimer();
    _stopHealthMonitor();
    _isStarted = false;

    if (currentCount > 0) {
      Logs.error('⚠️ 警告：停止重发管理器时清空了${currentCount}条待发送消息！');
      Logs.error('这可能导致消息丢失，请检查调用 stop() 的时机是否正确');
      _sendingMsgMap.forEach((clientSeq, msg) {
        Logs.error(
            '  被清空的消息: clientSeq: $clientSeq, sendCount: ${msg.sendCount}, priority: ${msg.priority.name}');
      });

      // 备份队列，防止消息丢失
      _backupQueue = LinkedHashMap.from(_sendingMsgMap);
      Logs.warn('已备份${currentCount}条消息，下次启动时将尝试恢复');

      // 打印调用栈，帮助定位问题
      Logs.error('调用栈: ${StackTrace.current}');
    }

    _sendingMsgMap.clear();
    _messageFingerprints.clear(); // ⚠️ 重要：清空指纹缓存，避免内存泄漏
    Logs.info('优化消息重发管理器已停止');
  }

  /// 添加发送中的消息
  void addSendingMessage(SendPacket sendPacket, {MessagePriority? priority}) {
    // 检查是否已经存在相同的消息，避免重复添加
    if (_sendingMsgMap.containsKey(sendPacket.clientSeq)) {
      Logs.warn('消息已在重发队列中，跳过重复添加: clientSeq=${sendPacket.clientSeq}');
      return;
    }

    // 基于clientMsgNO检测重复消息
    String fingerprint = sendPacket.clientMsgNO;
    if (_messageFingerprints.contains(fingerprint)) {
      Logs.error(
          '检测到重复消息！clientMsgNO=$fingerprint, clientSeq=${sendPacket.clientSeq}');
      Logs.error('这可能是导致消息重复发送的原因，已拦截');
      return;
    }

    // 如果没有指定优先级，使用智能判断
    priority ??= _determineSmartPriority(sendPacket);

    int retryInterval = _getRetryInterval(priority);
    int maxRetryCount = _getMaxRetryCount(priority);

    OptimizedSendingMsg sendingMsg = OptimizedSendingMsg(
      sendPacket,
      maxRetryCount: maxRetryCount,
      retryInterval: retryInterval,
      priority: priority,
    );

    _sendingMsgMap[sendPacket.clientSeq] = sendingMsg;
    _messageFingerprints.add(fingerprint);
    _totalSentMessages++;

    // 动态调整重试策略
    _adjustRetryStrategy();

    bool isConnected = !WKIM.shared.connectionManager.isDisconnection;
    Logs.info(
        '添加发送中消息: clientSeq=${sendPacket.clientSeq}, clientMsgNO=$fingerprint, priority=${priority.name}, '
        '连接状态=${isConnected ? "已连接" : "已断开"}, 队列总数=${_sendingMsgMap.length}, '
        '连接健康度=${getConnectionHealthScore()}');

    // 注意：超时检查由定时器统一处理，不在这里单独添加
    // 避免每条消息都创建独立的Timer导致重复触发
  }

  /// 处理发送确认
  void handleSendAck(int clientSeq, int reasonCode) {
    OptimizedSendingMsg? sendingMsg = _sendingMsgMap[clientSeq];
    if (sendingMsg == null) {
      return;
    }

    if (reasonCode == WKSendMsgResult.sendSuccess) {
      // 发送成功，移除消息和指纹
      _sendingMsgMap.remove(clientSeq);
      _messageFingerprints.remove(sendingMsg.sendPacket.clientMsgNO);
      Logs.debug(
          '消息发送成功: clientSeq=$clientSeq, clientMsgNO=${sendingMsg.sendPacket.clientMsgNO}, 优先级=${sendingMsg.priority.name}');
    } else {
      // 发送失败，使用增强的错误处理
      if (_shouldRetryEnhanced(reasonCode) &&
          sendingMsg.sendCount < sendingMsg.maxRetryCount) {
        Logs.warn('消息发送失败，准备重试: clientSeq=$clientSeq, reasonCode=$reasonCode, '
            '优先级=${sendingMsg.priority.name}, 第${sendingMsg.sendCount + 1}次重试');

        // 客服场景：对于高优先级消息，缩短重试间隔
        if (sendingMsg.priority == MessagePriority.high &&
            reasonCode == WKSendMsgResult.sendFail) {
          // 网络错误时，高优先级消息立即重试
          sendingMsg.lastSendTime =
              DateTime.now().millisecondsSinceEpoch - sendingMsg.retryInterval;
        }

        // 保持在重发队列中，等待下次重发
      } else {
        // 不应重试或超过重试次数，标记为失败并清理
        String failReason = _getFailureReason(reasonCode);
        sendingMsg.markAsFailed('发送失败: $failReason');
        _sendingMsgMap.remove(clientSeq);
        _messageFingerprints.remove(sendingMsg.sendPacket.clientMsgNO);
        _totalFailedMessages++;

        Logs.error(
            '消息发送最终失败: clientSeq=$clientSeq, clientMsgNO=${sendingMsg.sendPacket.clientMsgNO}, reasonCode=$reasonCode, '
            '失败原因=$failReason, 优先级=${sendingMsg.priority.name}, '
            '重试次数=${sendingMsg.sendCount}/${sendingMsg.maxRetryCount}');
      }
    }
  }

  /// 获取失败原因描述
  String _getFailureReason(int reasonCode) {
    switch (reasonCode) {
      case WKSendMsgResult.sendFail:
        return '网络发送失败';
      case WKSendMsgResult.notOnWhiteList:
        return '不在白名单中';
      case WKSendMsgResult.noRelation:
        return '无关系权限';
      default:
        return '未知错误($reasonCode)';
    }
  }

  /// 启动重发定时器
  void _startResendTimer() {
    _stopResendTimer();
    _resendTimer = Timer.periodic(
        const Duration(milliseconds: resendCheckIntervalMs), (timer) {
      _checkAndResendMessages();
    });
  }

  void _stopResendTimer() {
    _resendTimer?.cancel();
    _resendTimer = null;
  }

  /// 启动清理定时器
  void _startCleanupTimer() {
    _stopCleanupTimer();
    _cleanupTimer = Timer.periodic(
        const Duration(milliseconds: cleanupIntervalMs), (timer) {
      _cleanupExpiredMessages();
    });
  }

  void _stopCleanupTimer() {
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
  }

  /// 启动健康监控
  void _startHealthMonitor() {
    _stopHealthMonitor();
    _healthMonitorTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
      _performHealthCheck();
    });
  }

  void _stopHealthMonitor() {
    _healthMonitorTimer?.cancel();
    _healthMonitorTimer = null;
  }

  /// 执行健康检查
  void _performHealthCheck() {
    int now = DateTime.now().millisecondsSinceEpoch;
    _lastHealthCheckTime = now;

    int healthScore = getConnectionHealthScore();
    int pendingCount = _sendingMsgMap.length;

    // 健康度过低时的处理
    if (healthScore < 30) {
      Logs.warn('消息队列健康度过低: $healthScore/100, 待发送消息: $pendingCount条');

      // 如果有大量消息积压且连接不稳定，考虑清理部分低优先级消息
      if (pendingCount > 50) {
        _cleanupLowPriorityMessages();
      }
    }

    // 积压消息过多时的处理
    if (pendingCount > 100) {
      Logs.error('消息积压严重: $pendingCount条，可能需要人工干预');
      // 可以触发告警或特殊处理
    }

    // 定期输出健康报告
    if (pendingCount > 0) {
      Logs.info('消息队列健康报告: 健康度=$healthScore/100, '
          '待发送=$pendingCount条, 成功率=${_getSuccessRate()}%');
    }
  }

  /// 清理低优先级消息（紧急情况下）
  void _cleanupLowPriorityMessages() {
    List<int> toRemove = [];
    int cleanupCount = 0;

    _sendingMsgMap.forEach((clientSeq, msg) {
      if (msg.priority == MessagePriority.low &&
          msg.sendCount >= 2 && // 已经重试过的低优先级消息
          cleanupCount < 20) {
        // 最多清理20条
        toRemove.add(clientSeq);
        cleanupCount++;
      }
    });

    for (int clientSeq in toRemove) {
      OptimizedSendingMsg msg = _sendingMsgMap.remove(clientSeq)!;
      _messageFingerprints.remove(msg.sendPacket.clientMsgNO); // 清理指纹
      msg.markAsFailed('健康检查清理');
      _totalFailedMessages++;
    }

    if (cleanupCount > 0) {
      Logs.warn('健康检查清理了${cleanupCount}条低优先级消息');
    }
  }

  /// 获取成功率
  double _getSuccessRate() {
    if (_totalSentMessages == 0) return 100.0;
    double successCount =
        (_totalSentMessages - _totalFailedMessages - _totalTimeoutMessages)
            .toDouble();
    return (successCount / _totalSentMessages * 100);
  }

  /// 检查并重发消息
  Future<void> _checkAndResendMessages() async {
    if (_sendingMsgMap.isEmpty) return;

    // 简化连接状态检查，只检查基本连接状态
    if (WKIM.shared.connectionManager.isDisconnection) {
      Logs.debug('连接已断开，跳过重发检查');
      return;
    }

    List<OptimizedSendingMsg> toResend = [];
    List<int> toTimeout = [];

    try {
      // 分类处理消息
      _sendingMsgMap.forEach((clientSeq, sendingMsg) {
        // 检查是否整体超时（从创建时间算起，用于最终放弃）
        if (sendingMsg.isOverallTimeout()) {
          toTimeout.add(clientSeq);
        }
        // 检查单次发送是否超时（从最后发送时间算起）
        else if (sendingMsg.isTimeout(sendingMsg.getSingleSendTimeout())) {
          // 单次发送超时，但还没到整体超时，可以重试
          if (sendingMsg.canRetry()) {
            toResend.add(sendingMsg);
          } else {
            // 重试次数已达上限
            toTimeout.add(clientSeq);
          }
        }
        // 检查是否可以按间隔重试
        else if (sendingMsg.canRetry()) {
          toResend.add(sendingMsg);
        }
      });
    } catch (e) {
      Logs.error('检查重发消息时出错: $e');
      return;
    }

    // 处理超时消息
    for (int clientSeq in toTimeout) {
      OptimizedSendingMsg sendingMsg = _sendingMsgMap.remove(clientSeq)!;
      _messageFingerprints.remove(sendingMsg.sendPacket.clientMsgNO);

      int now = DateTime.now().millisecondsSinceEpoch;
      int totalTime = now - sendingMsg.createTime;
      int lastSendTime = now - sendingMsg.lastSendTime;
      int singleTimeout = sendingMsg.getSingleSendTimeout();

      String timeoutReason = sendingMsg.isOverallTimeout() ? '整体超时' : '重试次数达上限';

      sendingMsg.markAsFailed('发送超时: $timeoutReason');
      _totalTimeoutMessages++;
      Logs.warn(
          '消息发送超时: clientSeq=$clientSeq, clientMsgNO=${sendingMsg.sendPacket.clientMsgNO}, '
          '总耗时=${totalTime}ms, 距上次发送=${lastSendTime}ms, '
          '单次超时阈值=${singleTimeout}ms, '
          '重试次数=${sendingMsg.sendCount}/${sendingMsg.maxRetryCount}, '
          '超时原因=$timeoutReason');
    }

    // 按优先级重发消息，但限制每次重发的数量
    if (toResend.isNotEmpty) {
      // 限制每次最多重发5条消息，避免网络拥塞
      List<OptimizedSendingMsg> limitedResend = toResend.take(5).toList();
      await _resendMessagesByPriority(limitedResend);
    }
  }

  /// 按优先级重发消息
  Future<void> _resendMessagesByPriority(
      List<OptimizedSendingMsg> messages) async {
    // 按优先级分组
    Map<MessagePriority, List<OptimizedSendingMsg>> priorityGroups = {
      MessagePriority.high: [],
      MessagePriority.normal: [],
      MessagePriority.low: [],
    };

    for (OptimizedSendingMsg msg in messages) {
      priorityGroups[msg.priority]!.add(msg);
    }

    // 按优先级顺序重发
    for (MessagePriority priority in MessagePriority.values) {
      List<OptimizedSendingMsg> priorityMessages = priorityGroups[priority]!;
      if (priorityMessages.isEmpty) continue;

      Logs.debug('开始重发${priority.name}优先级消息: ${priorityMessages.length}条');

      for (int i = 0; i < priorityMessages.length; i++) {
        OptimizedSendingMsg sendingMsg = priorityMessages[i];

        // 简化连接状态检查
        if (WKIM.shared.connectionManager.isDisconnection) {
          Logs.warn('连接已断开，停止重发');
          return;
        }

        try {
          sendingMsg.prepareRetry();

          // 检查连接状态
          bool isConnected = !WKIM.shared.connectionManager.isDisconnection;
          Logs.info('准备重发消息: clientSeq=${sendingMsg.sendPacket.clientSeq}, '
              '第${sendingMsg.sendCount}次, 优先级=${priority.name}, '
              '连接状态=${isConnected ? "已连接" : "已断开"}');

          // 发送消息
          await WKIM.shared.connectionManager.sendPacket(sendingMsg.sendPacket);
          _totalResendMessages++;

          int timeSinceLastSend =
              DateTime.now().millisecondsSinceEpoch - sendingMsg.lastSendTime;
          Logs.info('重发消息完成: clientSeq=${sendingMsg.sendPacket.clientSeq}, '
              '第${sendingMsg.sendCount}次, 优先级=${priority.name}, '
              '距上次发送=${timeSinceLastSend}ms');

          // 所有消息之间都添加适当延迟，避免网络拥塞
          int delay = _getResendDelay(priority, i, priorityMessages.length);
          if (delay > 0) {
            await Future.delayed(Duration(milliseconds: delay));
          }
        } catch (e) {
          Logs.error(
              '重发消息失败: clientSeq=${sendingMsg.sendPacket.clientSeq}, error: $e');

          // 重发失败，检查是否超过重试次数
          if (sendingMsg.sendCount >= sendingMsg.maxRetryCount) {
            sendingMsg.markAsFailed('重发次数超限: $e');
            _sendingMsgMap.remove(sendingMsg.sendPacket.clientSeq);
            _totalFailedMessages++;
          }
        }
      }

      // 不同优先级之间添加更长延迟
      if (priority != MessagePriority.low) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
  }

  /// 获取重发延迟时间
  int _getResendDelay(MessagePriority priority, int index, int totalCount) {
    switch (priority) {
      case MessagePriority.high:
        return 50; // 高优先级消息间隔50ms
      case MessagePriority.normal:
        return 100; // 普通优先级消息间隔100ms
      case MessagePriority.low:
        return 200; // 低优先级消息间隔200ms
    }
  }

  /// 清理过期消息
  void _cleanupExpiredMessages() {
    List<int> toRemove = [];

    _sendingMsgMap.forEach((clientSeq, sendingMsg) {
      if (!sendingMsg.isCanResend) {
        toRemove.add(clientSeq);
      }
    });

    for (int clientSeq in toRemove) {
      OptimizedSendingMsg? msg = _sendingMsgMap.remove(clientSeq);
      if (msg != null) {
        _messageFingerprints.remove(msg.sendPacket.clientMsgNO); // 清理指纹
      }
    }

    if (toRemove.isNotEmpty) {
      Logs.debug('清理过期消息: ${toRemove.length}条');
    }
  }

  /// 获取重试间隔（客服场景优化）
  int _getRetryInterval(MessagePriority priority) {
    // 简化重试间隔，更快重发
    switch (priority) {
      case MessagePriority.high:
        return 1000; // 高优先级1秒
      case MessagePriority.normal:
        return 2000; // 普通优先级2秒
      case MessagePriority.low:
        return 3000; // 低优先级3秒
    }
  }

  /// 获取最大重试次数（客服场景优化）
  int _getMaxRetryCount(MessagePriority priority) {
    switch (priority) {
      case MessagePriority.high:
        return 10; // 客服高优先级消息必须送达，增加到10次
      case MessagePriority.normal:
        return 7; // 普通优先级7次
      case MessagePriority.low:
        return 5; // 低优先级5次
    }
  }

  /// 手动重发所有消息
  Future<void> resendAllMessages() async {
    List<OptimizedSendingMsg> allMessages = _sendingMsgMap.values.toList();
    if (allMessages.isNotEmpty) {
      Logs.info('手动重发所有消息: ${allMessages.length}条');

      // 缩短延迟时间
      await Future.delayed(const Duration(milliseconds: 500));

      // 简化连接检查，更积极地重发
      if (WKIM.shared.connectionManager.isDisconnection) {
        Logs.warn('连接已断开，但仍尝试重发（可能刚恢复连接）');
        // 不直接返回，继续尝试重发
      }

      // 直接重发，不分批（提高重发速度）
      await _directResendMessages(allMessages);
    }
  }

  /// 直接重发消息（不分批，更快速）
  Future<void> _directResendMessages(List<OptimizedSendingMsg> messages) async {
    Logs.info('开始直接重发${messages.length}条消息');

    for (int i = 0; i < messages.length; i++) {
      OptimizedSendingMsg sendingMsg = messages[i];

      try {
        sendingMsg.prepareRetry();
        await WKIM.shared.connectionManager.sendPacket(sendingMsg.sendPacket);
        _totalResendMessages++;

        Logs.info('直接重发消息: clientSeq=${sendingMsg.sendPacket.clientSeq}, '
            '第${sendingMsg.sendCount}次');

        // 减少延迟，加快重发速度
        if (i < messages.length - 1) {
          await Future.delayed(const Duration(milliseconds: 50));
        }
      } catch (e) {
        Logs.error(
            '直接重发失败: clientSeq=${sendingMsg.sendPacket.clientSeq}, error: $e');

        // 重发失败，检查是否超过重试次数
        if (sendingMsg.sendCount >= sendingMsg.maxRetryCount) {
          sendingMsg.markAsFailed('重发次数超限: $e');
          _sendingMsgMap.remove(sendingMsg.sendPacket.clientSeq);
          _totalFailedMessages++;
        }
      }
    }

    Logs.info('直接重发完成');
  }

  /// 获取所有发送中的消息
  List<Map<String, dynamic>> getAllSendingMessages() {
    return _sendingMsgMap.values
        .map((msg) => {
              'clientSeq': msg.sendPacket.clientSeq,
              'sendCount': msg.sendCount,
              'priority': msg.priority.name,
              'canRetry': msg.canRetry(),
              'createTime': msg.createTime,
              'lastSendTime': msg.lastSendTime,
            })
        .toList();
  }

  /// 获取统计信息
  Map<String, dynamic> getStatistics() {
    // 计算当前发送中消息的等待时间统计
    int now = DateTime.now().millisecondsSinceEpoch;
    int totalWaitTime = 0;
    int maxWaitTime = 0;
    int totalLastSendTime = 0;
    int maxLastSendTime = 0;
    int pendingTimeoutCount = 0;

    for (var msg in _sendingMsgMap.values) {
      int waitTime = now - msg.createTime;
      int lastSendTime = now - msg.lastSendTime;

      totalWaitTime += waitTime;
      totalLastSendTime += lastSendTime;

      if (waitTime > maxWaitTime) {
        maxWaitTime = waitTime;
      }
      if (lastSendTime > maxLastSendTime) {
        maxLastSendTime = lastSendTime;
      }

      // 检查是否接近单次发送超时
      if (lastSendTime > msg.getSingleSendTimeout() * 0.8) {
        pendingTimeoutCount++;
      }
    }

    double avgWaitTime =
        _sendingMsgMap.isNotEmpty ? totalWaitTime / _sendingMsgMap.length : 0;
    double avgLastSendTime = _sendingMsgMap.isNotEmpty
        ? totalLastSendTime / _sendingMsgMap.length
        : 0;

    return {
      'totalSentMessages': _totalSentMessages,
      'totalResendMessages': _totalResendMessages,
      'totalFailedMessages': _totalFailedMessages,
      'totalTimeoutMessages': _totalTimeoutMessages,
      'currentSendingCount': _sendingMsgMap.length,
      'lastResendTime': _lastResendTime,
      'avgWaitTimeMs': avgWaitTime.round(),
      'maxWaitTimeMs': maxWaitTime,
      'avgLastSendTimeMs': avgLastSendTime.round(),
      'maxLastSendTimeMs': maxLastSendTime,
      'pendingTimeoutCount': pendingTimeoutCount,
      'lastHealthCheckTime': _lastHealthCheckTime,
      'connectionHealthScore': getConnectionHealthScore(),
      'successRate': _totalSentMessages > 0
          ? '${((_totalSentMessages - _totalFailedMessages - _totalTimeoutMessages) / _totalSentMessages * 100).toStringAsFixed(2)}%'
          : '0%',
    };
  }

  /// 智能确定消息优先级（客服场景优化）
  MessagePriority _determineSmartPriority(SendPacket packet) {
    // 基于消息内容智能判断优先级
    try {
      // 这里可以根据消息内容、频道类型等判断
      // 客服消息通常需要高优先级
      if (packet.channelType == 1) {
        // 假设1是客服频道
        return MessagePriority.high;
      }

      // 可以根据消息大小判断
      if (packet.payload.length < 1000) {
        // 小消息优先
        return MessagePriority.high;
      }

      return MessagePriority.normal;
    } catch (e) {
      return MessagePriority.normal;
    }
  }

  /// 增强的错误码处理（客服场景）
  bool _shouldRetryEnhanced(int reasonCode) {
    switch (reasonCode) {
      case WKSendMsgResult.sendFail:
        return true; // 网络错误，必须重试
      case WKSendMsgResult.notOnWhiteList:
        return false; // 权限问题，不重试
      case WKSendMsgResult.noRelation:
        return false; // 关系问题，不重试

      // 客服场景特殊处理
      case 1001: // 假设这是服务器繁忙
        return true; // 服务器繁忙时应该重试
      case 1002: // 假设这是临时错误
        return true;

      default:
        // 未知错误码，客服场景下倾向于重试
        Logs.warn('未知错误码: $reasonCode， 重试');
        return true;
    }
  }

  /// 动态调整重试策略（基于网络状况）
  void _adjustRetryStrategy() {
    double failureRate = _totalSentMessages > 0
        ? (_totalFailedMessages + _totalTimeoutMessages) / _totalSentMessages
        : 0;

    if (failureRate > 0.3) {
      // 失败率超过30%
      Logs.warn('消息失败率过高: ${(failureRate * 100).toStringAsFixed(1)}%，调整重试策略');
      // 可以动态调整重试间隔和次数
    }
  }

  /// 紧急重发（客服场景的紧急消息）
  Future<void> emergencyResend(int clientSeq) async {
    OptimizedSendingMsg? msg = _sendingMsgMap[clientSeq];
    if (msg == null) return;

    if (WKIM.shared.connectionManager.isDisconnection) {
      Logs.warn('连接已断开，无法紧急重发');
      return;
    }

    try {
      // 紧急重发不受重试间隔限制
      msg.prepareRetry();
      await WKIM.shared.connectionManager.sendPacket(msg.sendPacket);
      _totalResendMessages++;

      Logs.info('紧急重发消息: clientSeq=$clientSeq');
    } catch (e) {
      Logs.error('紧急重发失败: $e');
    }
  }

  /// 获取发送中消息数量
  int getSendingMessageCount() {
    return _sendingMsgMap.length;
  }

  /// 强制重发所有消息（绕过连接检查，用于调试）
  Future<void> forceResendAllMessages() async {
    List<OptimizedSendingMsg> allMessages = _sendingMsgMap.values.toList();
    if (allMessages.isNotEmpty) {
      Logs.warn('强制重发所有消息: ${allMessages.length}条 (绕过连接检查)');

      for (var msg in allMessages) {
        try {
          msg.prepareRetry();
          await WKIM.shared.connectionManager.sendPacket(msg.sendPacket);
          _totalResendMessages++;

          Logs.info('强制重发: clientSeq=${msg.sendPacket.clientSeq}, '
              '第${msg.sendCount}次');

          // 添加小延迟避免发送过快
          await Future.delayed(const Duration(milliseconds: 100));
        } catch (e) {
          Logs.error(
              '强制重发失败: clientSeq=${msg.sendPacket.clientSeq}, error: $e');
        }
      }
    } else {
      Logs.info('强制重发: 无待发送消息');
    }
  }

  /// 获取连接健康度评分（0-100）
  int getConnectionHealthScore() {
    if (WKIM.shared.connectionManager.isDisconnection) {
      return 0;
    }

    int score = 100;

    // 心跳健康度
    int pongCount = WKIM.shared.connectionManager.unReceivePongCount;
    score -= pongCount * 20; // 每次未响应扣20分

    // 消息成功率
    if (_totalSentMessages > 0) {
      double successRate =
          (_totalSentMessages - _totalFailedMessages - _totalTimeoutMessages) /
              _totalSentMessages;
      score = (score * successRate).round();
    }

    // 当前积压消息数量
    if (_sendingMsgMap.length > 10) {
      score -= (_sendingMsgMap.length - 10) * 2; // 超过10条消息每条扣2分
    }

    return score.clamp(0, 100);
  }
}
