#!/usr/bin/env python3
"""
查找 VoiceInput 面板窗口并点击中心位置
"""
import Quartz
import subprocess
import sys

def find_voiceinput_window():
    """查找 VoiceInput 的窗口"""
    windows = Quartz.CGWindowListCopyWindowInfo(
        Quartz.kCGWindowListOptionAll,
        Quartz.kCGNullWindowID
    )

    for window in windows:
        owner = window.get('kCGWindowOwnerName', '')
        if owner == 'VoiceInput':
            bounds = window.get('kCGWindowBounds', {})
            x = bounds.get('X', 0)
            y = bounds.get('Y', 0)
            w = bounds.get('Width', 0)
            h = bounds.get('Height', 0)

            print(f"找到面板: 位置({x}, {y}) 大小({w}x{h})", file=sys.stderr)

            # 计算中心点
            center_x = int(x + w / 2)
            center_y = int(y + h / 2)

            return center_x, center_y

    return None, None

def click_position(x, y):
    """使用 cliclick 点击指定位置"""
    subprocess.run(['cliclick', f'c:{x},{y}'])

if __name__ == '__main__':
    x, y = find_voiceinput_window()

    if x is not None:
        print(f"点击位置: ({x}, {y})", file=sys.stderr)
        click_position(x, y)
        print(f"{x},{y}")  # 输出给 shell 脚本使用
        sys.exit(0)
    else:
        print("❌ 未找到 VoiceInput 窗口", file=sys.stderr)
        sys.exit(1)
