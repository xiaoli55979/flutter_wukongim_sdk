# WuKongIM SDK Flutter 示例

这个示例演示了如何使用 Flutter WuKongIM SDK 进行即时通讯功能的开发。

## 运行示例

1. 确保你已经安装了 Flutter SDK
2. 在项目根目录运行：
   ```bash
   cd example
   flutter pub get
   flutter run
   ```

## 示例说明

### 基础示例 (basic_example.dart)
**推荐使用** - 简洁清晰的SDK使用示例，包含：
- SDK 初始化和配置
- 连接状态监控
- 基础消息发送功能
- 实时日志显示
- 错误处理

### 简单示例 (simple_example.dart)
最基础的SDK使用示例，适合快速了解SDK的基本用法。

## 配置信息

示例中使用的测试配置：
- **UID**: `Vd550fadjh9js73f8th40`
- **Token**: `a583b2c0dfac11f08b96ba33e17853e7`
- **服务器地址**: `ws.xzlspe.cn`

## 功能演示

1. **SDK初始化**: 自动初始化WuKongIM SDK
2. **连接服务器**: 点击连接按钮建立与WuKongIM服务器的连接
3. **发送消息**: 发送测试消息到指定频道
4. **状态监控**: 实时查看连接状态和操作日志
5. **消息接收**: 监听并显示收到的消息

## 使用步骤

1. 启动应用后，SDK会自动初始化
2. 等待初始化完成（查看日志）
3. 点击"连接服务器"按钮
4. 连接成功后，可以点击"发送测试消息"
5. 查看日志了解详细的运行状态

## 注意事项

- 确保网络连接正常
- 服务器地址需要支持WebSocket连接
- 如果连接失败，请检查服务器状态和网络配置
- 日志会显示详细的错误信息，便于调试

## 自定义配置

如果你有自己的WuKongIM服务器，可以修改以下配置：

```dart
static const String uid = 'your_user_id';
static const String token = 'your_token';
static const String serverAddress = 'your_server_address';
```

## 故障排除

1. **初始化失败**: 检查SDK配置参数是否正确
2. **连接失败**: 检查服务器地址和网络连接
3. **消息发送失败**: 确认已成功连接到服务器
4. **权限问题**: 确保应用有网络访问权限

## API 使用说明

### 初始化SDK
```dart
final options = Options()
  ..uid = 'your_uid'
  ..token = 'your_token'
  ..addr = 'your_server_address'
  ..useWebSocket = true
  ..environment = WKEnvironment.development;

bool result = await WKIM.shared.setup(options);
```

### 连接服务器
```dart
WKIM.shared.connectionManager.connect();
```

### 发送消息
```dart
final textContent = WKTextContent('Hello World');
final channel = WKChannel('channel_id', WKChannelType.group);
WKIM.shared.messageManager.sendMessage(textContent, channel);
```

### 监听连接状态
```dart
WKIM.shared.connectionManager.addOnConnectionStatus('key', (status, reasonCode, info) {
  // 处理连接状态变化
});
```

### 监听新消息
```dart
WKIM.shared.messageManager.addOnNewMsgListener('key', (messages) {
  // 处理新消息
});
```

## 更多信息

查看主项目的 README.md 文件了解更多 SDK 使用方法和 API 文档。