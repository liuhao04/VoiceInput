#!/usr/bin/env bash
# 实时测试粘贴功能
set -e

echo "🎤 VoiceInput 粘贴功能实时测试"
echo "================================"
echo ""
echo "测试步骤："
echo "1. 打开 TextEdit"
echo "2. 创建新文档"
echo "3. 等待 2 秒"
echo "4. 模拟 VoiceInput 粘贴流程"
echo ""

# 打开 TextEdit
echo "启动 TextEdit..."
osascript -e 'tell application "TextEdit" to activate' 2>/dev/null
sleep 0.5
osascript -e 'tell application "TextEdit" to make new document' 2>/dev/null
sleep 1

# 获取 TextEdit 的 NSRunningApplication
TEST_TEXT="测试语音识别结果：今天天气真不错！$(date +%H:%M:%S)"

echo "测试文本: $TEST_TEXT"
echo ""
echo "模拟粘贴流程..."

# 使用 Swift 直接调用 VoiceInput 的粘贴逻辑
cat > /tmp/test_paste.swift <<EOF
import AppKit
import Carbon

// 从 VoiceInput 复制的粘贴逻辑
let text = "$TEST_TEXT"
NSPasteboard.general.clearContents()
NSPasteboard.general.setString(text, forType: .string)
print("[1] 剪贴板已写入")

if let app = NSWorkspace.shared.runningApplications.first(where: { \$0.bundleIdentifier == "com.apple.TextEdit" }) {
    print("[2] 找到 TextEdit: \\(app.localizedName ?? "?")")

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
        let activated = app.activate(options: [.activateIgnoringOtherApps])
        print("[3] 激活 TextEdit: \\(activated)")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            print("[4] 模拟 Cmd+V...")

            let source = CGEventSource(stateID: .combinedSessionState)
            source?.localEventsSuppressionInterval = 0.0

            if let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(0x37), keyDown: true) {
                cmdDown.post(tap: .cghidEventTap)
            }

            usleep(10000)

            if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(0x09), keyDown: true),
               let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(0x09), keyDown: false) {
                keyDown.flags = .maskCommand
                keyUp.flags = .maskCommand
                keyDown.post(tap: .cghidEventTap)
                usleep(10000)
                keyUp.post(tap: .cghidEventTap)
            }

            usleep(10000)

            if let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(0x37), keyDown: false) {
                cmdUp.post(tap: .cghidEventTap)
            }

            print("[5] Cmd+V 已发送")

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                // 验证结果
                if let script = NSAppleScript(source: "tell application \\"TextEdit\\" to get text of document 1") {
                    var error: NSDictionary?
                    let result = script.executeAndReturnError(&error)
                    let docText = result.stringValue ?? ""

                    if docText.contains(text) {
                        print("[6] ✅ 成功！文本已粘贴到 TextEdit")
                        print("    文档内容: \\(docText.prefix(50))...")
                        exit(0)
                    } else {
                        print("[6] ❌ 失败：文档中未找到文本")
                        print("    期望: \\(text)")
                        print("    实际: \\(docText)")
                        exit(1)
                    }
                }
            }
        }
    }

    RunLoop.main.run(until: Date(timeIntervalSinceNow: 5))
} else {
    print("❌ 找不到 TextEdit")
    exit(1)
}
EOF

swift /tmp/test_paste.swift 2>&1

if [ $? -eq 0 ]; then
    echo ""
    echo "================================"
    echo "✅ 粘贴功能测试通过！"
    echo "================================"
else
    echo ""
    echo "================================"
    echo "❌ 粘贴功能测试失败"
    echo "================================"
    exit 1
fi
