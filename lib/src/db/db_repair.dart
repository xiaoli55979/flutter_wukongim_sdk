import 'dart:async';
import 'package:sqflite/sqflite.dart';
import '../common/logs.dart';

import 'db_utils.dart';

/// 数据库修复和维护工具
class DatabaseRepair {
  static const String _tag = 'DB_REPAIR';

  /// 检查并修复数据库
  static Future<bool> checkAndRepairDatabase() async {
    Logs.info('开始数据库检查和修复', _tag);

    try {
      bool allPassed = true;

      // 1. 检查数据库连接
      if (!await _checkDatabaseConnection()) {
        Logs.error('数据库连接检查失败', _tag);
        allPassed = false;
      }

      // 2. 检查表结构
      if (!await _checkTableStructure()) {
        Logs.error('表结构检查失败', _tag);
        allPassed = false;
      }

      // 3. 检查数据完整性
      if (!await _checkDataIntegrity()) {
        Logs.error('数据完整性检查失败', _tag);
        allPassed = false;
      }

      // 4. 清理无效数据
      if (!await _cleanInvalidData()) {
        Logs.error('数据清理失败', _tag);
        allPassed = false;
      }

      // 5. 优化数据库
      if (!await _optimizeDatabase()) {
        Logs.error('数据库优化失败', _tag);
        allPassed = false;
      }

      Logs.info('数据库检查和修复完成，结果: ${allPassed ? '成功' : '部分失败'}', _tag);
      return allPassed;
    } catch (e, stackTrace) {
      Logs.error('数据库检查和修复过程中发生异常: $e', _tag);
      Logs.debug('Stack trace: $stackTrace', _tag);
      return false;
    }
  }

  /// 检查数据库连接
  static Future<bool> _checkDatabaseConnection() async {
    return await DatabaseUtils.executeQuery<bool>((db) async {
          // 执行简单查询测试连接
          await db.rawQuery('SELECT 1');
          return true;
        }, defaultValue: false, operationName: 'checkConnection') ??
        false;
  }

  /// 检查表结构
  static Future<bool> _checkTableStructure() async {
    return await DatabaseUtils.executeQuery<bool>((db) async {
          // 检查必要的表是否存在
          const requiredTables = [
            'message',
            'conversation',
            'channel',
            'channel_members',
            'message_extra',
            'message_reaction'
          ];

          for (String table in requiredTables) {
            var result = await db.rawQuery(
                "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
                [table]);

            if (result.isEmpty) {
              Logs.error('缺少必要的表: $table', _tag);
              return false;
            }
          }

          Logs.info('表结构检查通过', _tag);
          return true;
        }, defaultValue: false, operationName: 'checkTableStructure') ??
        false;
  }

  /// 检查数据完整性
  static Future<bool> _checkDataIntegrity() async {
    return await DatabaseUtils.executeQuery<bool>((db) async {
          bool allPassed = true;

          // 检查消息表中的无效数据
          var invalidMessages = await db.rawQuery('''
        SELECT COUNT(*) as count FROM message 
        WHERE channel_id = '' OR from_uid = '' OR client_msg_no = ''
      ''');

          int invalidCount =
              SafeDataReader.readInt(invalidMessages.first, 'count');
          if (invalidCount > 0) {
            Logs.warn('发现 $invalidCount 条无效消息记录', _tag);
            allPassed = false;
          }

          // 检查会话表中的无效数据
          var invalidConversations = await db.rawQuery('''
        SELECT COUNT(*) as count FROM conversation 
        WHERE channel_id = ''
      ''');

          invalidCount =
              SafeDataReader.readInt(invalidConversations.first, 'count');
          if (invalidCount > 0) {
            Logs.warn('发现 $invalidCount 条无效会话记录', _tag);
            allPassed = false;
          }

          // 检查孤立的消息扩展数据
          var orphanedExtras = await db.rawQuery('''
        SELECT COUNT(*) as count FROM message_extra 
        WHERE message_id NOT IN (SELECT message_id FROM message WHERE message_id != '')
      ''');

          invalidCount = SafeDataReader.readInt(orphanedExtras.first, 'count');
          if (invalidCount > 0) {
            Logs.warn('发现 $invalidCount 条孤立的消息扩展记录', _tag);
            allPassed = false;
          }

          return allPassed;
        }, defaultValue: false, operationName: 'checkDataIntegrity') ??
        false;
  }

  /// 清理无效数据
  static Future<bool> _cleanInvalidData() async {
    return await DatabaseUtils.executeTransaction((txn) async {
      int cleanedCount = 0;

      // 清理空的消息记录
      int result = await txn.rawDelete('''
        DELETE FROM message 
        WHERE channel_id = '' OR from_uid = '' OR client_msg_no = ''
      ''');
      cleanedCount += result;

      if (result > 0) {
        Logs.info('清理了 $result 条无效消息记录', _tag);
      }

      // 清理空的会话记录
      result = await txn.rawDelete('''
        DELETE FROM conversation 
        WHERE channel_id = ''
      ''');
      cleanedCount += result;

      if (result > 0) {
        Logs.info('清理了 $result 条无效会话记录', _tag);
      }

      // 清理孤立的消息扩展数据
      result = await txn.rawDelete('''
        DELETE FROM message_extra 
        WHERE message_id NOT IN (SELECT message_id FROM message WHERE message_id != '')
      ''');
      cleanedCount += result;

      if (result > 0) {
        Logs.info('清理了 $result 条孤立的消息扩展记录', _tag);
      }

      // 清理孤立的消息反应数据
      result = await txn.rawDelete('''
        DELETE FROM message_reaction 
        WHERE message_id NOT IN (SELECT message_id FROM message WHERE message_id != '')
      ''');
      cleanedCount += result;

      if (result > 0) {
        Logs.info('清理了 $result 条孤立的消息反应记录', _tag);
      }

      // 清理过大的扩展数据
      result = await txn.rawUpdate('''
        UPDATE message SET extra = '' 
        WHERE LENGTH(extra) > 1000000
      ''');

      if (result > 0) {
        Logs.info('清理了 $result 条过大的消息扩展数据', _tag);
      }

      result = await txn.rawUpdate('''
        UPDATE conversation SET extra = '' 
        WHERE LENGTH(extra) > 1000000
      ''');

      if (result > 0) {
        Logs.info('清理了 $result 条过大的会话扩展数据', _tag);
      }

      Logs.info('数据清理完成，总计清理 $cleanedCount 条记录', _tag);
    }, operationName: 'cleanInvalidData');
  }

  /// 优化数据库
  static Future<bool> _optimizeDatabase() async {
    return await DatabaseUtils.executeQuery<bool>((db) async {
          try {
            // 重建索引
            await _rebuildIndexes(db);

            // 分析表统计信息
            await db.execute('ANALYZE');

            // 清理数据库碎片
            await db.execute('VACUUM');

            Logs.info('数据库优化完成', _tag);
            return true;
          } catch (e) {
            Logs.error('数据库优化失败: $e', _tag);
            return false;
          }
        }, defaultValue: false, operationName: 'optimizeDatabase') ??
        false;
  }

  /// 重建索引
  static Future<void> _rebuildIndexes(Database db) async {
    const indexes = [
      'CREATE INDEX IF NOT EXISTS msg_channel_index ON message (channel_id,channel_type)',
      'CREATE UNIQUE INDEX IF NOT EXISTS msg_client_msg_no_index ON message (client_msg_no)',
      'CREATE INDEX IF NOT EXISTS searchable_word_index ON message (searchable_word)',
      'CREATE INDEX IF NOT EXISTS type_index ON message (type)',
      'CREATE INDEX IF NOT EXISTS msg_order_seq_index ON message (order_seq)',
      'CREATE INDEX IF NOT EXISTS msg_timestamp_index ON message (timestamp)',
      'CREATE UNIQUE INDEX IF NOT EXISTS conversation_msg_index_channel ON conversation (channel_id, channel_type)',
      'CREATE INDEX IF NOT EXISTS conversation_msg_index_time ON conversation (last_msg_timestamp)',
      'CREATE UNIQUE INDEX IF NOT EXISTS channel_index ON channel (channel_id, channel_type)',
      'CREATE UNIQUE INDEX IF NOT EXISTS channel_members_index ON channel_members (channel_id,channel_type,member_uid)',
      'CREATE UNIQUE INDEX IF NOT EXISTS chat_msg_reaction_index ON message_reaction (message_id,uid,emoji)',
    ];

    for (String indexSql in indexes) {
      try {
        await db.execute(indexSql);
      } catch (e) {
        Logs.warn('创建索引失败: $indexSql, error: $e', _tag);
      }
    }

    Logs.info('索引重建完成', _tag);
  }

  /// 获取数据库统计信息
  static Future<Map<String, dynamic>> getDatabaseStats() async {
    return await DatabaseUtils.executeQuery<Map<String, dynamic>>((db) async {
          Map<String, dynamic> stats = {};

          // 获取各表的记录数
          const tables = [
            'message',
            'conversation',
            'channel',
            'channel_members',
            'message_extra',
            'message_reaction'
          ];

          for (String table in tables) {
            try {
              var result =
                  await db.rawQuery('SELECT COUNT(*) as count FROM $table');
              stats['${table}_count'] =
                  SafeDataReader.readInt(result.first, 'count');
            } catch (e) {
              stats['${table}_count'] = -1;
              Logs.error('获取表 $table 统计信息失败: $e', _tag);
            }
          }

          // 获取数据库大小信息
          try {
            var result = await db.rawQuery('PRAGMA page_count');
            int pageCount = SafeDataReader.readInt(result.first, 'page_count');

            result = await db.rawQuery('PRAGMA page_size');
            int pageSize = SafeDataReader.readInt(result.first, 'page_size');

            stats['database_size_bytes'] = pageCount * pageSize;
            stats['database_size_mb'] =
                (pageCount * pageSize / (1024 * 1024)).toStringAsFixed(2);
          } catch (e) {
            Logs.error('获取数据库大小信息失败: $e', _tag);
          }

          return stats;
        }, defaultValue: {}, operationName: 'getDatabaseStats') ??
        {};
  }

  /// 备份关键数据
  static Future<bool> backupCriticalData() async {
    // 这里可以实现关键数据的备份逻辑
    // 比如导出重要的消息和会话数据到JSON文件
    Logs.info('数据备份功能待实现', _tag);
    return true;
  }

  /// 修复特定问题
  static Future<bool> fixSpecificIssue(String issueType) async {
    switch (issueType) {
      case 'duplicate_messages':
        return await _fixDuplicateMessages();
      case 'missing_indexes':
        return await _fixMissingIndexes();
      case 'corrupted_json':
        return await _fixCorruptedJson();
      default:
        Logs.warn('未知的问题类型: $issueType', _tag);
        return false;
    }
  }

  /// 修复重复消息
  static Future<bool> _fixDuplicateMessages() async {
    return await DatabaseUtils.executeTransaction((txn) async {
      // 查找重复的消息
      var duplicates = await txn.rawQuery('''
        SELECT client_msg_no, COUNT(*) as count 
        FROM message 
        GROUP BY client_msg_no 
        HAVING COUNT(*) > 1
      ''');

      int fixedCount = 0;
      for (var row in duplicates) {
        String clientMsgNo = SafeDataReader.readString(row, 'client_msg_no');

        // 保留最新的一条，删除其他的
        await txn.rawDelete('''
          DELETE FROM message 
          WHERE client_msg_no = ? AND client_seq NOT IN (
            SELECT MAX(client_seq) FROM message WHERE client_msg_no = ?
          )
        ''', [clientMsgNo, clientMsgNo]);

        fixedCount++;
      }

      Logs.info('修复了 $fixedCount 组重复消息', _tag);
    }, operationName: 'fixDuplicateMessages');
  }

  /// 修复缺失的索引
  static Future<bool> _fixMissingIndexes() async {
    return await DatabaseUtils.executeQuery<bool>((db) async {
          await _rebuildIndexes(db);
          return true;
        }, defaultValue: false, operationName: 'fixMissingIndexes') ??
        false;
  }

  /// 修复损坏的JSON数据
  static Future<bool> _fixCorruptedJson() async {
    return await DatabaseUtils.executeTransaction((txn) async {
      // 修复消息表中的损坏JSON
      var messages = await txn.rawQuery('''
        SELECT client_seq, extra FROM message 
        WHERE extra != '' AND extra != '{}'
      ''');

      int fixedCount = 0;
      for (var row in messages) {
        int clientSeq = SafeDataReader.readInt(row, 'client_seq');
        String extra = SafeDataReader.readString(row, 'extra');

        if (!JsonUtils.isValidJson(extra)) {
          await txn.rawUpdate('''
            UPDATE message SET extra = '' WHERE client_seq = ?
          ''', [clientSeq]);
          fixedCount++;
        }
      }

      // 修复会话表中的损坏JSON
      var conversations = await txn.rawQuery('''
        SELECT channel_id, channel_type, extra FROM conversation 
        WHERE extra != '' AND extra != '{}'
      ''');

      for (var row in conversations) {
        String channelId = SafeDataReader.readString(row, 'channel_id');
        int channelType = SafeDataReader.readInt(row, 'channel_type');
        String extra = SafeDataReader.readString(row, 'extra');

        if (!JsonUtils.isValidJson(extra)) {
          await txn.rawUpdate('''
            UPDATE conversation SET extra = '' 
            WHERE channel_id = ? AND channel_type = ?
          ''', [channelId, channelType]);
          fixedCount++;
        }
      }

      Logs.info('修复了 $fixedCount 条损坏的JSON数据', _tag);
    }, operationName: 'fixCorruptedJson');
  }
}
