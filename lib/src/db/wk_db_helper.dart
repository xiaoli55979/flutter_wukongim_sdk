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
              print(
                  '执行SQL[$i]: ${exeSql.substring(0, exeSql.length > 100 ? 100 : exeSql.length)}...');
              await txn.execute(exeSql);
            } catch (e) {
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
}
