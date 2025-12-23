import 'package:flutter/material.dart';
import 'package:flutter_wukongim_sdk/flutter_wukongim_sdk.dart';

/// 基础的WuKongIM SDK使用示例
/// 演示SDK初始化和连接功能
class BasicWuKongIMExample extends StatefulWidget {
  const BasicWuKongIMExample({super.key});

  @override
  State<BasicWuKongIMExample> createState() => _BasicWuKongIMExampleState();
}

class _BasicWuKongIMExampleState extends State<BasicWuKongIMExample> {
  bool _isInitialized = false;
  String _status = '未初始化';
  String _connectionStatus = '未连接';
  final List<String> _logs = [];

  // 你的凭据
  static const String uid = '';
  static const String token = '';
  static const String serverAddress = '';

  @override
  void initState() {
    super.initState();
    _initSDK();
  }

  Future<void> _initSDK() async {
    try {
      _addLog('开始初始化WuKongIM SDK...');

      final options = Options()
        ..uid = uid
        ..token = token
        ..addr = serverAddress
        ..useWebSocket = true
        ..environment = WKEnvironment.development
        ..protoVersion = 0x04
        ..deviceFlag = 1;

      bool result = await WKIM.shared.setup(options);

      setState(() {
        _isInitialized = result;
        _status = result ? 'SDK初始化成功' : 'SDK初始化失败';
      });

      _addLog(_status);

      if (result) {
        _setupListeners();
      }
    } catch (e) {
      _addLog('初始化错误: $e');
      setState(() {
        _status = '初始化错误';
      });
    }
  }

  void _setupListeners() {
    try {
      // 监听连接状态
      WKIM.shared.connectionManager.addOnConnectionStatus('basic_example', (
        status,
        reasonCode,
        info,
      ) {
        setState(() {
          _connectionStatus = _getStatusText(status);
        });
        _addLog('连接状态变更: $_connectionStatus');
      });

      // 监听新消息
      WKIM.shared.messageManager.addOnNewMsgListener('basic_example', (
        messages,
      ) {
        _addLog('收到 ${messages.length} 条新消息');
        for (var msg in messages) {
          _addLog('消息内容: ${msg.content}');
        }
      });

      _addLog('监听器设置完成');
    } catch (e) {
      _addLog('设置监听器错误: $e');
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
      default:
        return '未知状态($status)';
    }
  }

  void _connect() {
    if (_isInitialized) {
      try {
        WKIM.shared.connectionManager.connect();
        _addLog('开始连接服务器...');
      } catch (e) {
        _addLog('连接错误: $e');
      }
    } else {
      _addLog('SDK未初始化，无法连接');
    }
  }

  void _disconnect() {
    if (_isInitialized) {
      try {
        WKIM.shared.connectionManager.disconnect(true);
        _addLog('断开连接...');
      } catch (e) {
        _addLog('断开连接错误: $e');
      }
    }
  }

  void _sendTestMessage() {
    if (!_isInitialized) {
      _addLog('SDK未初始化，无法发送消息');
      return;
    }

    try {
      final textContent = WKTextContent('Hello from Flutter SDK! 测试消息');
      final channel = WKChannel('test_channel', WKChannelType.group);

      WKIM.shared.messageManager.sendMessage(textContent, channel);
      _addLog('发送测试消息到频道: test_channel');
    } catch (e) {
      _addLog('发送消息错误: $e');
    }
  }

  void _addLog(String log) {
    setState(() {
      _logs.add('${DateTime.now().toString().substring(11, 19)}: $log');
    });
    // 保持日志数量在合理范围内
    if (_logs.length > 100) {
      _logs.removeAt(0);
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
        title: const Text('WuKongIM SDK 基础示例'),
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
                    Text(
                      'SDK状态: $_status',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: _isInitialized ? Colors.green : Colors.red,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '连接状态: $_connectionStatus',
                      style: TextStyle(
                        fontSize: 14,
                        color: _connectionStatus == '已连接'
                            ? Colors.green
                            : Colors.orange,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text('用户ID: $uid', style: const TextStyle(fontSize: 12)),
                    Text(
                      '服务器: $serverAddress',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 16),

            // 操作按钮
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: _isInitialized && _connectionStatus != '已连接'
                        ? _connect
                        : null,
                    child: const Text('连接服务器'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _isInitialized && _connectionStatus == '已连接'
                        ? _disconnect
                        : null,
                    child: const Text('断开连接'),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 8),

            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: _isInitialized && _connectionStatus == '已连接'
                        ? _sendTestMessage
                        : null,
                    child: const Text('发送测试消息'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _clearLogs,
                    child: const Text('清空日志'),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 16),

            // 日志区域
            const Text(
              '运行日志:',
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
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1),
                      child: Text(
                        _logs[index],
                        style: const TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
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
        WKIM.shared.connectionManager.removeOnConnectionStatus('basic_example');
        WKIM.shared.messageManager.removeNewMsgListener('basic_example');
      } catch (e) {
        // 清理监听器时出错，但不影响应用运行
        debugPrint('清理监听器时出错: $e');
      }
    }
    super.dispose();
  }
}
