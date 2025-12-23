import 'package:flutter/foundation.dart';

import '../proto/proto.dart';
import 'logs.dart';

enum WKEnvironment {
  development,
  testing,
  staging,
  production,
}

class Options {
  /// 是否使用 websocket
  bool useWebSocket = true;

  String? uid, token;
  String? addr; // connect address IP:PORT
  int protoVersion = 0x04; // protocol version
  int deviceFlag = 0;

  /// 环境配置
  WKEnvironment environment = WKEnvironment.development;

  /// 调试总开关 - 根据环境自动设置
  bool get debug => _getDebugMode();

  /// 手动设置调试模式（可覆盖环境默认值）
  bool? _manualDebugMode = kDebugMode;

  List<String> addrs = [];
  int addrIndex = 0; // 默认从 0 开始

  /// 网络重连配置
  NetworkConfig networkConfig = NetworkConfig();

  /// 消息同步配置
  MessageSyncConfig messageSyncConfig = MessageSyncConfig();

  /// 异步获取地址的方法
  Function(Function(String addr) complete)? getAddr;

  /// 协议处理对象
  Proto proto = Proto();

  /// 异常回调
  Function(String url, Object error, StackTrace stack, int code)? onError;

  Options();

  Options.newDefault(this.uid, this.token, {this.addr, this.environment = WKEnvironment.development});

  /// 设置环境
  void setEnvironment(WKEnvironment env) {
    environment = env;
    configureForEnvironment();
  }

  /// 手动设置调试模式
  void setDebugMode(bool debug) {
    _manualDebugMode = debug;
  }

  /// 获取调试模式
  bool _getDebugMode() {
    if (_manualDebugMode != null) {
      return _manualDebugMode!;
    }

    switch (environment) {
      case WKEnvironment.development:
      case WKEnvironment.testing:
        return true;
      case WKEnvironment.staging:
      case WKEnvironment.production:
        return false;
    }
  }

  /// 根据环境配置相关参数
  void configureForEnvironment() {
    switch (environment) {
      case WKEnvironment.development:
        Logs.setLogLevel(LogLevel.debug);
        networkConfig.maxRetryCount = 5;
        messageSyncConfig.batchSize = 50;
        break;
      case WKEnvironment.testing:
        Logs.setLogLevel(LogLevel.debug);
        networkConfig.maxRetryCount = 3;
        messageSyncConfig.batchSize = 100;
        break;
      case WKEnvironment.staging:
        Logs.setLogLevel(LogLevel.info);
        networkConfig.maxRetryCount = 3;
        messageSyncConfig.batchSize = 200;
        break;
      case WKEnvironment.production:
        Logs.setLogLevel(LogLevel.error);
        networkConfig.maxRetryCount = 2;
        messageSyncConfig.batchSize = 500;
        break;
    }
  }
}

/// 网络重连配置
class NetworkConfig {
  /// 最大重连次数
  int maxRetryCount = 5;

  /// 基础重连间隔（毫秒）
  int baseRetryInterval = 1000;

  /// 最大重连间隔（毫秒）
  int maxRetryInterval = 30000;

  /// 重连间隔增长因子
  double retryBackoffMultiplier = 1.5;

  /// 连接超时时间（秒）
  int connectTimeout = 10;

  /// 心跳间隔（秒）
  int heartbeatInterval = 15;

  /// 心跳超时次数
  int heartbeatTimeoutCount = 2;

  /// 网络检测间隔（秒）
  int networkCheckInterval = 3;

  /// 快速地址切换延迟（毫秒）
  int fastAddressSwitchDelay = 500;

  /// 是否启用快速地址切换
  bool enableFastAddressSwitch = true;
}

/// 消息同步配置
class MessageSyncConfig {
  /// 批量同步消息数量
  int batchSize = 100;

  /// 同步超时时间（秒）
  int syncTimeout = 30;

  /// 最大并发同步数
  int maxConcurrentSync = 3;

  /// 同步重试次数
  int syncRetryCount = 3;

  /// 同步间隔（毫秒）
  int syncInterval = 500;
}
