#!/bin/bash

# 自动更新插件导出文件
# 扫描 lib/src/ 目录下的所有 .dart 文件，并自动添加到主导出文件中

set -e

# 获取脚本所在目录的父目录（项目根目录）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# 切换到项目根目录
cd "$PROJECT_ROOT"

# ========== 配置区域 ==========

# 排除的文件模式（不会被导出）
exclude_patterns=(
    "_*"              # 私有文件（以 _ 开头）
#    "*.g.dart"        # JSON 序列化生成文件
    "*.freezed.dart"  # Freezed 生成文件
    "*.mocks.dart"    # Mock 生成文件
    "*.gr.dart"       # AutoRoute 生成文件
)

# 排除的目录（不会被识别为插件）
exclude_dirs=(
    "scripts"
    ".*"              # 隐藏目录
)

# ========== 配置区域结束 ==========

# 颜色定义
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 自动检测插件目录
detect_plugins() {
    local plugins=()
    
    # 遍历项目根目录下的所有目录
    for dir in "$PROJECT_ROOT"/*; do
        # 跳过非目录
        [ ! -d "$dir" ] && continue
        
        local dir_name=$(basename "$dir")
        
        # 检查是否在排除列表中
        local should_exclude=false
        for exclude in "${exclude_dirs[@]}"; do
            if [[ "$dir_name" == $exclude ]]; then
                should_exclude=true
                break
            fi
        done
        
        [ "$should_exclude" = true ] && continue
        
        # 检查是否包含 pubspec.yaml（Flutter/Dart 插件的标志）
        if [ -f "$dir/pubspec.yaml" ]; then
            plugins+=("$dir_name")
        fi
    done
    
    echo "${plugins[@]}"
}

echo -e "${BLUE}🔄 开始更新插件导出文件...${NC}"
echo ""

# 自动检测插件
plugins=($(detect_plugins))

if [ ${#plugins[@]} -eq 0 ]; then
    echo -e "${YELLOW}⚠️  未检测到任何插件目录${NC}"
    exit 0
fi

echo -e "${GREEN}📦 检测到 ${#plugins[@]} 个插件：${NC}"
for plugin in "${plugins[@]}"; do
    echo -e "  - $plugin"
done
echo ""

# 更新单个插件的导出文件
update_plugin_exports() {
    local plugin=$1
    local plugin_dir="$plugin"
    local main_file="$plugin_dir/lib/$plugin.dart"
    local src_dir="$plugin_dir/lib/src"
    
    echo -e "${BLUE}  📦 处理 $plugin...${NC}"
    
    # 检查 src 目录是否存在，如果不存在则使用 lib 目录
    local scan_dir="$src_dir"
    if [ ! -d "$src_dir" ]; then
        scan_dir="$plugin_dir/lib"
        if [ ! -d "$scan_dir" ]; then
            echo -e "${YELLOW}    ⚠️  lib 目录不存在，跳过${NC}"
            return
        fi
    fi
    
    # 从 pubspec.yaml 中读取插件描述
    local description=""
    local pubspec_file="$plugin_dir/pubspec.yaml"
    if [ -f "$pubspec_file" ]; then
        # 尝试从 pubspec.yaml 中提取 description 字段
        description=$(grep "^description:" "$pubspec_file" | sed 's/^description: *//' | sed 's/^["'\'']//' | sed 's/["'\'']$//')
    fi
    
    # 如果没有描述，使用默认描述
    if [ -z "$description" ]; then
        description="$plugin plugin"
    fi
    
    # 创建临时文件
    local temp_file=$(mktemp)
    
    # 写入文件头
    # 首字母大写
    local plugin_name=$(echo "$plugin" | sed 's/_/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2));}1')
    
    cat > "$temp_file" << EOF
/// $plugin_name Plugin
///
/// $description

EOF

    # tesla_manager 自动导出 tesla_core
    if [ "$plugin" = "tesla_manager" ]; then
        echo "// 导出 Core 插件" >> "$temp_file"
        echo "export 'package:tesla_core/tesla_core.dart';" >> "$temp_file"
        echo "" >> "$temp_file"
    fi
    
    # 检查是否有特殊的导出需求（可以通过在 pubspec.yaml 中添加注释来配置）
    # 例如：# export_dependencies: tesla_auth tesla_home
    local export_deps=$(grep "^# export_dependencies:" "$pubspec_file" 2>/dev/null | sed 's/^# export_dependencies: *//')
    if [ -n "$export_deps" ]; then
        echo "// 导出其他依赖插件" >> "$temp_file"
        for dep in $export_deps; do
            echo "export 'package:$dep/$dep.dart';" >> "$temp_file"
        done
        echo "" >> "$temp_file"
    fi
    
    # 构建 find 命令的排除参数
    local find_cmd="find \"$scan_dir\" -name \"*.dart\" -type f"
    for pattern in "${exclude_patterns[@]}"; do
        find_cmd="$find_cmd ! -name \"$pattern\""
    done
    # 排除主文件本身
    find_cmd="$find_cmd ! -path \"$main_file\""
    find_cmd="$find_cmd | sort"
    
    # 查找所有 .dart 文件（排除配置的模式）
    local dart_files=$(eval $find_cmd)
    
    if [ -z "$dart_files" ]; then
        echo -e "${YELLOW}    ⚠️  未找到可导出的文件${NC}"
        rm "$temp_file"
        return
    fi
    
    # 统计文件数量
    local file_count=$(echo "$dart_files" | wc -l | tr -d ' ')
    
    # 按目录分组导出
    local current_dir=""
    local has_exports=false
    
    while IFS= read -r file; do
        # 获取相对于 lib/ 的路径
        local rel_path=${file#$plugin_dir/lib/}
        
        # 获取文件所在目录
        local file_dir=$(dirname "$rel_path")
        
        # 如果目录改变，添加注释
        if [ "$file_dir" != "$current_dir" ]; then
            if [ "$has_exports" = true ]; then
                echo "" >> "$temp_file"
            fi
            
            if [ "$file_dir" = "src" ]; then
                echo "// 核心类" >> "$temp_file"
            else
                local dir_name=$(basename "$file_dir")
                local formatted_name=$(echo "$dir_name" | awk '{print toupper(substr($0,1,1)) tolower(substr($0,2))}')
                echo "// $formatted_name" >> "$temp_file"
            fi
            
            current_dir="$file_dir"
            has_exports=true
        fi
        
        # 添加导出语句
        echo "export '$rel_path';" >> "$temp_file"
        
    done <<< "$dart_files"
    
    # 比较文件是否有变化
    if [ -f "$main_file" ] && cmp -s "$temp_file" "$main_file"; then
        echo -e "${GREEN}    ✓ 无变化${NC}"
        rm "$temp_file"
    else
        mv "$temp_file" "$main_file"
        echo -e "${GREEN}    ✓ 已更新 ($file_count 个文件)${NC}"
    fi
}

# 处理所有插件
for plugin in "${plugins[@]}"; do
    update_plugin_exports "$plugin"
done

echo ""
echo -e "${GREEN}✅ 所有插件导出文件更新完成！${NC}"
echo ""
echo -e "${BLUE}💡 提示：${NC}"
echo "  - 以 _ 开头的文件被视为私有文件，不会被导出"
echo "  - 运行 'melos bootstrap' 更新依赖"
echo "  - 运行 'make analyze' 检查代码"
