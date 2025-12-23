#!/bin/bash

echo "🚀 准备发布 Flutter WuKongIM SDK..."

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 检查函数
check_step() {
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ $1${NC}"
    else
        echo -e "${RED}❌ $1${NC}"
        exit 1
    fi
}

echo -e "${BLUE}📋 发布前检查清单${NC}"

# 1. 检查Flutter版本
echo -e "${YELLOW}1. 检查Flutter版本...${NC}"
flutter --version
check_step "Flutter版本检查"

# 2. 清理项目
echo -e "${YELLOW}2. 清理项目...${NC}"
flutter clean
check_step "项目清理"

# 3. 获取依赖
echo -e "${YELLOW}3. 获取依赖...${NC}"
flutter pub get
check_step "依赖获取"

# 4. 代码分析
echo -e "${YELLOW}4. 代码分析...${NC}"
flutter analyze
check_step "代码分析"

# 5. 格式化代码
echo -e "${YELLOW}5. 格式化代码...${NC}"
dart format lib/ example/lib/ --set-exit-if-changed
if [ $? -eq 0 ]; then
    echo -e "${GREEN}✅ 代码格式正确${NC}"
else
    echo -e "${YELLOW}⚠️ 代码已自动格式化${NC}"
    dart format lib/ example/lib/
fi

# 6. 运行测试（如果有的话）
echo -e "${YELLOW}6. 运行测试...${NC}"
if [ -d "test" ] && [ "$(ls -A test)" ]; then
    flutter test
    check_step "测试运行"
else
    echo -e "${YELLOW}⚠️ 没有找到测试文件${NC}"
fi

# 7. 检查示例项目
echo -e "${YELLOW}7. 检查示例项目...${NC}"
cd example
flutter pub get
flutter analyze
check_step "示例项目检查"
cd ..

# 8. 发布预检查
echo -e "${YELLOW}8. 发布预检查...${NC}"
flutter pub publish --dry-run
check_step "发布预检查"

echo ""
echo -e "${GREEN}🎉 所有检查通过！准备发布...${NC}"
echo ""
echo -e "${BLUE}📝 发布步骤：${NC}"
echo "1. 确保所有更改已提交到Git"
echo "2. 创建版本标签: git tag v0.0.1"
echo "3. 推送到GitHub: git push origin main --tags"
echo "4. 运行发布命令: flutter pub publish"
echo ""
echo -e "${YELLOW}⚠️ 注意事项：${NC}"
echo "- 确保已登录pub.dev账号"
echo "- 检查包名是否可用"
echo "- 确认所有文档和示例都是最新的"
echo ""