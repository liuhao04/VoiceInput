#!/usr/bin/env bash
# 交互式录音测试：提示用户说"测试一下"，然后验证是否正确识别并插入到 TextEdit
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_PATH="$HOME/Applications/VoiceInput.app"
APP_EXE="$APP_PATH/Contents/MacOS/VoiceInput"
LOG_FILE="$HOME/Library/Logs/VoiceInput.log"

# ANSI 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}VoiceInput 交互式录音测试${NC}"
echo -e "${BLUE}========================================${NC}"

# 1. 构建并安装
echo -e "\n${YELLOW}[1/7] 构建并安装应用...${NC}"
cd "$PROJECT_DIR"
"$SCRIPT_DIR/build-and-install.sh"

# 2. 清空日志
echo -e "\n${YELLOW}[2/7] 清空日志文件...${NC}"
> "$LOG_FILE"
echo "日志已清空"

# 3. 启动应用
echo -e "\n${YELLOW}[3/7] 启动 VoiceInput...${NC}"
pkill -x VoiceInput 2>/dev/null || true
sleep 1
open "$APP_PATH"
sleep 3

# 验证进程是否运行
if ! pgrep -x VoiceInput > /dev/null; then
    echo -e "${RED}✗ 应用启动失败${NC}"
    exit 1
fi
echo -e "${GREEN}✓ 应用已启动${NC}"

# 等待权限授予
echo -e "\n${BLUE}⚠️  如果系统弹出权限请求，请点击「允许」${NC}"
echo -e "${YELLOW}等待 5 秒确保权限已授予...${NC}"
sleep 5

# 检查麦克风权限
echo -e "\n${YELLOW}检查麦克风权限...${NC}"
PERMISSION_CHECK=$(tail -5 "$LOG_FILE" | grep -o "麦克风权限.*" || echo "")
echo "权限状态: $PERMISSION_CHECK"

if echo "$PERMISSION_CHECK" | grep -q "已授权"; then
    echo -e "${GREEN}✓ 麦克风权限已授予${NC}"
elif echo "$PERMISSION_CHECK" | grep -q "被拒绝"; then
    echo -e "${RED}✗ 麦克风权限被拒绝${NC}"
    echo -e "${RED}请运行: ./scripts/reset-permissions.sh${NC}"
    echo -e "${RED}然后重启应用并授予权限${NC}"
    exit 1
fi

# 4. 打开 TextEdit 并清空内容
echo -e "\n${YELLOW}[4/7] 准备 TextEdit...${NC}"
osascript <<EOF
tell application "TextEdit"
    activate
    if (count of documents) = 0 then
        make new document
    end if
    set text of front document to ""
end tell
EOF
sleep 1
echo -e "${GREEN}✓ TextEdit 已准备好（空文档）${NC}"

# 5. 触发录音（通过菜单点击"开始录音"）
echo -e "\n${YELLOW}[5/7] 触发录音...${NC}"
osascript <<EOF
tell application "System Events"
    tell process "VoiceInput"
        -- 点击菜单栏图标
        set menuBarItem to menu bar item 1 of menu bar 1
        click menuBarItem
        delay 0.5

        -- 点击"开始语音输入"菜单项
        try
            click menu item "开始语音输入" of menu 1 of menuBarItem
            return "SUCCESS"
        on error errMsg
            return "ERROR: " & errMsg
        end try
    end tell
end tell
EOF

CLICK_RESULT=$?
if [ $CLICK_RESULT -ne 0 ]; then
    echo -e "${RED}✗ 无法点击菜单项，尝试使用 F5 键...${NC}"
    # 备用方案：模拟 F5 按键
    osascript -e 'tell application "System Events" to key code 96' # F5 key code
fi

sleep 0.5

# 6. 提示用户说话并等待
echo -e "\n${BLUE}========================================${NC}"
echo -e "${BLUE}>>> 请现在对着麦克风说："测试一下" <<<${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "${YELLOW}将在 5 秒后自动停止录音...${NC}"

for i in 5 4 3 2 1; do
    echo -ne "${YELLOW}倒计时: $i 秒\r${NC}"
    sleep 1
done
echo ""

# 7. 停止录音（再次点击菜单或 F5）
echo -e "\n${YELLOW}[6/7] 停止录音...${NC}"
osascript <<EOF
tell application "System Events"
    tell process "VoiceInput"
        try
            -- 点击菜单栏图标
            set menuBarItem to menu bar item 1 of menu bar 1
            click menuBarItem
            delay 0.5

            -- 点击"停止语音输入"菜单项
            click menu item "停止语音输入" of menu 1 of menuBarItem
        on error
            -- 如果菜单方式失败，尝试 F5
            key code 96
        end try
    end tell
end tell
EOF

echo -e "${GREEN}✓ 录音已停止${NC}"
sleep 2  # 等待粘贴完成

# 8. 检查 TextEdit 内容
echo -e "\n${YELLOW}[7/7] 验证结果...${NC}"

TEXT_CONTENT=$(osascript <<EOF
tell application "TextEdit"
    if (count of documents) > 0 then
        return text of front document
    else
        return ""
    end if
end tell
EOF
)

echo -e "\n${BLUE}TextEdit 内容:${NC}"
echo "「$TEXT_CONTENT」"

# 检查是否包含"测试一下"
if echo "$TEXT_CONTENT" | grep -q "测试一下"; then
    echo -e "\n${GREEN}========================================${NC}"
    echo -e "${GREEN}✓ 测试通过！${NC}"
    echo -e "${GREEN}成功识别并插入："测试一下"${NC}"
    echo -e "${GREEN}========================================${NC}"
    exit 0
else
    echo -e "\n${RED}========================================${NC}"
    echo -e "${RED}✗ 测试失败！${NC}"
    echo -e "${RED}TextEdit 中没有找到"测试一下"${NC}"
    echo -e "${RED}========================================${NC}"

    # 显示最近的日志
    echo -e "\n${YELLOW}最近的日志（最后 20 行）:${NC}"
    tail -20 "$LOG_FILE"

    echo -e "\n${YELLOW}完整日志路径: $LOG_FILE${NC}"

    exit 1
fi
