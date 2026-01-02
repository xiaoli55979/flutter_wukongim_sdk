import 'dart:async';
import 'dart:math';

import 'package:connectivity_plus/connectivity_plus.dart';

import '../common/logs.dart';
import '../type/const.dart';
import '../wkim.dart';
import 'optimized_message_resend_manager.dart';

/// 智能重连管理器
class ReconnectManager {
  static final ReconnectManager _instance = ReconnectManager._internal();
  static ReconnectManager get shared => _instance;
  ReconnectManager._internal() {
    // 初始化时立即检查网络状态
    _initializeNetworkStatus();
  }

  Timer? _reconnectTimer;
  Timer? _networkCheckTimer;
  Timer? _connectTimeoutTimer;
  int _currentRetryCount = 0;
  bool _isReconnecting = false;
  bool _isNetworkAvailable = true;
  ConnectivityResult? _lastConnectivityResult;
  final Connectivity _connectivity = Connectivity();

  /// 重连策略：指数退避算法
  int _calculateRetryDelay() {
    final config = WKIM.shared.options.networkConfig;
    final delay = min(
            config.baseRetryInterval *
                pow(config.retryBackoffMultiplier, _currentRetryCount),
            config.maxRetryInterval.toDouble())
        .toInt();

    // 添加随机抖动，避免大量客户端同时重连
    final jitter = Random().nextInt(1000);
    return delay + jitter;
  }

  /// 开始重连
  void startReconnect() {
    if (_isReconnecting) {
      Logs.connection('重连已在进行中，跳过');
      return;
    }

    // 检查是否已登出（uid/token为空），如果是则不启动重连
    if (WKIM.shared.options.uid == null ||
        WKIM.shared.options.uid == "" ||
        WKIM.shared.options.token == null ||
        WKIM.shared.options.token == "") {
      Logs.connection('检测到uid或token为空，可能是登出状态，不启动重连');
      return;
    }

    final config = WKIM.shared.options.networkConfig;

    // 如果有多个地址，减少单个地址的重试次数
    int maxRetryCount = config.maxRetryCount;
    if (WKIM.shared.options.addrs.isNotEmpty &&
        WKIM.shared.options.addrs.length > 1) {
      maxRetryCount = (config.maxRetryCount / 2).ceil(); // 减少到一半
      Logs.connection('检测到多地址配置，减少单地址重试次数到: $maxRetryCount');
    }

    if (_currentRetryCount >= maxRetryCount) {
      Logs.error('达到最大重连次数 $maxRetryCount，停止重连');
      _notifyReconnectFailed();
      return;
    }

    _isReconnecting = true;
    final delay = _calculateRetryDelay();

    Logs.connection('开始第 ${_currentRetryCount + 1} 次重连，延迟 ${delay}ms');

    _reconnectTimer = Timer(Duration(milliseconds: delay), () {
      _performReconnect();
    });
  }

  /// 执行重连
  void _performReconnect() async {
    if (!_isNetworkAvailable) {
      Logs.connection('网络不可用，暂停重连');
      _isReconnecting = false;
      return;
    }

    // 检查是否已登出（uid/token为空），如果是则停止重连
    if (WKIM.shared.options.uid == null ||
        WKIM.shared.options.uid == "" ||
        WKIM.shared.options.token == null ||
        WKIM.shared.options.token == "") {
      Logs.connection('检测到uid或token为空，可能是登出状态，停止重连');
      _isReconnecting = false;
      _currentRetryCount = 0;
      return;
    }

    _currentRetryCount++;
    Logs.connection('执行第 $_currentRetryCount 次重连');

    try {
      // 检查当前连接状态，如果已经连接成功就不要重连
      if (!WKIM.shared.connectionManager.isDisconnection) {
        Logs.connection('当前连接正常，取消重连');
        _isReconnecting = false;
        _currentRetryCount = 0;
        return;
      }

      // 先确保断开现有连接，避免连接冲突
      WKIM.shared.connectionManager.disconnect(false);

      // 等待更长时间确保连接完全断开和资源释放
      await Future.delayed(Duration(milliseconds: 1500));

      // 再次检查网络状态
      bool networkCheck = await checkNetworkStatusNow();
      if (!networkCheck) {
        Logs.connection('重连前网络检查失败，暂停重连');
        _isReconnecting = false;
        return;
      }

      // 执行连接
      Logs.connection('开始执行重连...');
      WKIM.shared.connectionManager.connect();

      // 设置连接超时检查
      _connectTimeoutTimer = Timer(
          Duration(
              seconds: WKIM.shared.options.networkConfig.connectTimeout +
                  10), // 增加到10秒缓冲
          () {
        if (_isReconnecting) {
          Logs.connection('连接超时，准备下次重连');
          _isReconnecting = false;

          // 强制断开可能的半连接状态
          WKIM.shared.connectionManager.disconnect(false);

          // 添加更长延迟避免频繁重试
          Timer(const Duration(seconds: 5), () {
            if (WKIM.shared.connectionManager.isDisconnection) {
              startReconnect();
            }
          });
        }
      });
    } catch (e) {
      Logs.error('重连失败: $e');
      _isReconnecting = false;

      // 确保连接状态正确
      WKIM.shared.connectionManager.disconnect(false);

      // 添加延迟避免立即重试
      Timer(Duration(seconds: 5), () {
        if (WKIM.shared.connectionManager.isDisconnection) {
          startReconnect();
        }
      });
    }
  }

  /// 连接成功回调
  void onConnectSuccess() {
    Logs.connection('连接成功，重置重连状态');
    _currentRetryCount = 0;
    _isReconnecting = false;
    _stopReconnectTimer();

    // 取消连接超时检查
    _connectTimeoutTimer?.cancel();
    _connectTimeoutTimer = null;

    // 重连成功后，立即触发消息重发（减少延迟）
    Timer(const Duration(milliseconds: 500), () {
      _triggerMessageResend();
    });
  }

  /// 触发消息重发
  void _triggerMessageResend() {
    try {
      // 检查连接状态
      if (WKIM.shared.connectionManager.isDisconnection) {
        Logs.warn('连接已断开，跳过消息重发');
        return;
      }

      // 获取待重发消息数量
      int pendingCount =
          OptimizedMessageResendManager.shared.getSendingMessageCount();
      if (pendingCount > 0) {
        Logs.info('重连成功，开始重发待发送消息: $pendingCount条');

        // 获取重发前的统计信息
        var statsBefore = OptimizedMessageResendManager.shared.getStatistics();
        Logs.debug('重发前统计: $statsBefore');

        OptimizedMessageResendManager.shared.resendAllMessages();

        // 延迟检查重发结果
        Timer(const Duration(seconds: 10), () {
          _checkResendResult(pendingCount);
        });
      } else {
        Logs.debug('重连成功，无待重发消息');
      }
    } catch (e) {
      Logs.error('触发消息重发失败: $e');
    }
  }

  /// 检查重发结果
  void _checkResendResult(int originalPendingCount) {
    try {
      int currentPendingCount =
          OptimizedMessageResendManager.shared.getSendingMessageCount();
      var stats = OptimizedMessageResendManager.shared.getStatistics();

      if (currentPendingCount < originalPendingCount) {
        Logs.info(
            '消息重发进展: 原有${originalPendingCount}条，当前${currentPendingCount}条，'
            '成功率: ${stats['successRate']}');
      } else if (currentPendingCount == originalPendingCount) {
        Logs.warn('消息重发可能未执行: 待发送消息数量未变化 ($currentPendingCount条)');
        // 可以考虑再次触发重发
      }

      Logs.debug('重发后统计: $stats');
    } catch (e) {
      Logs.error('检查重发结果失败: $e');
    }
  }

  /// 连接失败回调
  void onConnectFailed() {
    // 检查是否已登出（uid/token为空），如果是则不启动重连
    if (WKIM.shared.options.uid == null ||
        WKIM.shared.options.uid == "" ||
        WKIM.shared.options.token == null ||
        WKIM.shared.options.token == "") {
      Logs.connection('检测到uid或token为空，可能是登出状态，不启动重连');
      return;
    }

    if (!_isReconnecting) {
      startReconnect();
    }
  }

  /// 停止重连
  void stopReconnect() {
    Logs.connection('停止重连');
    _isReconnecting = false;
    _currentRetryCount = 0;
    _stopReconnectTimer();
  }

  /// 重置重连状态
  void reset() {
    stopReconnect();
    _isNetworkAvailable = true;
    _lastConnectivityResult = null;
  }

  /// 强制重置连接状态（用于首次连接失败后的完全重置）
  void forceReset() {
    Logs.connection('强制重置连接状态');

    // 停止所有定时器
    _stopReconnectTimer();
    _stopNetworkMonitoring();

    // 重置所有状态
    _isReconnecting = false;
    _currentRetryCount = 0;
    _isNetworkAvailable = true;
    _lastConnectivityResult = null;

    // 强制断开连接
    WKIM.shared.connectionManager.disconnect(false);

    Logs.connection('连接状态强制重置完成');
  }

  void _stopReconnectTimer() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    // 同时取消连接超时检查
    _connectTimeoutTimer?.cancel();
    _connectTimeoutTimer = null;
  }

  /// 开始网络监控
  void startNetworkMonitoring() {
    _stopNetworkMonitoring();

    final interval = WKIM.shared.options.networkConfig.networkCheckInterval;
    _networkCheckTimer = Timer.periodic(Duration(seconds: interval), (timer) {
      _checkNetworkStatus();
    });
  }

  /// 停止网络监控
  void stopNetworkMonitoring() {
    _stopNetworkMonitoring();
  }

  void _stopNetworkMonitoring() {
    _networkCheckTimer?.cancel();
    _networkCheckTimer = null;
  }

  /// 检查网络状态
  void _checkNetworkStatus() async {
    try {
      final connectivityResults = await _connectivity.checkConnectivity();
      final isNetworkAvailable =
          !connectivityResults.contains(ConnectivityResult.none);

      if (_isNetworkAvailable != isNetworkAvailable) {
        _isNetworkAvailable = isNetworkAvailable;

        if (isNetworkAvailable) {
          Logs.connection('网络已恢复');

          // 检查是否已登出（uid/token为空），如果是则不启动重连
          if (WKIM.shared.options.uid == null ||
              WKIM.shared.options.uid == "" ||
              WKIM.shared.options.token == null ||
              WKIM.shared.options.token == "") {
            Logs.connection('检测到uid或token为空，可能是登出状态，跳过网络恢复重连');
            return;
          }

          // 检查当前连接状态，如果已经连接成功就不要重连
          if (!WKIM.shared.connectionManager.isDisconnection) {
            Logs.info('当前连接正常，跳过网络恢复重连');
            return;
          }

          WKIM.shared.connectionManager
              .setConnectionStatus(WKConnectStatus.connecting);
          // 网络恢复后直接尝试连接，不走重连流程
          if (!_isReconnecting) {
            _currentRetryCount = 0; // 重置重连次数
            Timer(const Duration(seconds: 3), () {
              // 减少到3秒，网络恢复后应该快速尝试连接
              if (_isNetworkAvailable &&
                  !_isReconnecting &&
                  WKIM.shared.connectionManager.isDisconnection) {
                Logs.connection('网络恢复，直接尝试连接');
                WKIM.shared.connectionManager.connect();
              }
            });
          }
        } else {
          Logs.connection('网络已断开');
          WKIM.shared.connectionManager
              .setConnectionStatus(WKConnectStatus.noNetwork);
          stopReconnect();
        }
      }

      // 检查网络类型变化
      if (connectivityResults.isNotEmpty) {
        final currentResult = connectivityResults.first;
        if (_lastConnectivityResult != null &&
            _lastConnectivityResult != currentResult &&
            isNetworkAvailable) {
          Logs.connection(
              '网络类型发生变化: $_lastConnectivityResult -> $currentResult');
          // 网络类型变化时重新连接
          WKIM.shared.connectionManager.disconnect(false);
          Timer(const Duration(milliseconds: 500), () {
            startReconnect();
          });
        }
        _lastConnectivityResult = currentResult;
      }
    } catch (e) {
      Logs.error('网络状态检查失败: $e');
    }
  }

  /// 通知重连失败
  void _notifyReconnectFailed() {
    WKIM.shared.connectionManager.setConnectionStatus(WKConnectStatus.fail);
  }

  /// 获取当前重连状态
  bool get isReconnecting => _isReconnecting;

  /// 获取当前重连次数
  int get currentRetryCount => _currentRetryCount;

  /// 获取网络可用状态
  bool get isNetworkAvailable => _isNetworkAvailable;

  /// 手动触发消息重发
  void manualTriggerResend() {
    Logs.info('手动触发消息重发');
    _triggerMessageResend();
  }

  /// 强制重发所有消息
  void forceResendAllMessages() {
    Logs.warn('强制重发所有消息');
    OptimizedMessageResendManager.shared.forceResendAllMessages();
  }

  /// 调试：打印重发队列状态
  void debugPrintResendQueue() {
    try {
      int pendingCount =
          OptimizedMessageResendManager.shared.getSendingMessageCount();
      var stats = OptimizedMessageResendManager.shared.getStatistics();
      var allMessages =
          OptimizedMessageResendManager.shared.getAllSendingMessages();

      Logs.info('=== 重发队列调试信息 ===');
      Logs.info('待发送消息数量: $pendingCount');
      Logs.info('统计信息: $stats');
      Logs.info(
          '连接状态: isDisconnection=${WKIM.shared.connectionManager.isDisconnection}');

      if (allMessages.isNotEmpty) {
        Logs.info('消息详情:');
        for (var msg in allMessages.take(5)) {
          // 只显示前5条
          Logs.info('  - clientSeq: ${msg['clientSeq']}, '
              'sendCount: ${msg['sendCount']}, '
              'priority: ${msg['priority']}, '
              'canRetry: ${msg['canRetry']}');
        }
      }
      Logs.info('========================');
    } catch (e) {
      Logs.error('调试重发队列失败: $e');
    }
  }

  /// 强制设置网络可用状态（用于调试或特殊情况）
  void forceNetworkAvailable(bool available) {
    _isNetworkAvailable = available;
    Logs.connection('强制设置网络状态: ${available ? "可用" : "不可用"}');
  }

  /// 初始化网络状态
  void _initializeNetworkStatus() {
    checkNetworkStatusNow().then((isAvailable) {
      Logs.connection('初始化网络状态: ${isAvailable ? "可用" : "不可用"}');
    }).catchError((e) {
      Logs.error('初始化网络状态失败: $e');
    });
  }

  /// 立即检查网络状态（异步方法）
  Future<bool> checkNetworkStatusNow() async {
    try {
      final connectivityResults = await _connectivity.checkConnectivity();
      final isAvailable =
          !connectivityResults.contains(ConnectivityResult.none);

      // 更新内部状态
      _isNetworkAvailable = isAvailable;

      Logs.connection(
          '实时网络检查结果: ${isAvailable ? "可用" : "不可用"}, 类型: $connectivityResults');
      return isAvailable;
    } catch (e) {
      Logs.error('connectivity_plus检查失败: $e，尝试备用检查方法');

      // 备用检查：尝试简单的网络连接测试
      try {
        // 这里可以添加其他网络检查方法，比如ping测试
        // 暂时假设网络可用，让实际连接来验证
        _isNetworkAvailable = true;
        Logs.connection('备用网络检查：假设网络可用，由实际连接验证');
        return true;
      } catch (e2) {
        Logs.error('备用网络检查也失败: $e2');
        // 最后的备用方案：假设网络可用
        _isNetworkAvailable = true;
        return true;
      }
    }
  }
}
