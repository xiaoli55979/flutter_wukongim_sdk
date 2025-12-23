
import '../../flutter_wukongim_sdk.dart';

class WKTextContent extends WKMessageContent {
  WKTextContent(content) {
    contentType = WkMessageContentType.text;
    this.content = content;
  }
  @override
  Map<String, dynamic> encodeJson() {
    return {"content": content};
  }

  @override
  WKMessageContent decodeJson(Map<String, dynamic> json) {
    content = WKDBConst.readString(json, 'content');
    return this;
  }

  @override
  String displayText() {
    return content;
  }

  @override
  String searchableWord() {
    return content;
  }
}
