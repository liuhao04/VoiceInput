#!/usr/bin/env bash
# 持续测试脚本：监控代码变化，自动构建、测试并报告
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 配置
WATCH_MODE="${1:-once}"  # once, watch, or continuous
INTERVAL="${2:-300}"     # 监控间隔（秒）

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}VoiceInput 持续测试系统${NC}"
echo -e "${CYAN}模式: $WATCH_MODE${NC}"
echo -e "${CYAN}========================================${NC}\n"

# 记录上次文件修改时间
LAST_HASH=""

get_source_hash() {
    # 计算所有 Swift 源文件的 hash
    find "$PROJECT_DIR/Sources" -name "*.swift" -type f -exec md5 {} \; 2>/dev/null | md5 | cut -d' ' -f1
}

run_full_test_cycle() {
    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}开始测试周期 - $(date)${NC}"
    echo -e "${BLUE}========================================${NC}\n"

    # 1. 构建并安装
    echo -e "${YELLOW}步骤 1/5: 构建并安装${NC}"
    if "$SCRIPT_DIR/build-and-install.sh" 2>&1 | tee /tmp/voiceinput_build.log; then
        VERSION_LINE=$(head -1 /tmp/voiceinput_build.log)
        echo -e "${GREEN}✓ 构建成功: $VERSION_LINE${NC}"

        # 提取版本号
        BUILD_VERSION=$(echo "$VERSION_LINE" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' || echo "未知")
        echo -e "${CYAN}当前版本: $BUILD_VERSION${NC}"
    else
        echo -e "${RED}✗ 构建失败${NC}"
        tail -20 /tmp/voiceinput_build.log
        return 1
    fi

    sleep 2

    # 2. 运行 CI 测试（Python 协议 + Swift 构建验证）
    echo -e "\n${YELLOW}步骤 2/5: CI 测试（协议验证）${NC}"
    if "$SCRIPT_DIR/ci-test.sh" 2>&1 | tee /tmp/voiceinput_ci.log; then
        echo -e "${GREEN}✓ CI 测试通过${NC}"
    else
        echo -e "${RED}✗ CI 测试失败${NC}"
        tail -20 /tmp/voiceinput_ci.log
        return 1
    fi

    # 3. E2E 测试（模拟音频）
    echo -e "\n${YELLOW}步骤 3/5: E2E 测试（模拟音频）${NC}"
    if "$SCRIPT_DIR/e2e-test-app.sh" 2>&1 | tee /tmp/voiceinput_e2e_app.log; then
        echo -e "${GREEN}✓ E2E 模拟音频测试通过${NC}"

        # 显示识别结果
        if [ -f /tmp/voiceinput_e2e_result.json ]; then
            RECOGNIZED=$(python3 -c "import json; print(json.load(open('/tmp/voiceinput_e2e_result.json')).get('recognized','')[:80])" 2>/dev/null || echo "")
            echo -e "${CYAN}识别内容: $RECOGNIZED${NC}"
        fi
    else
        echo -e "${RED}✗ E2E 模拟音频测试失败${NC}"
        tail -20 /tmp/voiceinput_e2e_app.log
    fi

    # 4. 视觉测试
    echo -e "\n${YELLOW}步骤 4/5: 视觉测试（UI 验证）${NC}"
    if python3 "$SCRIPT_DIR/visual-test.py" 2>&1 | tee /tmp/voiceinput_visual.log; then
        echo -e "${GREEN}✓ 视觉测试通过${NC}"
    else
        echo -e "${RED}✗ 视觉测试失败${NC}"
        tail -20 /tmp/voiceinput_visual.log
    fi

    # 5. 生成测试摘要
    echo -e "\n${YELLOW}步骤 5/5: 生成测试摘要${NC}"

    SUMMARY_FILE="/tmp/voiceinput_test_summary_$(date +%Y%m%d_%H%M%S).txt"

    cat > "$SUMMARY_FILE" <<EOF
========================================
VoiceInput 测试摘要
========================================
时间: $(date)
版本: $BUILD_VERSION

测试结果:
------------------
EOF

    # 检查各项测试结果
    if grep -q "PASS: App 构建成功" /tmp/voiceinput_build.log 2>/dev/null; then
        echo "✓ 构建测试: 通过" >> "$SUMMARY_FILE"
    else
        echo "✗ 构建测试: 失败" >> "$SUMMARY_FILE"
    fi

    if grep -q "全部通过" /tmp/voiceinput_ci.log 2>/dev/null; then
        echo "✓ CI 测试: 通过" >> "$SUMMARY_FILE"
    else
        echo "✗ CI 测试: 失败" >> "$SUMMARY_FILE"
    fi

    if grep -q "PASS: 识别并粘贴成功" /tmp/voiceinput_e2e_app.log 2>/dev/null; then
        echo "✓ E2E 测试: 通过" >> "$SUMMARY_FILE"
    else
        echo "✗ E2E 测试: 失败" >> "$SUMMARY_FILE"
    fi

    if grep -q "成功率: 100.0%" /tmp/voiceinput_visual.log 2>/dev/null; then
        echo "✓ 视觉测试: 通过" >> "$SUMMARY_FILE"
    else
        echo "✗ 视觉测试: 部分失败" >> "$SUMMARY_FILE"
    fi

    echo "" >> "$SUMMARY_FILE"
    echo "详细日志:" >> "$SUMMARY_FILE"
    echo "  构建: /tmp/voiceinput_build.log" >> "$SUMMARY_FILE"
    echo "  CI: /tmp/voiceinput_ci.log" >> "$SUMMARY_FILE"
    echo "  E2E: /tmp/voiceinput_e2e_app.log" >> "$SUMMARY_FILE"
    echo "  视觉: /tmp/voiceinput_visual.log" >> "$SUMMARY_FILE"
    echo "========================================" >> "$SUMMARY_FILE"

    cat "$SUMMARY_FILE"

    echo -e "\n${BLUE}测试摘要已保存: $SUMMARY_FILE${NC}"

    # 通知（使用 macOS 通知）
    PASS_COUNT=$(grep -c "^✓" "$SUMMARY_FILE" || echo "0")
    FAIL_COUNT=$(grep -c "^✗" "$SUMMARY_FILE" || echo "0")

    if [ "$FAIL_COUNT" -eq 0 ]; then
        osascript -e "display notification \"版本 $BUILD_VERSION - 所有测试通过 ($PASS_COUNT/$PASS_COUNT)\" with title \"VoiceInput 测试\" sound name \"Glass\"" 2>/dev/null || true
        echo -e "\n${GREEN}🎉 所有测试通过！版本 $BUILD_VERSION${NC}\n"
    else
        osascript -e "display notification \"版本 $BUILD_VERSION - $FAIL_COUNT 项测试失败\" with title \"VoiceInput 测试\" sound name \"Basso\"" 2>/dev/null || true
        echo -e "\n${RED}⚠️  有 $FAIL_COUNT 项测试失败${NC}\n"
    fi
}

# 运行模式
case "$WATCH_MODE" in
    once)
        # 单次运行
        run_full_test_cycle
        ;;

    watch)
        # 监控文件变化
        echo -e "${CYAN}监控模式启动 - 监控 Sources/ 目录变化...${NC}\n"
        LAST_HASH=$(get_source_hash)

        while true; do
            sleep 5
            CURRENT_HASH=$(get_source_hash)

            if [ "$CURRENT_HASH" != "$LAST_HASH" ]; then
                echo -e "\n${YELLOW}检测到代码变化，开始测试...${NC}"
                LAST_HASH=$CURRENT_HASH
                run_full_test_cycle
            fi
        done
        ;;

    continuous)
        # 持续运行（定时）
        echo -e "${CYAN}持续测试模式启动 - 每 $INTERVAL 秒运行一次...${NC}\n"

        while true; do
            run_full_test_cycle
            echo -e "\n${CYAN}等待 $INTERVAL 秒后进行下一轮测试...${NC}"
            sleep "$INTERVAL"
        done
        ;;

    *)
        echo -e "${RED}未知模式: $WATCH_MODE${NC}"
        echo "用法: $0 [once|watch|continuous] [间隔秒数]"
        echo "  once       - 运行一次完整测试"
        echo "  watch      - 监控文件变化自动测试"
        echo "  continuous - 定时持续测试（默认 300 秒）"
        exit 1
        ;;
esac
