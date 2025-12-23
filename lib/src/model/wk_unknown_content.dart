
import '../../flutter_wukongim_sdk.dart';

class WKUnknownContent extends WKMessageContent {
  WKUnknownContent() {
    contentType = WkMessageContentType.unknown;
  }
  @override
  String displayText() {
    return '[未知消息]';
  }
}
