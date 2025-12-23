
import '../flutter_wukongim_sdk.dart';
import 'common/options.dart';
import 'common/logs.dart';
import 'manager/connect_manager.dart';
import 'model/wk_card_content.dart';

class WKIM {
  WKIM._privateConstructor();
  int deviceFlagApp = 0;
  static final WKIM _instance = WKIM._privateConstructor();

  static WKIM get shared => _instance;
  Model runMode = Model.app;
  Options options = Options();

  Future<bool> setup(Options opts) async {
    options = opts;
    deviceFlagApp = opts.deviceFlag;

    // 根据环境配置日志和其他参数
    options.configureForEnvironment();

    Logs.info('WKIM SDK 初始化开始，环境: ${opts.environment}');

    _initNormalMsgContent();

    if (isApp()) {
      bool result = await WKDBHelper.shared.init();
      if (result) {
        await messageManager.updateSendingMsgFail(isInitialization: true);
        Logs.info('WKIM SDK 初始化成功');
      } else {
        Logs.error('数据库初始化失败');
      }
      return result;
    }

    Logs.info('WKIM SDK 初始化完成（非App模式）');
    return true;
  }

  _initNormalMsgContent() {
    messageManager.registerMsgContent(WkMessageContentType.text,
        (dynamic data) {
      return WKTextContent('').decodeJson(data);
    });
    messageManager.registerMsgContent(WkMessageContentType.card,
        (dynamic data) {
      return WKCardContent('', '').decodeJson(data);
    });
    messageManager.registerMsgContent(WkMessageContentType.image,
        (dynamic data) {
      return WKImageContent(
        0,
        0,
      ).decodeJson(data);
    });
    messageManager.registerMsgContent(WkMessageContentType.voice,
        (dynamic data) {
      return WKVoiceContent(
        0,
      ).decodeJson(data);
    });
    messageManager.registerMsgContent(WkMessageContentType.video,
        (dynamic data) {
      return WKVideoContent().decodeJson(data);
    });
  }

  @Deprecated('Use Options deviceFlag')
  void setDeviceFlag(int deviceFlag) {
    deviceFlagApp = deviceFlag;
  }

  bool isApp() {
    return runMode == Model.app;
  }

  WKConnectionManager connectionManager = WKConnectionManager.shared;
  WKMessageManager messageManager = WKMessageManager.shared;
  WKConversationManager conversationManager = WKConversationManager.shared;
  WKChannelManager channelManager = WKChannelManager.shared;
  WKChannelMemberManager channelMemberManager = WKChannelMemberManager.shared;
  WKReminderManager reminderManager = WKReminderManager.shared;
  WKCMDManager cmdManager = WKCMDManager.shared;

  // 新增的管理器
  ReconnectManager get reconnectManager => ReconnectManager.shared;
  MessageSyncManager get messageSyncManager => MessageSyncManager.shared;

  OptimizedMessageResendManager get optimizedMessageResendManager =>
      OptimizedMessageResendManager.shared;

  /// 强制重置连接状态
  /// 用于解决首次连接失败后无法重连的问题
  /// 建议在连接长时间失败后调用此方法
  void forceResetConnection() {
    Logs.info('执行强制重置连接状态');
    connectionManager.forceReset();
  }
}
