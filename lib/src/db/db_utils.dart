import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import '../common/logs.dart';
import 'wk_db_helper.dart';

/// 数据库工具类 - 统一管理数据库操作
class DatabaseUtils {
  /// 执行数据库查询操作
  static Future<T?> executeQuery<T>(
    Future<T> Function(Database db) operation, {
    T? defaultValue,
    String? operationName,
  }) async {
    final db = WKDBHelper.shared.getDB();
    if (db == null) {
      Logs.error(
          'Database not initialized for operation: ${operationName ?? 'unknown'}');
      return defaultValue;
    }

    try {
      return await operation(db);
    } catch (e, stackTrace) {
      Logs.error(
          'Database operation failed: ${operationName ?? 'unknown'}, error: $e');
      Logs.debug('Stack trace: $stackTrace');
      return defaultValue;
    }
  }

  /// 执行事务操作
  static Future<bool> executeTransaction(
    Future<void> Function(Transaction txn) operation, {
    String? operationName,
  }) async {
    return await executeQuery<bool>((db) async {
          await db.transaction(operation);
          return true;
        }, defaultValue: false, operationName: operationName) ??
        false;
  }

  /// 批量插入操作
  static Future<bool> batchInsert(
    String table,
    List<Map<String, dynamic>> dataList, {
    ConflictAlgorithm conflictAlgorithm = ConflictAlgorithm.replace,
    String? operationName,
  }) async {
    if (dataList.isEmpty) return true;

    return await executeTransaction((txn) async {
      for (var data in dataList) {
        await txn.insert(table, data, conflictAlgorithm: conflictAlgorithm);
      }
    }, operationName: operationName ?? 'batchInsert_$table');
  }

  /// 批量更新操作
  static Future<bool> batchUpdate(
    String table,
    List<Map<String, dynamic>> dataList,
    String whereClause,
    List<dynamic> Function(Map<String, dynamic> data) whereArgsBuilder, {
    String? operationName,
  }) async {
    if (dataList.isEmpty) return true;

    return await executeTransaction((txn) async {
      for (var data in dataList) {
        await txn.update(
          table,
          data,
          where: whereClause,
          whereArgs: whereArgsBuilder(data),
        );
      }
    }, operationName: operationName ?? 'batchUpdate_$table');
  }
}

/// 安全的数据读取工具类
class SafeDataReader {
  /// 安全读取整数
  static int readInt(dynamic data, String key, {int defaultValue = 0}) {
    if (data == null) {
      Logs.debug('Data is null when reading key: $key');
      return defaultValue;
    }

    if (data is! Map) {
      Logs.debug('Data is not a Map when reading key: $key');
      return defaultValue;
    }

    if (!data.containsKey(key)) {
      Logs.debug('Key not found: $key');
      return defaultValue;
    }

    dynamic result = data[key];
    if (result == null) {
      return defaultValue;
    }

    // 如果已经是整数，直接返回
    if (result is int) {
      return result;
    }

    // 如果是字符串，尝试解析
    if (result is String) {
      if (result.isEmpty) {
        return defaultValue;
      }
      try {
        return int.parse(result);
      } catch (e) {
        Logs.error(
            'Failed to parse int from string: $result for key: $key, error: $e');
        return defaultValue;
      }
    }

    // 其他类型，尝试转换
    try {
      return int.parse(result.toString());
    } catch (e) {
      Logs.error('Failed to convert to int: $result for key: $key, error: $e');
      return defaultValue;
    }
  }

  /// 安全读取字符串
  static String readString(dynamic data, String key,
      {String defaultValue = ''}) {
    if (data == null) {
      Logs.debug('Data is null when reading key: $key');
      return defaultValue;
    }

    if (data is! Map) {
      Logs.debug('Data is not a Map when reading key: $key');
      return defaultValue;
    }

    if (!data.containsKey(key)) {
      Logs.debug('Key not found: $key');
      return defaultValue;
    }

    dynamic result = data[key];
    if (result == null) {
      return defaultValue;
    }

    return result.toString();
  }

  /// 安全读取动态数据（JSON）
  static dynamic readDynamic(dynamic data, String key, {dynamic defaultValue}) {
    String jsonStr = readString(data, key);
    if (jsonStr.isEmpty) {
      return defaultValue;
    }

    return JsonUtils.safeDecode(jsonStr) ?? defaultValue;
  }

  /// 安全读取布尔值
  static bool readBool(dynamic data, String key, {bool defaultValue = false}) {
    int intValue = readInt(data, key, defaultValue: defaultValue ? 1 : 0);
    return intValue == 1;
  }

  /// 安全读取双精度浮点数
  static double readDouble(dynamic data, String key,
      {double defaultValue = 0.0}) {
    if (data == null || data is! Map || !data.containsKey(key)) {
      return defaultValue;
    }

    dynamic result = data[key];
    if (result == null) {
      return defaultValue;
    }

    if (result is double) {
      return result;
    }

    if (result is int) {
      return result.toDouble();
    }

    try {
      return double.parse(result.toString());
    } catch (e) {
      Logs.error(
          'Failed to convert to double: $result for key: $key, error: $e');
      return defaultValue;
    }
  }
}

/// JSON 工具类
class JsonUtils {
  /// 安全的 JSON 解码
  static dynamic safeDecode(String jsonStr) {
    if (jsonStr.isEmpty) {
      return null;
    }

    try {
      return jsonDecode(jsonStr);
    } catch (e) {
      Logs.error(
          'JSON decode failed: ${jsonStr.length > 100 ? '${jsonStr.substring(0, 100)}...' : jsonStr}, error: $e');
      return null;
    }
  }

  /// 安全的 JSON 编码
  static String safeEncode(dynamic data) {
    if (data == null) {
      return '';
    }

    try {
      return jsonEncode(data);
    } catch (e) {
      Logs.error('JSON encode failed: $data, error: $e');
      return '';
    }
  }

  /// 检查是否为有效的 JSON 字符串
  static bool isValidJson(String str) {
    if (str.isEmpty) return false;

    try {
      final parsed = jsonDecode(str);
      return parsed is Map || parsed is List;
    } catch (e) {
      return false;
    }
  }
}

/// 数据大小管理工具
class DataSizeManager {
  static const int MAX_EXTRA_SIZE = 100 * 1024; // 100KB
  static const int MAX_CONTENT_SIZE = 1024 * 1024; // 1MB
  static const int WARNING_SIZE = 50 * 1024; // 50KB

  /// 限制额外数据大小
  static String limitExtraData(dynamic data, {int? maxSize}) {
    if (data == null) return '';

    String jsonStr = data.toString();
    int limit = maxSize ?? MAX_EXTRA_SIZE;

    if (jsonStr.length <= limit) {
      return jsonStr;
    }

    Logs.warn(
        'Extra data too large (${jsonStr.length} bytes), truncating to $limit bytes');

    // 尝试保持 JSON 结构完整性
    if (JsonUtils.isValidJson(jsonStr)) {
      try {
        // 如果是 JSON，尝试压缩或截断
        var decoded = JsonUtils.safeDecode(jsonStr);
        if (decoded is Map) {
          // 对于 Map，可以移除一些非关键字段
          Map<String, dynamic> mapData = Map<String, dynamic>.from(decoded);
          return _truncateMapData(mapData, limit);
        }
      } catch (e) {
        Logs.error('Failed to process large JSON data: $e');
      }
    }

    return jsonStr.substring(0, limit);
  }

  /// 截断 Map 数据
  static String _truncateMapData(Map<String, dynamic> data, int maxSize) {
    // 优先保留重要字段
    const importantKeys = ['id', 'type', 'status', 'timestamp'];
    Map<String, dynamic> result = {};

    // 先添加重要字段
    for (String key in importantKeys) {
      if (data.containsKey(key)) {
        result[key] = data[key];
      }
    }

    // 添加其他字段，直到达到大小限制
    String currentJson = JsonUtils.safeEncode(result);
    for (var entry in data.entries) {
      if (!importantKeys.contains(entry.key)) {
        var tempResult = Map<String, dynamic>.from(result);
        tempResult[entry.key.toString()] = entry.value;
        String tempJson = JsonUtils.safeEncode(tempResult);

        if (tempJson.length > maxSize) {
          break;
        }

        result = tempResult;
        currentJson = tempJson;
      }
    }

    return currentJson;
  }

  /// 检查数据大小并发出警告
  static void checkDataSize(String data, String context) {
    if (data.length > WARNING_SIZE) {
      Logs.warn('Large data detected in $context: ${data.length} bytes');
    }
  }
}

/// SQL 构建工具
class SqlBuilder {
  /// 生成占位符
  static String getPlaceholders(int count) {
    if (count <= 0) return '';

    return List.filled(count, '?').join(', ');
  }

  /// 构建 IN 查询条件
  static String buildInCondition(String column, int count) {
    if (count <= 0) return '$column IN ()';

    return '$column IN (${getPlaceholders(count)})';
  }

  /// 构建批量插入 SQL
  static String buildBatchInsertSql(
      String table, List<String> columns, int rowCount) {
    if (columns.isEmpty || rowCount <= 0) {
      throw ArgumentError('Columns and rowCount must be greater than 0');
    }

    String columnStr = columns.join(', ');
    String valueStr =
        List.filled(rowCount, '(${getPlaceholders(columns.length)})')
            .join(', ');

    return 'INSERT OR REPLACE INTO $table ($columnStr) VALUES $valueStr';
  }
}
