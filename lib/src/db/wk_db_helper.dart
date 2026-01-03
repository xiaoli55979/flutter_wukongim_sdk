import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../wkim.dart';

class WKDBHelper {
  WKDBHelper._privateConstructor();
  static final WKDBHelper _instance = WKDBHelper._privateConstructor();
  static WKDBHelper get shared => _instance;
  final dbVersion = 1;
  Database? _database;
  Future<bool> init() async {
    var databasesPath = await getDatabasesPath();
    String path = p.join(databasesPath, 'wk_${WKIM.shared.options.uid}.db');
    _database = await openDatabase(
      path,
      version: dbVersion,
      onCreate: (Database db, int version) async {
        // onUpgrade(db);
      },
      // onUpgrade: (db, oldVersion, newVersion) => {
      //   onUpgrade(db)},
    );
    bool result = await onUpgrade(_database!);
    return _database != null && result;
  }

  Future<bool> onUpgrade(Database db) async {
    try {
      print('开始数据库升级...');

      String path;
      try {
        path = await rootBundle
            .loadString('packages/flutter_wukongim_sdk/assets/sql.txt');
        print('成功加载sql.txt文件');
      } catch (e) {
        print('加载sql.txt失败，尝试直接路径: $e');
        try {
          path = await rootBundle.loadString('assets/sql.txt');
          print('成功加载assets/sql.txt文件');
        } catch (e2) {
          print('加载assets/sql.txt也失败: $e2');
          return false;
        }
      }

      List<String> names = path.split(';');
      SharedPreferences preferences = await SharedPreferences.getInstance();
      String wkUid = WKIM.shared.options.uid!;
      int maxVersion = preferences.getInt('wk_max_sql_version_$wkUid') ?? 0;

      print('当前用户: $wkUid, 已完成版本: $maxVersion');

      // 收集需要升级的版本
      List<int> pendingVersions = [];
      for (String name in names) {
        if (name.trim().isEmpty) continue;
        try {
          int version = int.parse(name.trim());
          if (version > maxVersion) {
            pendingVersions.add(version);
          }
        } catch (e) {
          print('解析版本号失败: ${name.trim()}, 错误: $e');
          continue;
        }
      }

      print('待升级版本: $pendingVersions');

      if (pendingVersions.isEmpty) {
        print('无需升级，检查表完整性...');
        return await _verifyBasicIntegrity(db);
      }

      // 按版本号排序
      pendingVersions.sort();

      // 逐个版本升级，确保原子性
      for (int version in pendingVersions) {
        print('开始升级到版本: $version');
        bool success = await _upgradeToVersion(db, version);
        if (!success) {
          print('升级到版本 $version 失败');
          return false;
        }

        // 更新已完成的版本
        await preferences.setInt('wk_max_sql_version_$wkUid', version);
        print('版本 $version 升级完成');
      }

      // 升级完成后进行基本完整性检查
      bool integrityCheck = await _verifyBasicIntegrity(db);
      print('数据库完整性检查结果: $integrityCheck');
      return integrityCheck;
    } catch (e) {
      print('数据库升级异常: $e');
      return false;
    }
  }

  /// 升级到指定版本
  Future<bool> _upgradeToVersion(Database db, int version) async {
    try {
      String sqlStr;
      try {
        sqlStr = await rootBundle
            .loadString('packages/flutter_wukongim_sdk/assets/$version.sql');
      } catch (e) {
        print('加载packages路径失败，尝试直接路径: $e');
        sqlStr = await rootBundle.loadString('assets/$version.sql');
      }

      List<String> sqlList = sqlStr.split(';');
      print('版本 $version 包含 ${sqlList.length} 个SQL语句');

      // 使用事务确保原子性
      await db.transaction((txn) async {
        for (int i = 0; i < sqlList.length; i++) {
          String sql = sqlList[i];
          String exeSql = sql.trim().replaceAll('\n', ' ').replaceAll('\r', '');
          if (exeSql.isNotEmpty) {
            try {
              // 处理 CREATE TABLE 和 CREATE INDEX 语句，添加 IF NOT EXISTS 避免已存在错误
              exeSql = _normalizeCreateStatement(exeSql);

              // 如果是 ALTER TABLE 语句，先检查表是否存在
              if (_isAlterTableStatement(exeSql)) {
                String? tableName = _extractTableNameFromAlter(exeSql);
                if (tableName != null) {
                  bool tableExists = await _checkTableExists(txn, tableName);
                  if (!tableExists) {
                    print('表 $tableName 不存在，尝试从基础版本创建表...');
                    // 尝试从基础版本创建表
                    bool created =
                        await _createTableFromBaseVersion(txn, tableName);
                    if (!created) {
                      print('无法创建表 $tableName，跳过 ALTER TABLE 语句');
                      continue; // 跳过这个 SQL，继续执行下一个
                    }
                    print('表 $tableName 创建成功，继续执行 ALTER TABLE');
                  }

                  // 检查列是否已存在（如果是 ADD COLUMN）
                  if (_isAlterTableAddColumn(exeSql)) {
                    String? columnName = _extractColumnNameFromAlter(exeSql);
                    if (columnName != null) {
                      bool columnExists =
                          await _checkColumnExists(txn, tableName, columnName);
                      if (columnExists) {
                        print(
                            '表 $tableName 的列 $columnName 已存在，跳过 ALTER TABLE 语句');
                        continue; // 跳过这个 SQL，继续执行下一个
                      }
                    }
                  }
                }
              }

              print(
                  '执行SQL[$i]: ${exeSql.substring(0, exeSql.length > 100 ? 100 : exeSql.length)}...');
              await txn.execute(exeSql);
            } catch (e) {
              // 如果是已存在的错误，检查是否是 CREATE 语句，如果是则跳过
              String errorStr = e.toString().toLowerCase();
              if (errorStr.contains('already exists') &&
                  (_isCreateTableStatement(exeSql) ||
                      _isCreateIndexStatement(exeSql))) {
                String objectName = _extractObjectName(exeSql);
                String objectType =
                    _isCreateTableStatement(exeSql) ? '表' : '索引';
                print('$objectType已存在，跳过创建: $objectName');
                continue; // 跳过这个 SQL，继续执行下一个
              }

              // 如果是 ALTER TABLE 相关的错误，也尝试跳过
              if (errorStr.contains('no such table') &&
                  _isAlterTableStatement(exeSql)) {
                String? tableName = _extractTableNameFromAlter(exeSql);
                print('表 ${tableName ?? "unknown"} 不存在，跳过 ALTER TABLE 语句');
                continue; // 跳过这个 SQL，继续执行下一个
              }

              if (errorStr.contains('duplicate column name') &&
                  _isAlterTableStatement(exeSql)) {
                String? tableName = _extractTableNameFromAlter(exeSql);
                String? columnName = _extractColumnNameFromAlter(exeSql);
                print(
                    '表 ${tableName ?? "unknown"} 的列 ${columnName ?? "unknown"} 已存在，跳过 ALTER TABLE 语句');
                continue; // 跳过这个 SQL，继续执行下一个
              }

              print('执行SQL失败: $exeSql');
              print('错误: $e');
              rethrow; // 抛出异常，触发事务回滚
            }
          }
        }
      });

      return true;
    } catch (e) {
      print('升级到版本 $version 失败: $e');
      return false;
    }
  }

  /// 验证基本数据库完整性
  Future<bool> _verifyBasicIntegrity(Database db) async {
    try {
      // 检查关键表是否存在
      List<String> requiredTables = [
        'message',
        'conversation',
        'channel',
        'channel_members'
      ];

      print('开始检查数据库表完整性...');

      // 先查看所有表
      var allTables = await db
          .rawQuery("SELECT name FROM sqlite_master WHERE type='table'");
      print('数据库中的所有表: ${allTables.map((t) => t['name']).toList()}');

      for (String table in requiredTables) {
        var result = await db.rawQuery(
            "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
            [table]);

        if (result.isEmpty) {
          print('缺少必需的表: $table');
          return false;
        } else {
          print('表 $table 存在');
        }
      }

      print('数据库完整性检查通过');
      return true;
    } catch (e) {
      print('数据库完整性检查失败: $e');
      return false;
    }
  }

  Database? getDB() {
    return _database;
  }

  close() {
    if (_database != null) {
      _database!.close();
      _database = null;
    }
  }

  /// 规范化 CREATE 语句（TABLE 和 INDEX），添加 IF NOT EXISTS
  String _normalizeCreateStatement(String sql) {
    // 处理 CREATE TABLE
    if (_isCreateTableStatement(sql)) {
      // 如果已经包含 IF NOT EXISTS，直接返回
      if (sql.toUpperCase().contains('IF NOT EXISTS')) {
        return sql;
      }

      // 添加 IF NOT EXISTS
      return sql.replaceFirst(
        RegExp(r'CREATE\s+TABLE\s+', caseSensitive: false),
        'CREATE TABLE IF NOT EXISTS ',
      );
    }

    // 处理 CREATE INDEX（包括 CREATE UNIQUE INDEX）
    if (_isCreateIndexStatement(sql)) {
      // 如果已经包含 IF NOT EXISTS，直接返回
      if (sql.toUpperCase().contains('IF NOT EXISTS')) {
        return sql;
      }

      // 检查是否是 UNIQUE INDEX
      bool isUnique = RegExp(r'CREATE\s+UNIQUE\s+INDEX', caseSensitive: false)
          .hasMatch(sql);

      // 添加 IF NOT EXISTS（在 INDEX 或 UNIQUE INDEX 之后）
      if (isUnique) {
        return sql.replaceFirst(
          RegExp(r'CREATE\s+UNIQUE\s+INDEX\s+', caseSensitive: false),
          'CREATE UNIQUE INDEX IF NOT EXISTS ',
        );
      } else {
        return sql.replaceFirst(
          RegExp(r'CREATE\s+INDEX\s+', caseSensitive: false),
          'CREATE INDEX IF NOT EXISTS ',
        );
      }
    }

    return sql;
  }

  /// 检查是否是 CREATE TABLE 语句
  bool _isCreateTableStatement(String sql) {
    final regex = RegExp(
      r'^\s*CREATE\s+TABLE',
      caseSensitive: false,
    );
    return regex.hasMatch(sql);
  }

  /// 检查是否是 CREATE INDEX 语句
  bool _isCreateIndexStatement(String sql) {
    final regex = RegExp(
      r'^\s*CREATE\s+(?:UNIQUE\s+)?INDEX',
      caseSensitive: false,
    );
    return regex.hasMatch(sql);
  }

  /// 从 CREATE 语句中提取对象名（表名或索引名，用于日志）
  String _extractObjectName(String sql) {
    try {
      if (_isCreateTableStatement(sql)) {
        // 匹配 CREATE TABLE [IF NOT EXISTS] table_name
        final regex = RegExp(
          r'CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(\w+)',
          caseSensitive: false,
        );
        final match = regex.firstMatch(sql);
        if (match != null && match.groupCount >= 1) {
          return match.group(1) ?? 'unknown';
        }
      } else if (_isCreateIndexStatement(sql)) {
        // 匹配 CREATE [UNIQUE] INDEX [IF NOT EXISTS] index_name
        final regex = RegExp(
          r'CREATE\s+(?:UNIQUE\s+)?INDEX\s+(?:IF\s+NOT\s+EXISTS\s+)?(\w+)',
          caseSensitive: false,
        );
        final match = regex.firstMatch(sql);
        if (match != null && match.groupCount >= 1) {
          return match.group(1) ?? 'unknown';
        }
      }
    } catch (e) {
      print('提取对象名失败: $e');
    }
    return 'unknown';
  }

  /// 检查是否是 ALTER TABLE 语句
  bool _isAlterTableStatement(String sql) {
    final regex = RegExp(
      r'^\s*ALTER\s+TABLE',
      caseSensitive: false,
    );
    return regex.hasMatch(sql);
  }

  /// 检查是否是 ALTER TABLE ADD COLUMN 语句
  bool _isAlterTableAddColumn(String sql) {
    final regex = RegExp(
      r'ALTER\s+TABLE\s+.*\s+ADD\s+',
      caseSensitive: false,
    );
    return regex.hasMatch(sql);
  }

  /// 从 ALTER TABLE 语句中提取表名
  String? _extractTableNameFromAlter(String sql) {
    try {
      // 匹配 ALTER TABLE 'table_name' 或 ALTER TABLE "table_name" 或 ALTER TABLE table_name
      // 尝试多种模式
      List<RegExp> patterns = [
        RegExp(r"ALTER\s+TABLE\s+'(\w+)'", caseSensitive: false),
        RegExp(r'ALTER\s+TABLE\s+"(\w+)"', caseSensitive: false),
        RegExp(r'ALTER\s+TABLE\s+(\w+)', caseSensitive: false),
      ];

      for (var regex in patterns) {
        var match = regex.firstMatch(sql);
        if (match != null && match.groupCount >= 1) {
          return match.group(1);
        }
      }
    } catch (e) {
      print('提取表名失败: $e');
    }
    return null;
  }

  /// 从 ALTER TABLE ADD COLUMN 语句中提取列名
  String? _extractColumnNameFromAlter(String sql) {
    try {
      // 匹配 ADD 'column_name' 或 ADD "column_name" 或 ADD column_name
      // 尝试多种模式
      List<RegExp> patterns = [
        RegExp(r"ADD\s+'(\w+)'", caseSensitive: false),
        RegExp(r'ADD\s+"(\w+)"', caseSensitive: false),
        RegExp(r'ADD\s+(\w+)', caseSensitive: false),
      ];

      for (var regex in patterns) {
        var match = regex.firstMatch(sql);
        if (match != null && match.groupCount >= 1) {
          return match.group(1);
        }
      }
    } catch (e) {
      print('提取列名失败: $e');
    }
    return null;
  }

  /// 检查表是否存在
  Future<bool> _checkTableExists(DatabaseExecutor txn, String tableName) async {
    try {
      var result = await txn.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
        [tableName],
      );
      return result.isNotEmpty;
    } catch (e) {
      print('检查表是否存在失败: $e');
      return false;
    }
  }

  /// 检查列是否存在
  Future<bool> _checkColumnExists(
      DatabaseExecutor txn, String tableName, String columnName) async {
    try {
      // 获取表的 schema
      var result = await txn.rawQuery(
        "PRAGMA table_info($tableName)",
      );

      for (var row in result) {
        if (row['name']?.toString().toLowerCase() == columnName.toLowerCase()) {
          return true;
        }
      }
      return false;
    } catch (e) {
      print('检查列是否存在失败: $e');
      return false;
    }
  }

  /// 从基础版本创建表（如果表不存在）
  Future<bool> _createTableFromBaseVersion(
      DatabaseExecutor txn, String tableName) async {
    try {
      // 基础版本号
      const int baseVersion = 202008292051;

      // 加载基础版本的 SQL
      String sqlStr;
      try {
        sqlStr = await rootBundle.loadString(
            'packages/flutter_wukongim_sdk/assets/$baseVersion.sql');
      } catch (e) {
        print('加载基础版本 SQL 失败，尝试直接路径: $e');
        try {
          sqlStr = await rootBundle.loadString('assets/$baseVersion.sql');
        } catch (e2) {
          print('加载基础版本 SQL 也失败: $e2');
          return false;
        }
      }

      // 解析 SQL 语句
      List<String> sqlList = sqlStr.split(';');

      // 查找创建该表的 SQL 语句
      for (String sql in sqlList) {
        String trimmedSql =
            sql.trim().replaceAll('\n', ' ').replaceAll('\r', '');
        if (trimmedSql.isEmpty) continue;

        // 检查是否是创建该表的语句
        if (_isCreateTableStatement(trimmedSql)) {
          String? createdTableName = _extractObjectName(trimmedSql);
          if (createdTableName.toLowerCase() == tableName.toLowerCase()) {
            // 找到创建该表的 SQL，执行它
            try {
              trimmedSql = _normalizeCreateStatement(trimmedSql);
              print('从基础版本创建表 $tableName');
              await txn.execute(trimmedSql);

              // 创建表后，还需要创建相关的索引
              await _createIndexesFromBaseVersion(txn, tableName, sqlStr);

              return true;
            } catch (e) {
              print('从基础版本创建表失败: $e');
              // 如果表已存在（可能是并发创建），也算成功
              if (e.toString().toLowerCase().contains('already exists')) {
                return true;
              }
              return false;
            }
          }
        }
      }

      print('在基础版本中未找到创建表 $tableName 的 SQL');
      return false;
    } catch (e) {
      print('从基础版本创建表异常: $e');
      return false;
    }
  }

  /// 从基础版本创建表的索引
  Future<void> _createIndexesFromBaseVersion(
      DatabaseExecutor txn, String tableName, String sqlStr) async {
    try {
      List<String> sqlList = sqlStr.split(';');

      for (String sql in sqlList) {
        String trimmedSql =
            sql.trim().replaceAll('\n', ' ').replaceAll('\r', '');
        if (trimmedSql.isEmpty) continue;

        // 检查是否是创建该表的索引的语句
        if (_isCreateIndexStatement(trimmedSql) &&
            trimmedSql.toLowerCase().contains(tableName.toLowerCase())) {
          try {
            trimmedSql = _normalizeCreateStatement(trimmedSql);
            await txn.execute(trimmedSql);
            print('创建索引: ${_extractObjectName(trimmedSql)}');
          } catch (e) {
            // 索引已存在或其他错误，继续执行下一个
            if (!e.toString().toLowerCase().contains('already exists')) {
              print('创建索引失败: $e');
            }
          }
        }
      }
    } catch (e) {
      print('创建索引异常: $e');
    }
  }
}
