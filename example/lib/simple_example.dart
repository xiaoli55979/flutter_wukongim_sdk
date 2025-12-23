import 'package:flutter/material.dart';
import 'package:flutter_wukongim_sdk/flutter_wukongim_sdk.dart';

/// 简单的WuKongIM SDK使用示例
class SimpleWuKongIMExample extends StatefulWidget {
  const SimpleWuKongIMExample({super.key});

  @override
  State<SimpleWuKongIMExample> createState() => _SimpleWuKongIMExampleState();
}

class _SimpleWuKongIMExampleState extends State<SimpleWuKongIMExample> {
  bool _isInitialized = false;
  String _status = '未初始化';
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
      _addLog('开始初始化SDK...');

      final options = Options()
        ..uid = uid
        ..token = token
        ..addr = serverAddress
        ..useWebSocket = true
        ..environment = WKEnvironment.development;

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
    // 监听连接状态
    WKIM.shared.connectionManager.addOnConnectionStatus('simple', (
      status,
      reasonCode,
      info,
    ) {
      _addLog('连接状态: ${_getStatusText(status)}');
    });

    // 监听新消息
    WKIM.shared.messageManager.addOnNewMsgListener('simple', (messages) {
      _addLog('收到 ${messages.length} 条新消息');
    });
  }

  String _getStatusText(int status) {
    switch (status) {
      case WKConnectStatus.connecting:
        return '连接中';
      case WKConnectStatus.success:
        return '已连接';
      case WKConnectStatus.fail:
        return '连接失败';
      default:
        return '未知';
    }
  }

  void _connect() {
    if (_isInitialized) {
      WKIM.shared.connectionManager.connect();
      _addLog('开始连接服务器...');
    }
  }

  void _sendTestMessage() {
    if (!_isInitialized) return;

    try {
      final textContent = WKTextContent('Hello from Flutter SDK!');
      final channel = WKChannel('test_channel', WKChannelType.group);
      WKIM.shared.messageManager.sendMessage(textContent, channel);
      _addLog('发送测试消息');
    } catch (e) {
      _addLog('发送消息错误: $e');
    }
  }

  void _addLog(String log) {
    setState(() {
      _logs.add('${DateTime.now().toString().substring(11, 19)}: $log');
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Simple WuKongIM Example')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('状态: $_status', style: const TextStyle(fontSize: 16)),
                    const SizedBox(height: 8),
                    Text('UID: $uid'),
                    Text('服务器: $serverAddress'),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: _isInitialized ? _connect : null,
                    child: const Text('连接服务器'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _isInitialized ? _sendTestMessage : null,
                    child: const Text('发送测试消息'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Text(
              '日志:',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: ListView.builder(
                  itemCount: _logs.length,
                  itemBuilder: (context, index) {
                    return Text(
                      _logs[index],
                      style: const TextStyle(
                        fontSize: 12,
                        fontFamily: 'monospace',
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
      WKIM.shared.connectionManager.removeOnConnectionStatus('simple');
      WKIM.shared.messageManager.removeNewMsgListener('simple');
    }
    super.dispose();
  }
}
