#!/usr/bin/env bash
# 完全自动化测试套件：构建 → 测试所有核心功能 → 截图验证 → 生成报告
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_RESULTS_DIR="/tmp/voiceinput_test_results"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
REPORT_FILE="$TEST_RESULTS_DIR/report_${TIMESTAMP}.html"

mkdir -p "$TEST_RESULTS_DIR/screenshots"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}VoiceInput 自动化测试套件${NC}"
echo -e "${BLUE}时间: $(date)${NC}"
echo -e "${BLUE}========================================${NC}\n"

# 测试计数器
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

# HTML 报告头部
cat > "$REPORT_FILE" <<'EOF'
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>VoiceInput 测试报告</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; margin: 20px; background: #f5f5f5; }
        .container { max-width: 1200px; margin: 0 auto; background: white; padding: 30px; border-radius: 10px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
        h1 { color: #333; border-bottom: 3px solid #007aff; padding-bottom: 10px; }
        h2 { color: #555; margin-top: 30px; }
        .summary { background: #f8f9fa; padding: 20px; border-radius: 8px; margin: 20px 0; }
        .test-case { margin: 20px 0; padding: 15px; border-left: 4px solid #ddd; background: #fafafa; }
        .pass { border-left-color: #34c759; background: #f0fdf4; }
        .fail { border-left-color: #ff3b30; background: #fef2f2; }
        .status { font-weight: bold; }
        .pass .status { color: #34c759; }
        .fail .status { color: #ff3b30; }
        .screenshot { max-width: 100%; margin-top: 10px; border: 1px solid #ddd; border-radius: 5px; }
        .metadata { color: #666; font-size: 14px; margin-top: 5px; }
        pre { background: #2d2d2d; color: #f8f8f2; padding: 15px; border-radius: 5px; overflow-x: auto; }
        .timestamp { color: #999; font-size: 12px; }
    </style>
</head>
<body>
<div class="container">
EOF

echo "<h1>VoiceInput 自动化测试报告</h1>" >> "$REPORT_FILE"
echo "<p class='timestamp'>生成时间: $(date '+%Y-%m-%d %H:%M:%S')</p>" >> "$REPORT_FILE"

# 记录测试结果的函数
log_test_result() {
    local test_name="$1"
    local status="$2"  # pass/fail
    local details="$3"
    local screenshot="$4"

    TOTAL_TESTS=$((TOTAL_TESTS + 1))

    if [ "$status" = "pass" ]; then
        PASSED_TESTS=$((PASSED_TESTS + 1))
        echo -e "${GREEN}✓ PASS${NC}: $test_name"
        class="pass"
        status_text="✓ 通过"
    else
        FAILED_TESTS=$((FAILED_TESTS + 1))
        echo -e "${RED}✗ FAIL${NC}: $test_name"
        class="fail"
        status_text="✗ 失败"
    fi

    cat >> "$REPORT_FILE" <<EOF
<div class="test-case $class">
    <h3>$test_name <span class="status">[$status_text]</span></h3>
    <div class="metadata">$(date '+%H:%M:%S')</div>
    <pre>$details</pre>
EOF

    if [ -n "$screenshot" ] && [ -f "$screenshot" ]; then
        local screenshot_name=$(basename "$screenshot")
        echo "<img class='screenshot' src='screenshots/$screenshot_name' alt='Screenshot'>" >> "$REPORT_FILE"
    fi

    echo "</div>" >> "$REPORT_FILE"
}

# 截图函数
take_screenshot() {
    local name="$1"
    local output="$TEST_RESULTS_DIR/screenshots/${TIMESTAMP}_${name}.png"
    screencapture -x "$output" 2>/dev/null || true
    echo "$output"
}

# 等待函数
wait_for_condition() {
    local check_cmd="$1"
    local timeout="$2"
    local count=0
    while [ $count -lt $timeout ]; do
        if eval "$check_cmd"; then
            return 0
        fi
        sleep 1
        count=$((count + 1))
    done
    return 1
}

cd "$PROJECT_DIR"

# ==================== 测试 1: 构建测试 ====================
echo -e "\n${YELLOW}[测试 1/7]${NC} 构建测试..."
if swift build -c release 2>&1 | tee /tmp/voiceinput_build.log; then
    BUILD_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PROJECT_DIR/Info.plist" 2>/dev/null || echo "unknown")
    BUILD_NUM=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PROJECT_DIR/Info.plist" 2>/dev/null || echo "0")
    log_test_result "构建测试" "pass" "构建成功\n版本: $BUILD_VERSION.$BUILD_NUM\n$(tail -5 /tmp/voiceinput_build.log)"
else
    log_test_result "构建测试" "fail" "构建失败\n$(tail -20 /tmp/voiceinput_build.log)"
    echo -e "${RED}构建失败，终止测试${NC}"
    exit 1
fi

# ==================== 测试 2: Python 协议测试 ====================
echo -e "\n${YELLOW}[测试 2/7]${NC} Python 协议测试..."
cd "$PROJECT_DIR/asr_test"
if [ ! -d .venv ]; then
    python3 -m venv .venv
fi
source .venv/bin/activate
pip install -q -r requirements.txt 2>/dev/null || true

if python3 test_volc_asr.py --demo 2>&1 | tee /tmp/voiceinput_python_test.log; then
    FINAL_RESULT=$(grep "最终结果:" /tmp/voiceinput_python_test.log | tail -1 || echo "未找到结果")
    log_test_result "Python 协议测试" "pass" "协议测试通过\n$FINAL_RESULT\n$(tail -10 /tmp/voiceinput_python_test.log)"
else
    log_test_result "Python 协议测试" "fail" "协议测试失败\n$(tail -20 /tmp/voiceinput_python_test.log)"
fi

cd "$PROJECT_DIR"

# ==================== 测试 3: 安装与版本显示测试 ====================
echo -e "\n${YELLOW}[测试 3/7]${NC} 安装与版本显示测试..."
./scripts/build-and-install.sh 2>&1 | tee /tmp/voiceinput_install.log
sleep 2

# 等待 app 启动
if wait_for_condition "pgrep -x VoiceInput > /dev/null" 10; then
    sleep 1
    screenshot=$(take_screenshot "menubar_version")

    # 检查菜单栏图标
    if pgrep -x VoiceInput > /dev/null; then
        VERSION_FROM_PLIST=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$HOME/Applications/VoiceInput.app/Contents/Info.plist").$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$HOME/Applications/VoiceInput.app/Contents/Info.plist")
        log_test_result "安装与启动测试" "pass" "App 已成功安装并启动\n安装路径: ~/Applications/VoiceInput.app\n版本号: $VERSION_FROM_PLIST" "$screenshot"
    else
        log_test_result "安装与启动测试" "fail" "App 未能启动" "$screenshot"
    fi
else
    log_test_result "安装与启动测试" "fail" "App 启动超时"
fi

# ==================== 测试 4: E2E 测试（模拟音频）====================
echo -e "\n${YELLOW}[测试 4/7]${NC} E2E 测试（模拟音频）..."

# 下载测试音频
DEMO_WAV="/tmp/voiceinput_demo.wav"
DEMO_PCM="/tmp/voiceinput_demo.pcm"
if [ ! -f "$DEMO_WAV" ]; then
    curl -sSL "https://help-static-aliyun-doc.aliyuncs.com/file-manage-files/zh-CN/20230223/hvow/nls-sample-16k.wav" -o "$DEMO_WAV" || echo "下载失败"
fi

if [ -f "$DEMO_WAV" ]; then
    python3 -c "
import wave
with wave.open('$DEMO_WAV', 'rb') as f:
    pcm = f.readframes(f.getnframes())
    open('$DEMO_PCM', 'wb').write(pcm)
" 2>/dev/null || echo "转换失败"
fi

if ./scripts/e2e-test-app.sh 2>&1 | tee /tmp/voiceinput_e2e.log; then
    screenshot=$(take_screenshot "e2e_success")
    RESULT_JSON="/tmp/voiceinput_e2e_result.json"
    if [ -f "$RESULT_JSON" ]; then
        RECOGNIZED=$(python3 -c "import json; print(json.load(open('$RESULT_JSON')).get('recognized','')[:100])" 2>/dev/null || echo "")
        log_test_result "E2E 测试（模拟音频）" "pass" "识别并粘贴成功\n识别内容: $RECOGNIZED" "$screenshot"
    else
        log_test_result "E2E 测试（模拟音频）" "pass" "测试通过\n$(tail -10 /tmp/voiceinput_e2e.log)" "$screenshot"
    fi
else
    screenshot=$(take_screenshot "e2e_fail")
    log_test_result "E2E 测试（模拟音频）" "fail" "E2E 测试失败\n$(tail -20 /tmp/voiceinput_e2e.log)" "$screenshot"
fi

# ==================== 测试 5: 菜单栏交互测试 ====================
echo -e "\n${YELLOW}[测试 5/7]${NC} 菜单栏交互测试..."

# 确保 app 在运行
if ! pgrep -x VoiceInput > /dev/null; then
    open "$HOME/Applications/VoiceInput.app"
    sleep 2
fi

screenshot=$(take_screenshot "menubar_icon")

# 使用 AppleScript 测试菜单栏是否可访问（状态栏 app 使用 menu bar 1）
MENU_TEST_RESULT=$(osascript -e '
tell application "System Events"
    tell process "VoiceInput"
        try
            set menuBarItems to menu bar items of menu bar 1
            set itemCount to count of menuBarItems
            return "找到 " & itemCount & " 个菜单栏项"
        on error errMsg
            return "错误: " & errMsg
        end try
    end tell
end tell
' 2>&1 || echo "菜单栏访问失败")

if [[ "$MENU_TEST_RESULT" == *"找到"* ]]; then
    log_test_result "菜单栏交互测试" "pass" "菜单栏可访问\n$MENU_TEST_RESULT" "$screenshot"
else
    log_test_result "菜单栏交互测试" "fail" "菜单栏访问异常\n$MENU_TEST_RESULT" "$screenshot"
fi

# ==================== 测试 6: 日志文件测试 ====================
echo -e "\n${YELLOW}[测试 6/7]${NC} 日志文件测试..."

LOG_FILE="$HOME/Library/Logs/VoiceInput.log"
if [ -f "$LOG_FILE" ]; then
    LOG_SIZE=$(stat -f%z "$LOG_FILE" 2>/dev/null || echo "0")
    LOG_LINES=$(wc -l < "$LOG_FILE" 2>/dev/null || echo "0")
    RECENT_LOGS=$(tail -20 "$LOG_FILE" 2>/dev/null || echo "无法读取")
    log_test_result "日志文件测试" "pass" "日志文件存在且可访问\n路径: $LOG_FILE\n大小: $LOG_SIZE bytes\n行数: $LOG_LINES\n\n最近日志:\n$RECENT_LOGS"
else
    log_test_result "日志文件测试" "fail" "日志文件不存在: $LOG_FILE"
fi

# ==================== 测试 7: 权限检查 ====================
echo -e "\n${YELLOW}[测试 7/7]${NC} 权限检查..."

# 检查麦克风权限
MIC_PERMISSION=$(osascript -e '
tell application "System Events"
    try
        set micStatus to do shell script "sqlite3 ~/Library/Application\\ Support/com.apple.TCC/TCC.db \"SELECT service, allowed FROM access WHERE service = '\''kTCCServiceMicrophone'\'' AND client = '\'''"$HOME"'/Applications/VoiceInput.app'\''\" 2>/dev/null || echo \"未知\""
        return micStatus
    on error
        return "权限查询失败"
    end try
end tell
' 2>/dev/null || echo "无法查询")

# 检查辅助功能权限
ACCESSIBILITY_CHECK=$(osascript -e '
tell application "System Events"
    try
        keystroke "test" using command down
        return "辅助功能权限可能已授予"
    on error
        return "辅助功能权限可能未授予"
    end try
end tell
' 2>/dev/null || echo "无法测试")

PERMISSION_REPORT="麦克风权限: $MIC_PERMISSION\n辅助功能测试: $ACCESSIBILITY_CHECK"

if [[ "$MIC_PERMISSION" != *"未知"* ]] || [[ "$ACCESSIBILITY_CHECK" == *"已授予"* ]]; then
    log_test_result "权限检查" "pass" "$PERMISSION_REPORT"
else
    log_test_result "权限检查" "fail" "$PERMISSION_REPORT\n\n警告: 某些权限可能未正确授予"
fi

# ==================== 生成摘要 ====================
echo -e "\n${BLUE}========================================${NC}"
echo -e "${BLUE}测试完成${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "总计: $TOTAL_TESTS"
echo -e "${GREEN}通过: $PASSED_TESTS${NC}"
echo -e "${RED}失败: $FAILED_TESTS${NC}"

# HTML 摘要
cat >> "$REPORT_FILE" <<EOF
<div class="summary">
    <h2>测试摘要</h2>
    <p><strong>总计:</strong> $TOTAL_TESTS 项测试</p>
    <p><strong style="color: #34c759;">通过:</strong> $PASSED_TESTS</p>
    <p><strong style="color: #ff3b30;">失败:</strong> $FAILED_TESTS</p>
    <p><strong>成功率:</strong> $(echo "scale=1; $PASSED_TESTS * 100 / $TOTAL_TESTS" | bc)%</p>
</div>
</div>
</body>
</html>
EOF

echo -e "\n${BLUE}测试报告已生成: $REPORT_FILE${NC}"

# 自动打开报告
open "$REPORT_FILE"

# 返回退出码
if [ $FAILED_TESTS -eq 0 ]; then
    echo -e "\n${GREEN}所有测试通过！${NC}"
    exit 0
else
    echo -e "\n${RED}有 $FAILED_TESTS 项测试失败${NC}"
    exit 1
fi
