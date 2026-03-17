#!/usr/bin/env bash
# 综合测试脚本：执行所有测试并生成详细报告
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${CYAN}${BOLD}"
echo "╔════════════════════════════════════════════════════════╗"
echo "║      VoiceInput 综合自动化测试系统                     ║"
echo "║      $(date '+%Y-%m-%d %H:%M:%S')                    ║"
echo "╚════════════════════════════════════════════════════════╝"
echo -e "${NC}\n"

RESULTS_DIR="/tmp/voiceinput_comprehensive_test_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RESULTS_DIR"

# 测试计数
TEST_COUNT=0
PASS_COUNT=0
FAIL_COUNT=0

# 记录测试结果
record_test() {
    local name="$1"
    local status="$2"  # pass/fail
    local details="$3"

    TEST_COUNT=$((TEST_COUNT + 1))

    if [ "$status" = "pass" ]; then
        PASS_COUNT=$((PASS_COUNT + 1))
        echo -e "${GREEN}✓ PASS${NC}: $name"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo -e "${RED}✗ FAIL${NC}: $name"
    fi

    if [ -n "$details" ]; then
        echo "   $details"
    fi

    echo "$name|$status|$details" >> "$RESULTS_DIR/results.txt"
}

cd "$PROJECT_DIR"

echo -e "${YELLOW}═══════════════════════════════════════════${NC}"
echo -e "${YELLOW}第 1 阶段：构建与安装${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════${NC}\n"

# 测试 1: 构建
echo -e "${BLUE}[1/12]${NC} 构建测试..."
if ./scripts/build-and-install.sh > "$RESULTS_DIR/build.log" 2>&1; then
    VERSION=$(head -1 "$RESULTS_DIR/build.log" | grep -oE 'Version: [0-9.]+' | cut -d' ' -f2)
    record_test "构建" "pass" "版本: $VERSION"
else
    record_test "构建" "fail" "构建失败"
    cat "$RESULTS_DIR/build.log"
    exit 1
fi

sleep 2

# 测试 2: App 安装验证
echo -e "${BLUE}[2/12]${NC} App 安装验证..."
APP_PATH="$HOME/Applications/VoiceInput.app"
if [ -d "$APP_PATH" ] && [ -f "$APP_PATH/Contents/MacOS/VoiceInput" ] && [ -x "$APP_PATH/Contents/MacOS/VoiceInput" ]; then
    APP_SIZE=$(du -sh "$APP_PATH" | cut -f1)
    record_test "安装验证" "pass" "路径: $APP_PATH, 大小: $APP_SIZE"
else
    record_test "安装验证" "fail" "App 未正确安装"
fi

# 测试 3: 进程运行
echo -e "${BLUE}[3/12]${NC} 进程运行测试..."
if pgrep -x "VoiceInput" > /dev/null; then
    PID=$(pgrep -x "VoiceInput")
    record_test "进程运行" "pass" "PID: $PID"
else
    record_test "进程运行" "fail" "进程未运行"
fi

echo -e "\n${YELLOW}═══════════════════════════════════════════${NC}"
echo -e "${YELLOW}第 2 阶段：协议与核心功能${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════${NC}\n"

# 测试 4: Python 协议测试
echo -e "${BLUE}[4/12]${NC} Python 协议测试..."
cd "$PROJECT_DIR/asr_test"
if [ ! -d .venv ]; then
    python3 -m venv .venv
fi
source .venv/bin/activate
pip install -q -r requirements.txt 2>/dev/null || true

if python3 test_volc_asr.py --demo > "$RESULTS_DIR/protocol.log" 2>&1; then
    RESULT=$(grep "最终结果:" "$RESULTS_DIR/protocol.log" | tail -1 || echo "未找到")
    record_test "协议测试" "pass" "$RESULT"
else
    record_test "协议测试" "fail" "协议测试失败"
fi

cd "$PROJECT_DIR"

# 测试 5: E2E 模拟音频测试
echo -e "${BLUE}[5/12]${NC} E2E 模拟音频测试..."
if ./scripts/e2e-test-app.sh > "$RESULTS_DIR/e2e_app.log" 2>&1; then
    if [ -f /tmp/voiceinput_e2e_result.json ]; then
        RECOGNIZED=$(python3 -c "import json; print(json.load(open('/tmp/voiceinput_e2e_result.json')).get('recognized','')[:50])" 2>/dev/null || echo "")
        record_test "E2E模拟音频" "pass" "识别: $RECOGNIZED"
    else
        record_test "E2E模拟音频" "pass" "测试通过"
    fi
else
    record_test "E2E模拟音频" "fail" "E2E 测试失败"
fi

echo -e "\n${YELLOW}═══════════════════════════════════════════${NC}"
echo -e "${YELLOW}第 3 阶段：UI 与交互${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════${NC}\n"

# 测试 6: 菜单栏图标
echo -e "${BLUE}[6/12]${NC} 菜单栏图标测试..."
MENU_CHECK=$(osascript -e '
tell application "System Events"
    tell process "VoiceInput"
        try
            set menuBarItems to menu bar items of menu bar 1
            return count of menuBarItems
        on error
            return 0
        end try
    end tell
end tell
' 2>/dev/null || echo "0")

if [ "$MENU_CHECK" -gt 0 ]; then
    record_test "菜单栏图标" "pass" "找到 $MENU_CHECK 个菜单项"
else
    record_test "菜单栏图标" "fail" "未找到菜单栏图标"
fi

# 测试 7: 截图测试
echo -e "${BLUE}[7/12]${NC} 截图测试..."
screencapture -x "$RESULTS_DIR/screenshot_full.png" 2>/dev/null || true
if [ -f "$RESULTS_DIR/screenshot_full.png" ]; then
    SIZE=$(stat -f%z "$RESULTS_DIR/screenshot_full.png" 2>/dev/null || echo "0")
    if [ "$SIZE" -gt 10000 ]; then
        record_test "截图功能" "pass" "截图大小: $SIZE bytes"
    else
        record_test "截图功能" "fail" "截图文件过小"
    fi
else
    record_test "截图功能" "fail" "无法截图"
fi

# 测试 8: 版本号匹配
echo -e "${BLUE}[8/12]${NC} 版本号一致性测试..."
PLIST_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist" 2>/dev/null)
PLIST_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Contents/Info.plist" 2>/dev/null)
FULL_VERSION="$PLIST_VERSION.$PLIST_BUILD"

if [ "$VERSION" = "$FULL_VERSION" ]; then
    record_test "版本一致性" "pass" "版本: $FULL_VERSION"
else
    record_test "版本一致性" "fail" "版本不匹配: build=$VERSION, plist=$FULL_VERSION"
fi

echo -e "\n${YELLOW}═══════════════════════════════════════════${NC}"
echo -e "${YELLOW}第 4 阶段：系统集成${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════${NC}\n"

# 测试 9: 日志文件
echo -e "${BLUE}[9/12]${NC} 日志文件测试..."
LOG_FILE="$HOME/Library/Logs/VoiceInput.log"
if [ -f "$LOG_FILE" ]; then
    LOG_SIZE=$(stat -f%z "$LOG_FILE" 2>/dev/null || echo "0")
    LOG_LINES=$(wc -l < "$LOG_FILE" 2>/dev/null || echo "0")
    tail -5 "$LOG_FILE" > "$RESULTS_DIR/recent_logs.txt"
    record_test "日志文件" "pass" "大小: $LOG_SIZE bytes, 行数: $LOG_LINES"
else
    record_test "日志文件" "fail" "日志文件不存在"
fi

# 测试 10: 内存使用
echo -e "${BLUE}[10/12]${NC} 内存使用测试..."
if pgrep -x "VoiceInput" > /dev/null; then
    MEM=$(ps -o rss= -p $(pgrep -x "VoiceInput") 2>/dev/null || echo "0")
    MEM_MB=$((MEM / 1024))
    if [ $MEM_MB -lt 500 ]; then
        record_test "内存使用" "pass" "使用: ${MEM_MB}MB"
    else
        record_test "内存使用" "fail" "内存使用过高: ${MEM_MB}MB"
    fi
else
    record_test "内存使用" "fail" "进程未运行"
fi

# 测试 11: CPU 使用
echo -e "${BLUE}[11/12]${NC} CPU 使用测试..."
if pgrep -x "VoiceInput" > /dev/null; then
    CPU=$(ps -o %cpu= -p $(pgrep -x "VoiceInput") 2>/dev/null || echo "0.0")
    record_test "CPU使用" "pass" "使用: ${CPU}%"
else
    record_test "CPU使用" "fail" "进程未运行"
fi

# 测试 12: 文件权限
echo -e "${BLUE}[12/12]${NC} 文件权限测试..."
if [ -x "$APP_PATH/Contents/MacOS/VoiceInput" ]; then
    PERMS=$(stat -f%A "$APP_PATH/Contents/MacOS/VoiceInput" 2>/dev/null || echo "unknown")
    record_test "文件权限" "pass" "权限: $PERMS"
else
    record_test "文件权限" "fail" "可执行文件无执行权限"
fi

echo -e "\n${YELLOW}═══════════════════════════════════════════${NC}"
echo -e "${YELLOW}生成测试报告${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════${NC}\n"

# 生成 HTML 报告
HTML_REPORT="$RESULTS_DIR/report.html"

cat > "$HTML_REPORT" <<'EOF'
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>VoiceInput 综合测试报告</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, "SF Pro", "Segoe UI", sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            padding: 40px 20px;
        }
        .container {
            max-width: 1000px;
            margin: 0 auto;
            background: white;
            border-radius: 20px;
            box-shadow: 0 20px 60px rgba(0,0,0,0.3);
            overflow: hidden;
        }
        .header {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 40px;
            text-align: center;
        }
        .header h1 {
            font-size: 36px;
            font-weight: 700;
            margin-bottom: 10px;
        }
        .header .timestamp {
            opacity: 0.9;
            font-size: 14px;
        }
        .summary {
            display: grid;
            grid-template-columns: repeat(3, 1fr);
            gap: 20px;
            padding: 40px;
            background: #f8f9fa;
        }
        .summary-card {
            background: white;
            padding: 20px;
            border-radius: 12px;
            text-align: center;
            box-shadow: 0 2px 8px rgba(0,0,0,0.1);
        }
        .summary-card .number {
            font-size: 48px;
            font-weight: 700;
            margin-bottom: 10px;
        }
        .summary-card .label {
            color: #666;
            font-size: 14px;
            text-transform: uppercase;
            letter-spacing: 1px;
        }
        .summary-card.total .number { color: #667eea; }
        .summary-card.pass .number { color: #34c759; }
        .summary-card.fail .number { color: #ff3b30; }
        .tests {
            padding: 40px;
        }
        .test-item {
            padding: 20px;
            border-left: 4px solid #ddd;
            margin-bottom: 15px;
            background: #fafafa;
            border-radius: 0 8px 8px 0;
            transition: all 0.3s ease;
        }
        .test-item:hover {
            transform: translateX(5px);
            box-shadow: 0 4px 12px rgba(0,0,0,0.1);
        }
        .test-item.pass { border-left-color: #34c759; background: #f0fdf4; }
        .test-item.fail { border-left-color: #ff3b30; background: #fef2f2; }
        .test-item .title {
            font-size: 18px;
            font-weight: 600;
            margin-bottom: 8px;
            display: flex;
            align-items: center;
            justify-content: space-between;
        }
        .test-item .status {
            font-size: 14px;
            padding: 4px 12px;
            border-radius: 20px;
            font-weight: 600;
        }
        .test-item.pass .status {
            background: #34c759;
            color: white;
        }
        .test-item.fail .status {
            background: #ff3b30;
            color: white;
        }
        .test-item .details {
            color: #666;
            font-size: 14px;
            margin-top: 8px;
        }
        .screenshot {
            max-width: 100%;
            border-radius: 8px;
            margin-top: 15px;
            box-shadow: 0 4px 12px rgba(0,0,0,0.1);
        }
        .footer {
            background: #f8f9fa;
            padding: 30px;
            text-align: center;
            color: #666;
            font-size: 14px;
        }
        .progress-bar {
            height: 8px;
            background: #e0e0e0;
            border-radius: 4px;
            overflow: hidden;
            margin: 20px 0;
        }
        .progress-fill {
            height: 100%;
            background: linear-gradient(90deg, #34c759, #30d158);
            transition: width 0.5s ease;
        }
    </style>
</head>
<body>
<div class="container">
    <div class="header">
        <h1>🎤 VoiceInput 测试报告</h1>
        <p class="timestamp">生成时间: TIMESTAMP_PLACEHOLDER</p>
    </div>

    <div class="summary">
        <div class="summary-card total">
            <div class="number">TOTAL_PLACEHOLDER</div>
            <div class="label">总测试数</div>
        </div>
        <div class="summary-card pass">
            <div class="number">PASS_PLACEHOLDER</div>
            <div class="label">通过</div>
        </div>
        <div class="summary-card fail">
            <div class="number">FAIL_PLACEHOLDER</div>
            <div class="label">失败</div>
        </div>
    </div>

    <div style="padding: 0 40px;">
        <div class="progress-bar">
            <div class="progress-fill" style="width: PERCENT_PLACEHOLDER%;"></div>
        </div>
    </div>

    <div class="tests">
        <h2 style="margin-bottom: 20px; color: #333;">测试详情</h2>
        TESTS_PLACEHOLDER
    </div>

    <div class="footer">
        <p>VoiceInput Automated Testing System</p>
        <p style="margin-top: 10px;">版本: VERSION_PLACEHOLDER</p>
    </div>
</div>
</body>
</html>
EOF

# 填充数据
PERCENT=$((PASS_COUNT * 100 / TEST_COUNT))
sed -i '' "s/TIMESTAMP_PLACEHOLDER/$(date '+%Y-%m-%d %H:%M:%S')/" "$HTML_REPORT"
sed -i '' "s/TOTAL_PLACEHOLDER/$TEST_COUNT/" "$HTML_REPORT"
sed -i '' "s/PASS_PLACEHOLDER/$PASS_COUNT/" "$HTML_REPORT"
sed -i '' "s/FAIL_PLACEHOLDER/$FAIL_COUNT/" "$HTML_REPORT"
sed -i '' "s/PERCENT_PLACEHOLDER/$PERCENT/" "$HTML_REPORT"
sed -i '' "s/VERSION_PLACEHOLDER/$FULL_VERSION/" "$HTML_REPORT"

# 生成测试项 HTML
TESTS_HTML=""
while IFS='|' read -r name status details; do
    STATUS_TEXT=$([ "$status" = "pass" ] && echo "✓ 通过" || echo "✗ 失败")
    TESTS_HTML="$TESTS_HTML
    <div class='test-item $status'>
        <div class='title'>
            <span>$name</span>
            <span class='status'>$STATUS_TEXT</span>
        </div>
        <div class='details'>$details</div>
    </div>"
done < "$RESULTS_DIR/results.txt"

# 替换占位符（使用临时文件避免 sed 问题）
awk -v tests="$TESTS_HTML" '{gsub(/TESTS_PLACEHOLDER/, tests); print}' "$HTML_REPORT" > "$HTML_REPORT.tmp"
mv "$HTML_REPORT.tmp" "$HTML_REPORT"

echo -e "${CYAN}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║                     测试摘要                            ║${NC}"
echo -e "${CYAN}╠════════════════════════════════════════════════════════╣${NC}"
echo -e "${CYAN}║${NC}  总计: ${BOLD}$TEST_COUNT${NC} 项测试"
echo -e "${CYAN}║${NC}  ${GREEN}通过: $PASS_COUNT${NC}"
echo -e "${CYAN}║${NC}  ${RED}失败: $FAIL_COUNT${NC}"
echo -e "${CYAN}║${NC}  成功率: ${BOLD}${PERCENT}%${NC}"
echo -e "${CYAN}╠════════════════════════════════════════════════════════╣${NC}"
echo -e "${CYAN}║${NC}  报告: ${BLUE}$HTML_REPORT${NC}"
echo -e "${CYAN}║${NC}  日志: ${BLUE}$RESULTS_DIR/${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════╝${NC}"

# 打开报告
open "$HTML_REPORT"

# 通知
if [ $FAIL_COUNT -eq 0 ]; then
    osascript -e "display notification \"所有 $TEST_COUNT 项测试通过 ✓\" with title \"VoiceInput 测试\" subtitle \"版本 $FULL_VERSION\" sound name \"Glass\"" 2>/dev/null || true
    echo -e "\n${GREEN}${BOLD}🎉 恭喜！所有测试通过！${NC}\n"
    exit 0
else
    osascript -e "display notification \"$FAIL_COUNT 项测试失败\" with title \"VoiceInput 测试\" subtitle \"版本 $FULL_VERSION\" sound name \"Basso\"" 2>/dev/null || true
    echo -e "\n${RED}${BOLD}⚠️  有 $FAIL_COUNT 项测试失败，请查看报告${NC}\n"
    exit 1
fi
