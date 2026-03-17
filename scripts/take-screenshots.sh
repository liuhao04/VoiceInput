#!/bin/bash
# Take screenshots for README documentation

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SCREENSHOTS_DIR="$PROJECT_DIR/docs/screenshots"

mkdir -p "$SCREENSHOTS_DIR"

echo "📸 Screenshot guide for VoiceInput documentation"
echo ""
echo "Please manually take the following screenshots and save them to:"
echo "  $SCREENSHOTS_DIR"
echo ""
echo "Required screenshots:"
echo ""
echo "1. menubar-icon.png"
echo "   - Show the VoiceInput icon in the macOS menu bar"
echo "   - Take using: Cmd+Shift+4, then Space, then click menu bar area"
echo ""
echo "2. settings-window.png"
echo "   - Click VoiceInput menu bar icon → Settings"
echo "   - Show the settings window with App ID, Access Token fields"
echo "   - Take using: Cmd+Shift+4, then Space, then click settings window"
echo ""
echo "3. floating-panel.png"
echo "   - Press F5 (or your configured hotkey) to start recording"
echo "   - Speak some words to show transcription in the floating panel"
echo "   - Take using: Cmd+Shift+4, then select the floating panel area"
echo ""
echo "4. history-window.png (optional)"
echo "   - Click VoiceInput menu bar icon → Recognition History"
echo "   - Show the history window with past transcriptions"
echo "   - Take using: Cmd+Shift+4, then Space, then click history window"
echo ""
echo "After taking screenshots, run this script again to verify:"
echo "  ./scripts/take-screenshots.sh verify"
echo ""

if [ "$1" = "verify" ]; then
    echo "🔍 Verifying screenshots..."
    echo ""

    required_files=(
        "menubar-icon.png"
        "settings-window.png"
        "floating-panel.png"
    )

    optional_files=(
        "history-window.png"
    )

    all_exist=true
    for file in "${required_files[@]}"; do
        if [ -f "$SCREENSHOTS_DIR/$file" ]; then
            size=$(wc -c < "$SCREENSHOTS_DIR/$file")
            echo "✅ $file ($(numfmt --to=iec-i --suffix=B $size 2>/dev/null || echo "${size} bytes"))"
        else
            echo "❌ $file (missing)"
            all_exist=false
        fi
    done

    for file in "${optional_files[@]}"; do
        if [ -f "$SCREENSHOTS_DIR/$file" ]; then
            size=$(wc -c < "$SCREENSHOTS_DIR/$file")
            echo "✅ $file ($(numfmt --to=iec-i --suffix=B $size 2>/dev/null || echo "${size} bytes"))"
        else
            echo "⚠️  $file (optional, not found)"
        fi
    done

    echo ""
    if [ "$all_exist" = true ]; then
        echo "✅ All required screenshots are present!"
        echo ""
        echo "Next step: Update README.md to include these images:"
        echo "  ![Settings Window](docs/screenshots/settings-window.png)"
        echo "  ![Floating Panel](docs/screenshots/floating-panel.png)"
    else
        echo "❌ Some required screenshots are missing. Please take them and verify again."
        exit 1
    fi
fi
