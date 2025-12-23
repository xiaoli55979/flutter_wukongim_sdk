import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../flutter_wukongim_sdk.dart';

/// 常见、可忽略的关闭码（可按需增减）
/// 1000: 正常关闭
/// 1002: 协议错误（很多实现里并不代表可行动信息）
/// 1005: 未收到状态码（保留值，线上常见、通常无可行动价值）
const Set<int> kWsIgnoredCloseCodes = {1000, 1002, 1005};

class _WKSocket {
  Socket? _socket; // 将 _socket 声明为可空类型
  bool _isListening = false;
  static _WKSocket? _instance;
  _WKSocket._internal(this._socket);
  factory _WKSocket.newSocket(Socket socket) {
    _instance ??= _WKSocket._internal(socket);
    return _instance!;
  }

  void close() {
    _isListening = false;
    _instance = null;
    try {
      _socket?.close();
      // _socket?.destroy();
    } finally {
      _socket = null; // 现在可以将 _socket 设置为 null
    }
  }

  send(Uint8List data) {
    try {
      if (_socket?.remotePort != null) {
        _socket?.add(data); // 使用安全调用操作符
        return _socket?.flush();
      }
    } catch (e) {
      Logs.debug('发送消息错误$e');
    }
  }

  void listen(void Function(Uint8List data) onData, void Function() error) {
    if (!_isListening && _socket != null) {
      _socket!.listen(
        onData,
        onError: (err, stack) {
          Logs.debug('Socket 发生错误: ${err.toString()}');
          WKIM.shared.options.onError?.call(WKIM.shared.options.addr ?? "", err, stack, -4);
          error(); // 触发外部错误处理（例如重连）
        },
        onDone: () {
          Logs.debug('Socket 连接已关闭');
          error(); // 触发外部错误处理（例如重连）
        },
        cancelOnError: true, // 确保错误时取消订阅
      );
      _isListening = true;
    }
  }
}

class WKConnectionManager {
  WKConnectionManager._privateConstructor();
  static final WKConnectionManager _instance = WKConnectionManager._privateConstructor();
  static WKConnectionManager get shared => _instance;

  bool isDisconnection = true;
  Timer? heartTimer;
  int unReceivePongCount = 0;
  HashMap<String, Function(int, int?, ConnectionInfo?)>? _connectionListenerMap;
  _WKSocket? _socket;
  WebSocketChannel? _webSocket;

  int pingSendIndex = 0;

  /// 提供外部访问的只读属性
  WebSocketChannel? get webSocket => _webSocket;

  /// 强制重置连接状态（用于解决首次连接失败后无法重连的问题）
  void forceReset() {
    Logs.connection('强制重置连接管理器状态');

    // 强制断开所有连接
    _forceDisconnect();

    // 重置所有状态变量
    isDisconnection = true;
    unReceivePongCount = 0;
    pingSendIndex = 0;

    // 清空缓存数据
    _cacheData = null;

    // 重置地址尝试记录
    _resetAddressAttempts();

    // 重置重连管理器
    ReconnectManager.shared.forceReset();

    Logs.connection('连接管理器状态强制重置完成');
  }

  addOnConnectionStatus(String key, Function(int, int?, ConnectionInfo?) back) {
    _connectionListenerMap ??= HashMap();
    _connectionListenerMap![key] = back;
  }

  removeOnConnectionStatus(String key) {
    if (_connectionListenerMap != null) {
      _connectionListenerMap!.remove(key);
    }
  }

  setConnectionStatus(int status, {int? reasoncode, ConnectionInfo? info}) {
    if (_connectionListenerMap != null) {
      _connectionListenerMap!.forEach((key, back) {
        back(status, reasoncode, info);
      });
    }
  }

  connect() {
    var addr = WKIM.shared.options.addr;
    if ((addr == null || addr == "") && WKIM.shared.options.getAddr == null) {
      Logs.connection("没有配置addr！");
      return;
    }
    if (WKIM.shared.options.uid == "" ||
        WKIM.shared.options.uid == null ||
        WKIM.shared.options.token == "" ||
        WKIM.shared.options.token == null) {
      Logs.error("没有初始化uid或token");
      return;
    }

    // 检查是否已经在连接中，避免重复连接
    if (!isDisconnection) {
      Logs.connection("连接已存在，跳过重复连接");
      return;
    }

    Logs.connection("开始连接流程...");

    // 检查网络状态
    ReconnectManager.shared.checkNetworkStatusNow().then((networkAvailable) {
      if (!networkAvailable) {
        Logs.connection("网络不可用，等待网络恢复后再连接");
        setConnectionStatus(WKConnectStatus.noNetwork);

        // 启动网络监控，等待网络恢复
        ReconnectManager.shared.startNetworkMonitoring();
        return;
      }

      // 网络可用，继续连接流程
      _performConnect(addr);
    }).catchError((e) {
      Logs.error("网络状态检查出错: $e，尝试连接");
      // 网络检查出错时仍尝试连接，可能是检查方法的问题
      _performConnect(addr);
    });
  }

  /// 执行连接（网络检查通过后）
  void _performConnect(String? addr) {
    try {
      Logs.connection("执行连接，地址: $addr");

      // 确保完全断开现有连接
      _forceDisconnect();

      // 重置连接状态
      isDisconnection = true;
      unReceivePongCount = 0;
      pingSendIndex = 0;

      // 设置连接中状态
      setConnectionStatus(WKConnectStatus.connecting);

      if (WKIM.shared.options.getAddr != null) {
        WKIM.shared.options.getAddr!((String addr) {
          _socketConnect(addr);
        });
      } else {
        _socketConnect(addr!);
      }
    } catch (e) {
      Logs.error("执行连接失败: $e");
      isDisconnection = true;
      setConnectionStatus(WKConnectStatus.fail);
      ReconnectManager.shared.onConnectFailed();
    }
  }

  /// 强制断开连接，确保资源完全释放
  void _forceDisconnect() {
    try {
      // 停止心跳
      _stopHeartTimer();

      // 关闭WebSocket连接
      if (_webSocket != null) {
        try {
          _webSocket!.sink.close();
        } catch (e) {
          Logs.debug("关闭WebSocket失败: $e");
        }
        _webSocket = null;
      }

      // 关闭Socket连接
      if (_socket != null) {
        try {
          _socket!.close();
        } catch (e) {
          Logs.debug("关闭Socket失败: $e");
        }
        _socket = null;
      }

      Logs.connection("强制断开连接完成");
    } catch (e) {
      Logs.error("强制断开连接异常: $e");
    }
  }

  disconnect(bool isLogout) {
    Logs.connection("断开连接，isLogout: $isLogout");
    isDisconnection = true;

    // 停止心跳
    _stopHeartTimer();

    // 停止重连和网络监控
    if (isLogout) {
      ReconnectManager.shared.stopReconnect();
      ReconnectManager.shared.stopNetworkMonitoring();
      MessageSyncManager.shared.stopSync();
    }

    // 关闭连接
    if (WKIM.shared.options.useWebSocket) {
      _webSocket?.sink.close();
    } else {
      _socket?.close();
    }

    if (isLogout) {
      WKIM.shared.options.uid = '';
      WKIM.shared.options.token = '';

      // 停止消息重发
      OptimizedMessageResendManager.shared.stop();

      // 安全地更新消息状态（不等待完成，避免阻塞）
      _updateSendingMsgFailSafely();

      // 延迟关闭数据库，给更新操作一些时间
      Timer(const Duration(milliseconds: 200), () {
        WKDBHelper.shared.close();
      });
    }

    _closeAll();
    setConnectionStatus(isLogout ? WKConnectStatus.fail : WKConnectStatus.fail);
  }

  _socketConnect(String addr) {
    // 调试日志：记录原始地址
    Logs.info("_socketConnect 收到地址: '$addr'");
    print("DEBUG: _socketConnect 收到地址: '$addr', 长度: ${addr.length}");

    // 检查地址中是否包含异常字符
    if (addr.contains('#')) {
      Logs.warn("地址包含异常字符 '#': $addr");
    }
    if (addr.contains(':0')) {
      Logs.warn("地址包含异常端口 ':0': $addr");
    }

    WKIM.shared.options.addr = addr;
    // WKIM.shared.options.useWebSocket = !_isTcpAddr(addr);
    if (WKIM.shared.options.useWebSocket) {
      _webSocketConnect(addr);
    } else {
      _wkSocketConnect(addr);
    }
  }

  Future<void> _webSocketConnect(String addr) async {
    try {
      // 确保地址格式正确
      String cleanAddr = addr.trim();
      if (!cleanAddr.startsWith('ws://') && !cleanAddr.startsWith('wss://')) {
        cleanAddr = 'wss://$cleanAddr';
      }

      // 移除可能的异常字符
      cleanAddr = cleanAddr.replaceAll(RegExp(r'[#\s]'), '');

      // 验证URL格式
      final wsUrl = Uri.parse(cleanAddr);
      if (wsUrl.scheme != 'ws' && wsUrl.scheme != 'wss') {
        throw Exception('无效的WebSocket协议: ${wsUrl.scheme}');
      }

      Logs.info("尝试连接 WebSocket: $cleanAddr");
      Logs.info("IM连接地址: $cleanAddr baseUrl:$addr");

      final channel = WebSocketChannel.connect(wsUrl);
      await channel.ready; // 确保连接成功

      _webSocket = channel;
      Logs.info("WebSocket 连接成功: $cleanAddr");
      _connectSuccess();
    } catch (e, stack) {
      Logs.error("WebSocket 连接失败: $e");
      print("IM连接异常: $e baseUrl:$addr");
      final code = _webSocket?.closeCode ?? 0;
      // 处理WebSocket关闭
      if (code != 0 && shouldReportWsClose(code)) {
        WKIM.shared.options.onError?.call(addr, e, stack, code);
      }
      _connectFail(e, addr);
    }
  }

  _wkSocketConnect(String addr) {
    Logs.info("Socket连接地址--->$addr");
    if (addr == '') {
      _connectFail('连接地址为空', addr);
      return;
    }
    var addrs = addr.split(":");
    var host = addrs[0];
    var port = addrs[1];
    try {
      setConnectionStatus(WKConnectStatus.connecting);
      Socket.connect(host, int.parse(port), timeout: const Duration(seconds: 5)).then((socket) {
        _socket = _WKSocket.newSocket(socket);
        _connectSuccess();
      }).catchError((err) {
        _connectFail(err, addr);
      }).onError((err, stackTrace) {
        _connectFail(err, addr);
      });
    } catch (e) {
      Logs.error(e.toString());
    }
  }

  // socket 连接成功
  void _connectSuccess() {
    Logs.connection("Socket连接建立成功");
    isDisconnection = false;

    // Socket连接成功

    if (WKIM.shared.options.useWebSocket) {
      _webSocket?.stream.listen(
        (message) {
          try {
            _cutDatas(message);
          } catch (e) {
            Logs.error("处理 WebSocket 消息出错: $e");
          }
        },
        onDone: () {
          final reason = _webSocket?.closeReason ?? "未知原因";
          final code = _webSocket?.closeCode ?? 0;
          final addr = WKIM.shared.options.addr;
          Logs.connection("WebSocket连接关闭，Code: $code, Reason: $reason, addr: $addr");

          isDisconnection = true;
          setConnectionStatus(WKConnectStatus.fail);

          // 处理WebSocket关闭
          if (code != 0 && shouldReportWsClose(code)) {
            final error = Exception("WebSocket closed: Code $code, Reason: $reason");
            WKIM.shared.options.onError?.call(addr ?? "", error, StackTrace.current, code);
          }
          ReconnectManager.shared.onConnectFailed();
        },
        onError: (error) {
          Logs.error("WebSocket发生错误: $error");
          isDisconnection = true;
          setConnectionStatus(WKConnectStatus.fail);
          final code = _webSocket?.closeCode ?? 0;
          // 处理WebSocket关闭
          if (code != 0 && shouldReportWsClose(code)) {
            WKIM.shared.options.onError?.call(WKIM.shared.options.addr ?? "", error, StackTrace.current, code);
          }

          //  WebSocket错误时应该触发重连
          ReconnectManager.shared.onConnectFailed();
        },
      );
    } else {
      _socket?.listen(
        (data) {
          _cutDatas(data);
        },
        () {
          Logs.connection("Socket连接断开");
          isDisconnection = true;
          setConnectionStatus(WKConnectStatus.fail);
          ReconnectManager.shared.onConnectFailed();
        },
      );
    }

    // 发送连接包
    _sendConnectPacket();
  }

  /// 关闭码是否需要上报
  bool shouldReportWsClose(int? code, {String? reason}) {
    // 未提供code的情况
    if (code == null) return true;

    // 过滤掉常见且无行动价值的关闭码
    if (kWsIgnoredCloseCodes.contains(code)) return false;

    return true;
  }

  _connectFail(error, baseUrl) {
    Logs.error("连接失败: $error, URL: $baseUrl");

    // 确保连接状态正确重置
    isDisconnection = true;
    unReceivePongCount = 0;
    pingSendIndex = 0;

    // 强制清理连接资源
    _forceDisconnect();

    setConnectionStatus(WKConnectStatus.fail);

    // 快速地址切换逻辑
    if (WKIM.shared.options.addrs.isNotEmpty && WKIM.shared.options.addrs.length > 1) {
      _tryNextAddress(baseUrl);
    } else {
      // 单地址或无备用地址时，使用重连管理器
      Timer(const Duration(milliseconds: 1000), () {
        ReconnectManager.shared.onConnectFailed();
      });
    }
  }

  /// 尝试下一个地址
  void _tryNextAddress(String failedUrl) async {
    // 先检查网络状态
    bool networkAvailable = await ReconnectManager.shared.checkNetworkStatusNow();
    if (!networkAvailable) {
      Logs.connection("地址 $failedUrl 连接失败，但网络不可用，等待网络恢复");
      setConnectionStatus(WKConnectStatus.noNetwork);
      ReconnectManager.shared.startNetworkMonitoring();
      return;
    }

    final addrs = WKIM.shared.options.addrs;
    final currentIndex = WKIM.shared.options.addrIndex;

    // 记录失败的地址
    Logs.connection("地址 $failedUrl 连接失败，网络正常，尝试下一个地址");

    // 检查是否已经尝试过所有地址
    if (_hasTriedAllAddresses()) {
      Logs.connection("所有地址都已尝试过，开始重连流程");
      _resetAddressAttempts();
      Timer(const Duration(seconds: 2), () {
        ReconnectManager.shared.onConnectFailed();
      });
      return;
    }

    // 切换到下一个地址
    final nextIndex = currentIndex % addrs.length;
    final rawAddr = addrs[nextIndex].trim();
    WKIM.shared.options.addrIndex = (nextIndex + 1) % addrs.length;

    // 确保地址格式正确
    String nextAddr = rawAddr;
    if (!rawAddr.startsWith("ws://") && !rawAddr.startsWith("wss://")) {
      nextAddr = "wss://$rawAddr";
    }

    // 移除可能的异常字符
    nextAddr = nextAddr.replaceAll(RegExp(r'[#\s]'), '');

    // 验证端口号，移除异常的:0端口
    if (nextAddr.contains(':0#') || nextAddr.endsWith(':0')) {
      nextAddr = nextAddr.replaceAll(RegExp(r':0#?$'), '');
    }

    Logs.connection("快速切换到下一个地址: $nextAddr (索引: $nextIndex)");

    // 记录尝试的地址
    _recordAddressAttempt(nextAddr);

    // 短暂延迟后尝试下一个地址
    Timer(const Duration(milliseconds: 500), () {
      if (isDisconnection) {
        _socketConnect(nextAddr);
      }
    });
  }

  // 地址尝试记录
  final Set<String> _attemptedAddresses = <String>{};
  int _currentRoundAttempts = 0;

  /// 记录尝试的地址
  void _recordAddressAttempt(String addr) {
    _attemptedAddresses.add(addr);
    _currentRoundAttempts++;
  }

  /// 检查是否已经尝试过所有地址
  bool _hasTriedAllAddresses() {
    final addrs = WKIM.shared.options.addrs;
    return _currentRoundAttempts >= addrs.length;
  }

  /// 重置地址尝试记录
  void _resetAddressAttempts() {
    _attemptedAddresses.clear();
    _currentRoundAttempts = 0;
    WKIM.shared.options.addrIndex = 0;
  }

  /// 安全地更新发送中消息状态
  void _updateSendingMsgFailSafely() {
    try {
      // 检查数据库是否可用
      if (WKDBHelper.shared.getDB() != null) {
        // 登出时更新消息状态，不启动重发管理器
        WKIM.shared.messageManager.updateSendingMsgFail(isInitialization: true).catchError((e) {
          print('安全更新发送中消息状态失败: $e');
        });
      } else {
        print('数据库不可用，跳过更新发送中消息状态');
      }
    } catch (e) {
      print('安全更新发送中消息状态异常: $e');
    }
  }

  testCutData(Uint8List data) {
    _cutDatas(data);
  }

  Uint8List? _cacheData;
  _cutDatas(Uint8List data) {
    if (_cacheData == null || _cacheData!.isEmpty) {
      _cacheData = data;
    } else {
      // 上次存在未解析完的消息
      Uint8List temp = Uint8List(_cacheData!.length + data.length);
      for (var i = 0; i < _cacheData!.length; i++) {
        temp[i] = _cacheData![i];
      }
      for (var i = 0; i < data.length; i++) {
        temp[i + _cacheData!.length] = data[i];
      }
      _cacheData = temp;
    }
    Uint8List lastMsgBytes = _cacheData!;
    int readLength = 0;
    while (lastMsgBytes.isNotEmpty && readLength != lastMsgBytes.length) {
      readLength = lastMsgBytes.length;
      ReadData readData = ReadData(lastMsgBytes);
      var b = readData.readUint8();
      var packetType = b >> 4;
      if (PacketType.values[(b >> 4)] == PacketType.pong) {
        Logs.debug('收到pong响应');
        // 只有在连接状态不是成功时才设置状态，避免频繁状态变更
        // setConnectionStatus(WKConnectStatus.success);
        unReceivePongCount = 0;
        Uint8List bytes = lastMsgBytes.sublist(1, lastMsgBytes.length);
        _cacheData = lastMsgBytes = bytes;
        pingSendIndex = 0;

        // /// 检测是否有未发送的消息
        // _checkSedingMsg();
      } else {
        if (packetType < 10) {
          if (lastMsgBytes.length < 5) {
            _cacheData = lastMsgBytes;
            break;
          }
          int remainingLength = readData.readVariableLength();
          if (remainingLength == -1) {
            //剩余长度被分包
            _cacheData = lastMsgBytes;
            break;
          }
          if (remainingLength > 1 << 21) {
            _cacheData = null;
            break;
          }
          List<int> bytes = encodeVariableLength(remainingLength);

          if (remainingLength + 1 + bytes.length > lastMsgBytes.length) {
            //半包情况
            _cacheData = lastMsgBytes;
          } else {
            Uint8List msg = lastMsgBytes.sublist(0, remainingLength + 1 + bytes.length);
            _decodePacket(msg);
            Uint8List temps = lastMsgBytes.sublist(msg.length, lastMsgBytes.length);
            _cacheData = lastMsgBytes = temps;
          }
        } else {
          _cacheData = null;
          // 数据包错误，重连
          connect();
          break;
        }
      }
    }
  }

  _decodePacket(Uint8List data) {
    var packet = WKIM.shared.options.proto.decode(data);
    Logs.debug('解码出包->$packet');
    unReceivePongCount = 0;
    if (packet.header.packetType == PacketType.connack) {
      var connackPacket = packet as ConnackPacket;
      if (connackPacket.reasonCode == 1) {
        Logs.connection('连接认证成功！节点ID: ${connackPacket.nodeId}');
        WKIM.shared.options.protoVersion = connackPacket.serviceProtoVersion;
        CryptoUtils.setServerKeyAndSalt(connackPacket.serverKey, connackPacket.salt);

        // 通知重连管理器连接成功
        ReconnectManager.shared.onConnectSuccess();

        setConnectionStatus(WKConnectStatus.success, reasoncode: connackPacket.reasonCode, info: ConnectionInfo(connackPacket.nodeId));

        // 发送心跳包
        sendPacket(PingPacket());

        // 启动心跳和网络监控
        _startHeartTimer();
        ReconnectManager.shared.startNetworkMonitoring();

        // 启动消息重发管理器
        OptimizedMessageResendManager.shared.start();

        // 开始消息同步
        try {
          // 开始消息同步
          WKIM.shared.conversationManager.setSyncConversation(() {
            setConnectionStatus(WKConnectStatus.syncCompleted);
            // 延迟重发消息，确保同步完成且连接稳定
            Timer(const Duration(seconds: 1), () {
              if (!isDisconnection) {
                Logs.info('消息同步完成，触发消息重发');
                OptimizedMessageResendManager.shared.resendAllMessages();
              }
            });
          });
        } catch (e) {
          Logs.error('消息同步失败: $e');
          // 消息同步失败时，仍然尝试重发消息
          Timer(const Duration(seconds: 2), () {
            if (!isDisconnection) {
              Logs.warn('消息同步失败，但仍尝试重发消息');
              OptimizedMessageResendManager.shared.resendAllMessages();
            }
          });
        }

        // 备用重发机制：缩短到3秒后检查并重发
        Timer(const Duration(seconds: 3), () {
          if (!isDisconnection) {
            int pendingCount = OptimizedMessageResendManager.shared.getSendingMessageCount();
            if (pendingCount > 0) {
              Logs.info('备用重发机制：检测到${pendingCount}条待发送消息，开始重发');
              OptimizedMessageResendManager.shared.resendAllMessages();
            }
          }
        });
      } else {
        setConnectionStatus(WKConnectStatus.fail, reasoncode: connackPacket.reasonCode);
        Logs.error('连接认证失败！错误码: ${connackPacket.reasonCode}');
        ReconnectManager.shared.onConnectFailed();
      }
    } else if (packet.header.packetType == PacketType.recv) {
      Logs.debug('收到消息');
      var recvPacket = packet as RecvPacket;
      _verifyRecvMsg(recvPacket);
      if (!recvPacket.header.noPersist) {
        _sendReceAckPacket(recvPacket.messageID, recvPacket.messageSeq, recvPacket.header);
      }
    } else if (packet.header.packetType == PacketType.sendack) {
      var sendack = packet as SendAckPacket;
      Logs.debug('收到发送确认：clientSeq=${sendack.clientSeq}, reasonCode=${sendack.reasonCode}');

      // 更新消息状态
      WKIM.shared.messageManager.updateSendResult(sendack.messageID, sendack.clientSeq, sendack.messageSeq, sendack.reasonCode);

      // 使用优化的重发管理器处理确认
      OptimizedMessageResendManager.shared.handleSendAck(sendack.clientSeq, sendack.reasonCode);
    } else if (packet.header.packetType == PacketType.disconnect) {
      var disconnectPacket = packet as DisconnectPacket;
      Logs.warn('服务器主动断开连接: reasonCode=${disconnectPacket.reasonCode}, reason=${disconnectPacket.reason}');

      // 根据断开原因决定是否重连
      bool shouldReconnect = _shouldReconnectAfterDisconnect(disconnectPacket.reasonCode, disconnectPacket.reason);

      if (shouldReconnect) {
        // 网络问题等可重连的情况，不清空重发队列
        disconnect(false);
        setConnectionStatus(WKConnectStatus.fail);
        ReconnectManager.shared.onConnectFailed();
      } else {
        // 认证失败、重复登录等不应重连的情况
        disconnect(true); // 清空重发队列
        setConnectionStatus(WKConnectStatus.kicked);
        Logs.error('服务器断开连接，停止重连: ${disconnectPacket.reason}');
      }
    } else if (packet.header.packetType == PacketType.pong) {
      Logs.debug('收到pong包响应');
      unReceivePongCount = 0;
    }
  }

  _closeAll() {
    Logs.connection("关闭所有连接资源");
    _stopHeartTimer();

    if (WKIM.shared.options.useWebSocket) {
      _webSocket?.sink.close();
      _webSocket = null;
    } else {
      _socket?.close();
      _socket = null;
    }
  }

  _sendReceAckPacket(BigInt messageID, int messageSeq, PacketHeader header) {
    RecvAckPacket ackPacket = RecvAckPacket();
    ackPacket.header.noPersist = header.noPersist;
    ackPacket.header.syncOnce = header.syncOnce;
    ackPacket.header.showUnread = header.showUnread;
    ackPacket.messageID = messageID;
    ackPacket.messageSeq = messageSeq;
    sendPacket(ackPacket);
  }

  _sendConnectPacket() async {
    CryptoUtils.init();
    var deviceID = await _getDeviceID();
    var connectPacket = ConnectPacket(
        uid: WKIM.shared.options.uid!,
        token: WKIM.shared.options.token!,
        version: WKIM.shared.options.protoVersion,
        clientKey: base64Encode(CryptoUtils.dhPublicKey!),
        deviceID: deviceID,
        clientTimestamp: DateTime.now().millisecondsSinceEpoch);
    connectPacket.deviceFlag = WKIM.shared.deviceFlagApp;
    sendPacket(connectPacket);
  }

  Future<void> sendPacket(Packet packet) async {
    if (isDisconnection) {
      Logs.debug('连接已断开，跳过发送包: ${packet.runtimeType}');

      // 如果是SendPacket，需要通知重发管理器发送失败
      if (packet is SendPacket) {
        Logs.info('断网时发送失败，通知重发管理器: clientSeq=${packet.clientSeq}');
        // 延迟一点时间模拟网络发送失败
        Timer(const Duration(milliseconds: 100), () {
          OptimizedMessageResendManager.shared.handleSendAck(packet.clientSeq, WKSendMsgResult.sendFail);
        });
      }
      return;
    }

    var data = WKIM.shared.options.proto.encode(packet);
    if (WKIM.shared.options.useWebSocket) {
      if (_webSocket != null) {
        try {
          _webSocket!.sink.add(data);
        } catch (e) {
          Logs.error('WebSocket发送数据失败: $e');
          isDisconnection = true;
          setConnectionStatus(WKConnectStatus.fail);

          // 如果是SendPacket发送失败，通知重发管理器
          if (packet is SendPacket) {
            Logs.info('WebSocket发送失败，通知重发管理器: clientSeq=${packet.clientSeq}');
            OptimizedMessageResendManager.shared.handleSendAck(packet.clientSeq, WKSendMsgResult.sendFail);
          }

          ReconnectManager.shared.onConnectFailed();
        }
      }
    } else {
      try {
        await _socket?.send(data);
      } catch (e) {
        Logs.error('Socket发送数据失败: $e');
        isDisconnection = true;
        setConnectionStatus(WKConnectStatus.fail);

        // 如果是SendPacket发送失败，通知重发管理器
        if (packet is SendPacket) {
          Logs.info('Socket发送失败，通知重发管理器: clientSeq=${packet.clientSeq}');
          OptimizedMessageResendManager.shared.handleSendAck(packet.clientSeq, WKSendMsgResult.sendFail);
        }

        ReconnectManager.shared.onConnectFailed();
      }
    }
  }

  _startHeartTimer() {
    _stopHeartTimer();
    final config = WKIM.shared.options.networkConfig;

    heartTimer = Timer.periodic(Duration(seconds: config.heartbeatInterval), (timer) {
      if (isDisconnection) {
        _stopHeartTimer();
        return;
      }

      // 检查心跳超时 - 使用更宽松的策略
      if (unReceivePongCount >= config.heartbeatTimeoutCount + 2) {
        // 多给两次机会，减少网络抖动导致的误判
        Logs.connection('心跳超时，未收到 ${config.heartbeatTimeoutCount + 2} 次pong响应，开始重连');
        _stopHeartTimer();
        isDisconnection = true;
        setConnectionStatus(WKConnectStatus.fail);
        ReconnectManager.shared.onConnectFailed();
        return;
      }

      // 发送心跳
      Logs.debug('发送心跳包，当前未响应次数: $unReceivePongCount');
      unReceivePongCount++;
      sendPacket(PingPacket());
    });
  }

  _stopHeartTimer() {
    if (heartTimer != null) {
      heartTimer!.cancel();
      heartTimer = null;
    }
  }

  sendMessage(WKMsg wkMsg) {
    SendPacket packet = SendPacket();
    packet.setting = wkMsg.setting;
    packet.header.noPersist = wkMsg.header.noPersist;
    packet.header.showUnread = wkMsg.header.redDot;
    packet.header.syncOnce = wkMsg.header.syncOnce;
    packet.channelID = wkMsg.channelID;
    packet.channelType = wkMsg.channelType;
    packet.clientSeq = wkMsg.clientSeq;
    packet.clientMsgNO = wkMsg.clientMsgNO;
    packet.topic = wkMsg.topicID;
    packet.expire = wkMsg.expireTime;
    packet.payload = wkMsg.content;

    // 确定消息优先级
    MessagePriority priority = _determineMessagePriority(wkMsg);

    // 使用优化的重发管理器
    OptimizedMessageResendManager.shared.addSendingMessage(packet, priority: priority);
    sendPacket(packet);
  }

  /// 确定消息优先级
  MessagePriority _determineMessagePriority(WKMsg wkMsg) {
    // 根据消息类型确定优先级
    switch (wkMsg.contentType) {
      case WkMessageContentType.text:
        return MessagePriority.normal;
      case WkMessageContentType.image:
      case WkMessageContentType.video:
      case WkMessageContentType.voice:
        return MessagePriority.low; // 媒体消息优先级较低
      case WkMessageContentType.card:
        return MessagePriority.high; // 卡片消息优先级较高
      default:
        return MessagePriority.normal;
    }
  }

  /// 判断服务器断开连接后是否应该重连
  bool _shouldReconnectAfterDisconnect(int reasonCode, String reason) {
    // 根据断开原因判断是否应该重连
    switch (reasonCode) {
      case 1: // 认证失败
        Logs.error('认证失败，不重连: $reason');
        return false;
      case 2: // 重复登录
        Logs.error('重复登录，不重连: $reason');
        return false;
      case 3: // 被踢下线
        Logs.error('被踢下线，不重连: $reason');
        return false;
      case 4: // 账号被禁用
        Logs.error('账号被禁用，不重连: $reason');
        return false;
      case 12: // 在其他设备登录
        Logs.error('在其他设备登录，不重连: $reason');
        return false;
      case 0: // 正常断开或网络问题
      default:
        // 只有明确的网络问题才重连
        if (reasonCode == 0 || reason.contains('network') || reason.contains('timeout')) {
          Logs.info('网络问题或服务器重启，可以重连: reasonCode=$reasonCode, reason=$reason');
          return true;
        } else {
          Logs.warn('未知断开原因，为安全起见不重连: reasonCode=$reasonCode, reason=$reason');
          return false;
        }
    }
  }

  _verifyRecvMsg(RecvPacket recvMsg) {
    StringBuffer sb = StringBuffer();
    sb.writeAll([
      recvMsg.messageID,
      recvMsg.messageSeq,
      recvMsg.clientMsgNO,
      recvMsg.messageTime,
      recvMsg.fromUID,
      recvMsg.channelID,
      recvMsg.channelType,
      recvMsg.payload
    ]);
    var encryptContent = sb.toString();
    var result = CryptoUtils.aesEncrypt(encryptContent);
    String localMsgKey = CryptoUtils.generateMD5(result);
    if (recvMsg.msgKey != localMsgKey) {
      Logs.error('非法消息-->期望msgKey：$localMsgKey，实际msgKey：${recvMsg.msgKey}');
      return;
    } else {
      recvMsg.payload = CryptoUtils.aesDecrypt(recvMsg.payload);
      Logs.debug(recvMsg.toString());
      _saveRecvMsg(recvMsg);
    }
  }

  _saveRecvMsg(RecvPacket recvMsg) async {
    WKMsg msg = WKMsg();
    msg.header.redDot = recvMsg.header.showUnread;
    msg.header.noPersist = recvMsg.header.noPersist;
    msg.header.syncOnce = recvMsg.header.syncOnce;
    msg.setting = recvMsg.setting;
    msg.channelType = recvMsg.channelType;
    msg.channelID = recvMsg.channelID;
    msg.content = recvMsg.payload;
    msg.messageID = recvMsg.messageID.toString();
    msg.messageSeq = recvMsg.messageSeq;
    msg.timestamp = recvMsg.messageTime;
    msg.fromUID = recvMsg.fromUID;
    msg.clientMsgNO = recvMsg.clientMsgNO;
    msg.expireTime = recvMsg.expire;
    if (msg.expireTime > 0) {
      msg.expireTimestamp = msg.expireTime + msg.timestamp;
    }
    msg.status = WKSendMsgResult.sendSuccess;
    msg.topicID = recvMsg.topic;
    msg.orderSeq = await WKIM.shared.messageManager.getMessageOrderSeq(msg.messageSeq, msg.channelID, msg.channelType);
    dynamic contentJson = jsonDecode(msg.content);
    msg.contentType = WKDBConst.readInt(contentJson, 'type');
    msg.isDeleted = _isDeletedMsg(contentJson);
    msg.messageContent = WKIM.shared.messageManager.getMessageModel(msg.contentType, contentJson);
    WKChannel? fromChannel = await WKIM.shared.channelManager.getChannel(msg.fromUID, WKChannelType.personal);
    if (fromChannel != null) {
      msg.setFrom(fromChannel);
    }
    if (msg.channelType == WKChannelType.group) {
      WKChannelMember? memberChannel = await WKIM.shared.channelMemberManager.getMember(msg.channelID, WKChannelType.group, msg.fromUID);
      if (memberChannel != null) {
        msg.setMemberOfFrom(memberChannel);
      }
    }
    WKIM.shared.messageManager.parsingMsg(msg);
    if (msg.isDeleted == 0 && !msg.header.noPersist && msg.contentType != WkMessageContentType.insideMsg) {
      int row = await WKIM.shared.messageManager.saveMsg(msg);
      msg.clientSeq = row;
      WKUIConversationMsg? uiMsg = await WKIM.shared.conversationManager.saveWithLiMMsg(msg, msg.header.redDot ? 1 : 0);
      if (uiMsg != null) {
        List<WKUIConversationMsg> list = [];
        list.add(uiMsg);
        WKIM.shared.conversationManager.setRefreshUIMsgs(list);
      }
    } else {
      Logs.debug('消息不能存库:is_deleted=${msg.isDeleted},no_persist=${msg.header.noPersist},content_type:${msg.contentType}');
    }
    if (msg.contentType != WkMessageContentType.insideMsg) {
      List<WKMsg> list = [];
      list.add(msg);
      WKIM.shared.messageManager.pushNewMsg(list);
    }
  }

  int _isDeletedMsg(dynamic jsonObject) {
    int isDelete = 0;
    if (jsonObject != null) {
      var visibles = jsonObject['visibles'];
      if (visibles != null && visibles is List) {
        bool isIncludeLoginUser = false;
        for (int i = 0, size = visibles.length; i < size; i++) {
          if (visibles[i] == WKIM.shared.options.uid) {
            isIncludeLoginUser = true;
            break;
          }
        }
        isDelete = isIncludeLoginUser ? 0 : 1;
      }
    }
    return isDelete;
  }
}

Future<String> _getDeviceID() async {
  SharedPreferences preferences = await SharedPreferences.getInstance();
  String wkUid = WKIM.shared.options.uid!;
  String key = "${wkUid}_device_id";
  var deviceID = preferences.getString(key);
  if (deviceID == null || deviceID == "") {
    deviceID = const Uuid().v4().toString().replaceAll("-", "");
    preferences.setString(key, deviceID);
  }
  return "${deviceID}F";
}

class ConnectionInfo {
  int nodeId;
  ConnectionInfo(this.nodeId);
}
