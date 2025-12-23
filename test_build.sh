#!/bin/bash

echo "开始测试 WuKongIM SDK 示例编译..."

# 进入示例目录
cd example

echo "1. 清理项目..."
flutter clean

echo "2. 获取依赖..."
flutter pub get

echo "3. 分析代码..."
flutter analyze

if [ $? -eq 0 ]; then
    echo "✅ 代码分析通过"
else
    echo "❌ 代码分析失败"
    exit 1
fi

echo "4. 检查编译（不实际构建）..."
flutter build apk --debug --dry-run

if [ $? -eq 0 ]; then
    echo "✅ 编译检查通过"
    echo "🎉 WuKongIM SDK 示例项目准备就绪！"
else
    echo "❌ 编译检查失败"
    exit 1
fi

echo ""
echo "运行示例应用："
echo "cd example && flutter run"