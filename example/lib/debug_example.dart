import 'package:flutter/material.dart';
import 'package:flutter_wukongim_sdk/flutter_wukongim_sdk.dart';

/// 调试版本的WuKongIM SDK示例
/// 包含详细的连接诊断和错误分析
class DebugWuKongIMExample extends StatefulWidget {
  const DebugWuKongIMExample({super.key});

  @override
  State<DebugWuKongIMExample> createState() => _DebugWuKongIMExampleState();
}

class _DebugWuKongIMExampleState extends State<DebugWuKongIMExample> {
  bool _isInitialized = false;
  String _status = '未初始化';
  String _connectionStatus = '未连接';
  final List<String> _logs = [];

  // 你的凭据
  static const String uid = 'Vd550fadjh9js73f8th40';
  static const String token = 'a583b2c0dfac11f08b96ba33e17853e7';
  static const String serverAddress = 'ws.xzlspe.cn';

  @override
  void initState() {
    super.initState();
    _initSDK();
  }

  Future<void> _initSDK() async {
    try {
      _addLog('🚀 开始初始化WuKongIM SDK...');
      _addLog('📋 配置信息:');
      _addLog('   UID: $uid');
      _addLog('   Token: ${token.substring(0, 8)}...');
      _addLog('   服务器: $serverAddress');

      final options = Options()
        ..uid = uid
        ..token = token
        ..addr = serverAddress
        ..useWebSocket = true
        ..environment = WKEnvironment.development
        ..protoVersion = 0x04
        ..deviceFlag = 1
        ..onError = (url, error, stack, code) {
          _addLog('🔥 SDK错误回调: URL=$url, Code=$code');
          _addLog('   错误: $error');
        };

      bool result = await WKIM.shared.setup(options);

      setState(() {
        _isInitialized = result;
        _status = result ? 'SDK初始化成功' : 'SDK初始化失败';
      });

      _addLog(result ? '✅ $_status' : '❌ $_status');

      if (result) {
        _setupListeners();
      }
    } catch (e, stack) {
      _addLog('💥 初始化异常: $e');
      _addLog('📍 堆栈: ${stack.toString().split('\n').take(3).join('\n')}');
      setState(() {
        _status = '初始化异常';
      });
    }
  }

  void _setupListeners() {
    try {
      _addLog('🔧 设置监听器...');

      // 监听连接状态
      WKIM.shared.connectionManager.addOnConnectionStatus('debug_example', (
        status,
        reasonCode,
        info,
      ) {
        final statusText = _getStatusText(status);
        setState(() {
          _connectionStatus = statusText;
        });

        _addLog('🔄 连接状态: $statusText');
        if (reasonCode != null) {
          _addLog('   原因码: $reasonCode');
          _analyzeConnectionFailure(status, reasonCode);
        }
        if (info != null) {
          _addLog('   连接信息: $info');
        }
      });

      // 监听新消息
      WKIM.shared.messageManager.addOnNewMsgListener('debug_example', (
        messages,
      ) {
        _addLog('📨 收到 ${messages.length} 条新消息');
        for (var msg in messages) {
          _addLog('   消息: ${msg.content} (来自: ${msg.fromUID})');
        }
      });

      _addLog('✅ 监听器设置完成');
    } catch (e) {
      _addLog('❌ 设置监听器错误: $e');
    }
  }

  String _getStatusText(int status) {
    switch (status) {
      case WKConnectStatus.connecting:
        return '连接中';
      case WKConnectStatus.success:
        return '已连接';
      case WKConnectStatus.fail:
        return '连接失败';
      case WKConnectStatus.noNetwork:
        return '无网络';
      case WKConnectStatus.kicked:
        return '被踢下线';
      case WKConnectStatus.syncMsg:
        return '同步消息中';
      case WKConnectStatus.syncCompleted:
        return '同步完成';
      default:
        return '未知状态($status)';
    }
  }

  void _analyzeConnectionFailure(int status, int reasonCode) {
    if (status != WKConnectStatus.fail) return;

    _addLog('🔍 连接失败分析:');
    switch (reasonCode) {
      case 1:
        _addLog('   ❌ 认证失败');
        _addLog('   💡 可能原因: UID或Token不正确');
        _addLog('   🔧 解决方案: 检查凭据是否有效');
        break;
      case 2:
        _addLog('   ❌ 重复登录');
        _addLog('   💡 可能原因: 该账号已在其他设备登录');
        _addLog('   🔧 解决方案: 退出其他设备或使用不同账号');
        break;
      case 1006:
        _addLog('   ❌ WebSocket异常关闭');
        _addLog('   💡 可能原因: 认证超时、协议不匹配或网络问题');
        _addLog('   🔧 解决方案: 检查网络连接和服务器状态');
        break;
      default:
        _addLog('   ❌ 未知错误码: $reasonCode');
        _addLog('   🔧 解决方案: 联系技术支持');
    }
  }

  void _connect() {
    if (!_isInitialized) {
      _addLog('❌ SDK未初始化，无法连接');
      return;
    }

    _addLog('🔌 开始连接服务器...');
    _addLog('📡 目标地址: wss://$serverAddress');

    try {
      WKIM.shared.connectionManager.connect();
    } catch (e) {
      _addLog('💥 连接异常: $e');
    }
  }

  void _disconnect() {
    if (!_isInitialized) return;

    _addLog('🔌 断开连接...');
    try {
      WKIM.shared.connectionManager.disconnect(true);
    } catch (e) {
      _addLog('💥 断开连接异常: $e');
    }
  }

  void _sendTestMessage() {
    if (!_isInitialized) {
      _addLog('❌ SDK未初始化，无法发送消息');
      return;
    }

    if (_connectionStatus != '已连接') {
      _addLog('❌ 未连接到服务器，无法发送消息');
      return;
    }

    _addLog('📤 发送测试消息...');
    try {
      final textContent = WKTextContent('Hello from Debug Example! 🚀');
      final channel = WKChannel('test_channel', WKChannelType.group);

      WKIM.shared.messageManager.sendMessage(textContent, channel);
      _addLog('✅ 测试消息已发送到频道: test_channel');
    } catch (e) {
      _addLog('💥 发送消息异常: $e');
    }
  }

  void _testConnection() {
    _addLog('🧪 开始连接测试...');
    _addLog('1️⃣ 检查SDK状态: ${_isInitialized ? "✅" : "❌"}');
    _addLog('2️⃣ 检查连接状态: $_connectionStatus');
    _addLog('3️⃣ 检查配置:');
    _addLog('   - WebSocket: ${WKIM.shared.options.useWebSocket ? "✅" : "❌"}');
    _addLog('   - 协议版本: ${WKIM.shared.options.protoVersion}');
    _addLog('   - 设备标识: ${WKIM.shared.options.deviceFlag}');
    _addLog('   - 环境: ${WKIM.shared.options.environment}');
  }

  void _addLog(String log) {
    setState(() {
      _logs.add('${DateTime.now().toString().substring(11, 19)}: $log');
    });
    // 保持日志数量在合理范围内
    if (_logs.length > 200) {
      _logs.removeRange(0, 50);
    }
  }

  void _clearLogs() {
    setState(() {
      _logs.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('WuKongIM 连接诊断'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 状态卡片
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          _isInitialized ? Icons.check_circle : Icons.error,
                          color: _isInitialized ? Colors.green : Colors.red,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'SDK: $_status',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Icon(
                          _connectionStatus == '已连接'
                              ? Icons.wifi
                              : Icons.wifi_off,
                          color: _connectionStatus == '已连接'
                              ? Colors.green
                              : Colors.orange,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '连接: $_connectionStatus',
                          style: const TextStyle(fontSize: 14),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 16),

            // 操作按钮
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ElevatedButton.icon(
                  onPressed: _isInitialized && _connectionStatus != '已连接'
                      ? _connect
                      : null,
                  icon: const Icon(Icons.connect_without_contact),
                  label: const Text('连接'),
                ),
                ElevatedButton.icon(
                  onPressed: _isInitialized && _connectionStatus == '已连接'
                      ? _disconnect
                      : null,
                  icon: const Icon(Icons.link_off),
                  label: const Text('断开'),
                ),
                ElevatedButton.icon(
                  onPressed: _isInitialized && _connectionStatus == '已连接'
                      ? _sendTestMessage
                      : null,
                  icon: const Icon(Icons.send),
                  label: const Text('测试消息'),
                ),
                ElevatedButton.icon(
                  onPressed: _testConnection,
                  icon: const Icon(Icons.bug_report),
                  label: const Text('连接测试'),
                ),
                ElevatedButton.icon(
                  onPressed: _clearLogs,
                  icon: const Icon(Icons.clear),
                  label: const Text('清空日志'),
                ),
              ],
            ),

            const SizedBox(height: 16),

            // 日志区域
            const Text(
              '📋 详细日志:',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey[300]!),
                  borderRadius: BorderRadius.circular(8),
                  color: Colors.grey[50],
                ),
                child: ListView.builder(
                  itemCount: _logs.length,
                  itemBuilder: (context, index) {
                    final log = _logs[index];
                    Color? textColor;
                    if (log.contains('❌') || log.contains('💥')) {
                      textColor = Colors.red[700];
                    } else if (log.contains('✅')) {
                      textColor = Colors.green[700];
                    } else if (log.contains('🔄') || log.contains('🔧')) {
                      textColor = Colors.blue[700];
                    }

                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1),
                      child: Text(
                        log,
                        style: TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                          color: textColor,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    if (_isInitialized) {
      try {
        WKIM.shared.connectionManager.removeOnConnectionStatus('debug_example');
        WKIM.shared.messageManager.removeNewMsgListener('debug_example');
      } catch (e) {
        debugPrint('清理监听器时出错: $e');
      }
    }
    super.dispose();
  }
}
