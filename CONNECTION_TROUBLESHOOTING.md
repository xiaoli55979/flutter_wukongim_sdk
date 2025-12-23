# WuKongIM SDK 连接问题排查指南

## 问题现象

根据你提供的日志，连接过程如下：
```
✅ 网络检查通过 (WiFi)
✅ WebSocket连接成功 (wss://ws.xzlspe.cn)
❌ 连接异常关闭 (Code: 1006, 约6秒后)
```

## 问题分析

### WebSocket关闭码1006含义
- **1006 = Abnormal Closure（异常关闭）**
- 这通常表示连接在握手完成后被服务器主动断开
- 不是网络问题，而是应用层协议问题

### 可能的原因

1. **认证失败** ⭐ 最可能
   - UID或Token不正确
   - Token已过期
   - 服务器拒绝认证

2. **协议不匹配**
   - 客户端协议版本与服务器不兼容
   - 消息格式错误

3. **服务器限制**
   - 连接数限制
   - 频率限制
   - IP白名单限制

## 排查步骤

### 1. 验证凭据
```dart
// 检查你的凭据是否正确
static const String uid = 'Vd550fadjh9js73f8th40';
static const String token = 'a583b2c0dfac11f08b96ba33e17853e7';
```

**建议操作：**
- 确认UID和Token是否为最新有效的
- 检查Token是否有过期时间
- 联系服务器管理员验证账号状态

### 2. 检查协议配置
```dart
final options = Options()
  ..protoVersion = 0x04  // 确认协议版本
  ..deviceFlag = 1       // 确认设备标识
  ..useWebSocket = true; // 确认使用WebSocket
```

### 3. 添加错误回调
```dart
final options = Options()
  ..onError = (url, error, stack, code) {
    print('SDK错误: $error, Code: $code');
  };
```

### 4. 使用调试示例
运行新创建的 `DebugWuKongIMExample`，它提供了：
- 详细的连接状态分析
- 错误码解释
- 连接失败原因分析
- 实时诊断信息

## 解决方案

### 方案1：验证凭据（推荐）
1. 联系服务器管理员确认账号状态
2. 获取新的有效Token
3. 确认UID格式是否正确

### 方案2：检查服务器配置
1. 确认服务器地址是否正确
2. 检查服务器是否正常运行
3. 确认WebSocket端口是否开放

### 方案3：调整客户端配置
```dart
final options = Options()
  ..protoVersion = 0x03  // 尝试不同的协议版本
  ..deviceFlag = 0       // 尝试不同的设备标识
  ..environment = WKEnvironment.production; // 尝试生产环境
```

### 方案4：网络诊断
```bash
# 测试WebSocket连接
curl -i -N -H "Connection: Upgrade" \
     -H "Upgrade: websocket" \
     -H "Sec-WebSocket-Key: test" \
     -H "Sec-WebSocket-Version: 13" \
     https://ws.xzlspe.cn
```

## 常见错误码对照

| 错误码 | 含义 | 解决方案 |
|--------|------|----------|
| 1 | 认证失败 | 检查UID/Token |
| 2 | 重复登录 | 退出其他设备 |
| 1006 | 异常关闭 | 检查认证和协议 |
| 1002 | 协议错误 | 检查协议版本 |
| 1011 | 服务器错误 | 联系服务器管理员 |

## 下一步行动

1. **立即行动**：运行调试示例获取详细日志
2. **验证凭据**：确认UID和Token的有效性
3. **联系支持**：如果凭据正确但仍然失败，联系技术支持

## 调试示例使用方法

1. 运行应用后会自动初始化SDK
2. 点击"连接测试"按钮进行诊断
3. 查看详细日志了解具体失败原因
4. 根据错误提示进行相应处理

调试示例会提供比基础示例更详细的错误分析和解决建议。