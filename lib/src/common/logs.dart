import '../../flutter_wukongim_sdk.dart';

enum LogLevel {
  debug(0),
  info(1),
  warn(2),
  error(3),
  none(4);

  const LogLevel(this.value);
  final int value;
}

class Logs {
  static LogLevel _currentLevel = LogLevel.debug;
  static bool _enableConsoleOutput = true;
  static Function(LogLevel level, String tag, Object message)? _customLogger;

  /// 设置日志级别
  static void setLogLevel(LogLevel level) {
    _currentLevel = level;
  }

  /// 设置是否启用控制台输出
  static void setConsoleOutput(bool enable) {
    _enableConsoleOutput = enable;
  }

  /// 设置自定义日志处理器
  static void setCustomLogger(
      Function(LogLevel level, String tag, Object message)? logger) {
    _customLogger = logger;
  }

  /// 获取当前环境是否启用日志
  static bool get _isDebugEnabled {
    try {
      return WKIM.shared.options.debug;
    } catch (e) {
      // 如果WKIM还未初始化，默认启用日志
      return true;
    }
  }

  static void _log(LogLevel level, String tag, Object msg) {
    // 检查日志级别
    if (level.value < _currentLevel.value) return;

    // 检查全局调试开关
    if (!_isDebugEnabled) return;

    final timestamp = DateTime.now().toIso8601String();
    final formattedMsg = "[$timestamp] [$tag] $msg";

    // 自定义日志处理器优先
    if (_customLogger != null) {
      _customLogger!(level, tag, msg);
      return;
    }

    // 控制台输出
    if (_enableConsoleOutput) {
      switch (level) {
        case LogLevel.debug:
          // ignore: avoid_print
          print("🐛 $formattedMsg");
          break;
        case LogLevel.info:
          // ignore: avoid_print
          print("ℹ️ $formattedMsg");
          break;
        case LogLevel.warn:
          // ignore: avoid_print
          print("⚠️ $formattedMsg");
          break;
        case LogLevel.error:
          // ignore: avoid_print
          print("❌ $formattedMsg");
          break;
        case LogLevel.none:
          break;
      }
    }
  }

  static void debug(Object msg, [String tag = 'WKIM']) {
    _log(LogLevel.debug, tag, msg);
  }

  static void info(Object msg, [String tag = 'WKIM']) {
    _log(LogLevel.info, tag, msg);
  }

  static void warn(Object msg, [String tag = 'WKIM']) {
    _log(LogLevel.warn, tag, msg);
  }

  static void error(Object msg, [String tag = 'WKIM']) {
    _log(LogLevel.error, tag, msg);
  }

  /// 网络相关日志
  static void network(Object msg) {
    _log(LogLevel.debug, 'NETWORK', msg);
  }

  /// 消息相关日志
  static void message(Object msg) {
    _log(LogLevel.debug, 'MESSAGE', msg);
  }

  /// 连接相关日志
  static void connection(Object msg) {
    _log(LogLevel.info, 'CONNECTION', msg);
  }

  /// 数据库相关日志
  static void database(Object msg) {
    _log(LogLevel.debug, 'DATABASE', msg);
  }
}
