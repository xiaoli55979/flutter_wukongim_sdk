# Flutter WuKongIM SDK

[![pub package](https://img.shields.io/pub/v/flutter_wukongim_sdk.svg)](https://pub.dev/packages/flutter_wukongim_sdk)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Flutter WuKongIM SDK 是一个高性能的即时通讯Flutter插件，基于WuKongIM即时通讯系统构建。提供完整的聊天功能，包括消息发送接收、频道管理、会话管理等核心功能。

## ✨ 特性

- 🚀 **高性能**: 支持大量并发连接和消息处理
- 🔒 **安全可靠**: 端到端加密，支持x25519密钥交换
- 🔄 **自动重连**: 完善的网络重连机制和消息重发保障
- 📱 **跨平台**: 支持iOS和Android平台
- 🎯 **多消息类型**: 文本、图片、语音、视频、卡片等
- 💾 **本地存储**: 基于SQLite的消息持久化存储
- 🌍 **多环境**: 支持开发、测试、预发布、生产环境配置

## 📦 安装

在 `pubspec.yaml` 文件中添加依赖：

```yaml
dependencies:
  flutter_wukongim_sdk: ^0.0.1
```

然后运行：

```bash
flutter pub get
```

## 🚀 快速开始

### 1. 初始化SDK

```dart
import 'package:flutter_wukongim_sdk/flutter_wukongim_sdk.dart';

// 配置选项
final options = Options()
  ..uid = 'your_user_id'
  ..token = 'your_token'
  ..addr = 'your_server_address:port'
  ..environment = WKEnvironment.development;

// 初始化SDK
await WKIM.shared.setup(options);
```

### 2. 连接服务器

```dart
// 连接到WuKongIM服务器
WKIM.shared.connectionManager.connect();

// 监听连接状态
WKIM.shared.connectionManager.addOnConnectionStatusListener('demo', (status) {
  print('连接状态: $status');
});
```

### 3. 发送消息

```dart
// 创建文本消息
final textContent = WKTextContent('Hello, World!');

// 发送消息
WKIM.shared.messageManager.sendMessage(
  WKMsg()
    ..channelID = 'channel_id'
    ..channelType = WKChannelType.person
    ..content = textContent,
);
```

### 4. 接收消息

```dart
// 监听新消息
WKIM.shared.messageManager.addOnNewMsgListener('demo', (messages) {
  for (var msg in messages) {
    print('收到新消息: ${msg.content}');
  }
});
```

## 📚 核心功能

### 消息管理

```dart
// 注册自定义消息类型
WKIM.shared.messageManager.registerMsgContent(
  CustomMessageType.custom,
  (data) => CustomMessageContent().decodeJson(data),
);

// 发送图片消息
final imageContent = WKImageContent(width, height)
  ..localPath = imagePath;

WKIM.shared.messageManager.sendMessage(
  WKMsg()
    ..channelID = channelId
    ..channelType = channelType
    ..content = imageContent,
);
```

### 频道管理

```dart
// 获取频道信息
final channel = await WKIM.shared.channelManager.getChannel(
  channelId, 
  channelType,
);

// 加入频道
await WKIM.shared.channelManager.joinChannel(channelId, channelType);
```

### 会话管理

```dart
// 获取会话列表
final conversations = await WKIM.shared.conversationManager.getConversations();

// 删除会话
await WKIM.shared.conversationManager.deleteConversation(
  channelId, 
  channelType,
);
```

## ⚙️ 配置选项

### 环境配置

```dart
final options = Options()
  ..environment = WKEnvironment.production  // 生产环境
  ..debug = false;  // 关闭调试日志
```

### 网络配置

```dart
final options = Options()
  ..useWebSocket = true  // 使用WebSocket连接
  ..networkConfig = NetworkConfig()
    ..maxReconnectAttempts = 10
    ..reconnectInterval = Duration(seconds: 5);
```

### 消息同步配置

```dart
final options = Options()
  ..messageSyncConfig = MessageSyncConfig()
    ..syncInterval = Duration(minutes: 1)
    ..maxSyncMessages = 100;
```

## 🔧 高级用法

### 自定义消息类型

```dart
class CustomMessageContent extends WKMessageContent {
  String customData;
  
  CustomMessageContent(this.customData);
  
  @override
  WKMessageContent decodeJson(Map<String, dynamic> json) {
    return CustomMessageContent(json['custom_data'] ?? '');
  }
  
  @override
  Map<String, dynamic> encodeJson() {
    return {'custom_data': customData};
  }
}
```

### 消息加密

```dart
// SDK内置端到端加密，无需额外配置
// 支持x25519密钥交换算法
```

### 离线消息处理

```dart
// 监听离线消息同步
WKIM.shared.messageSyncManager.addOnSyncListener('demo', (syncResult) {
  print('同步了 ${syncResult.messages.length} 条离线消息');
});
```

## 🐛 错误处理

```dart
// 设置全局错误回调
final options = Options()
  ..onError = (url, error, stack, code) {
    print('SDK错误: $error');
    // 处理错误逻辑
  };

// 强制重置连接（解决连接问题）
WKIM.shared.forceResetConnection();
```

## 📱 平台支持

| 平台 | 支持版本 |
|------|----------|
| iOS | 9.0+ |
| Android | API 16+ |
| Flutter | 3.3.0+ |
  
## 🔗 相关链接

- [WuKongIM 官网](https://githubim.com)
- [Flutter 官方文档](https://flutter.dev)
- [问题反馈](https://github.com/your-repo/flutter_wukongim_sdk/issues)

## 📞 支持

如果您在使用过程中遇到问题，可以通过以下方式获取帮助：

- 查看 [常见问题](https://github.com/your-repo/flutter_wukongim_sdk/wiki/FAQ)
- 提交 [Issue](https://github.com/your-repo/flutter_wukongim_sdk/issues)
- 发送邮件至：support@example.com

