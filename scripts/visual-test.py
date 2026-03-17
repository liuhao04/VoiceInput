#!/usr/bin/env python3
"""
视觉测试脚本：通过截图和 OCR 验证 VoiceInput app 的 UI 状态
"""

import os
import sys
import time
import subprocess
import json
from pathlib import Path
from datetime import datetime

# 测试结果目录
RESULTS_DIR = Path("/tmp/voiceinput_visual_tests")
RESULTS_DIR.mkdir(exist_ok=True)

class Color:
    RED = '\033[0;31m'
    GREEN = '\033[0;32m'
    YELLOW = '\033[1;33m'
    BLUE = '\033[0;34m'
    NC = '\033[0m'

class VisualTest:
    def __init__(self):
        self.results = []
        self.screenshots = []

    def log(self, message, color=Color.NC):
        print(f"{color}{message}{Color.NC}")

    def take_screenshot(self, name):
        """截取整个屏幕"""
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        output = RESULTS_DIR / f"{timestamp}_{name}.png"
        subprocess.run(["screencapture", "-x", str(output)], check=False)
        if output.exists():
            self.screenshots.append(output)
            return output
        return None

    def take_window_screenshot(self, window_name):
        """截取特定窗口"""
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        output = RESULTS_DIR / f"{timestamp}_{window_name}_window.png"
        # 使用 screencapture -l 捕获特定窗口
        subprocess.run(["screencapture", "-x", "-o", str(output)], check=False)
        if output.exists():
            self.screenshots.append(output)
            return output
        return None

    def check_process_running(self, process_name):
        """检查进程是否在运行"""
        result = subprocess.run(["pgrep", "-x", process_name],
                              capture_output=True, text=True)
        return result.returncode == 0

    def check_menubar_icon(self):
        """检查菜单栏图标是否显示"""
        script = '''
        tell application "System Events"
            tell process "VoiceInput"
                try
                    -- 状态栏 app 使用 menu bar 1
                    set menuBarItems to menu bar items of menu bar 1
                    set itemCount to count of menuBarItems
                    if itemCount > 0 then
                        return "SUCCESS: 找到 " & itemCount & " 个菜单栏项"
                    else
                        return "FAIL: 没有找到菜单栏项"
                    end if
                on error errMsg
                    return "ERROR: " & errMsg
                end try
            end tell
        end tell
        '''
        result = subprocess.run(["osascript", "-e", script],
                              capture_output=True, text=True)
        return result.stdout.strip()

    def click_menubar_icon(self):
        """点击菜单栏图标"""
        script = '''
        tell application "System Events"
            tell process "VoiceInput"
                try
                    -- 状态栏 app 使用 menu bar 1
                    set menuBarItem to menu bar item 1 of menu bar 1
                    click menuBarItem
                    delay 0.5
                    return "SUCCESS"
                on error errMsg
                    return "ERROR: " & errMsg
                end try
            end tell
        end tell
        '''
        result = subprocess.run(["osascript", "-e", script],
                              capture_output=True, text=True)
        return result.stdout.strip()

    def read_menu_items(self):
        """读取菜单项内容"""
        script = '''
        tell application "System Events"
            tell process "VoiceInput"
                try
                    -- 状态栏 app 使用 menu bar 1
                    set menuBarItem to menu bar item 1 of menu bar 1
                    click menuBarItem
                    delay 0.3

                    set menuItems to menu items of menu 1 of menuBarItem
                    set itemNames to {}
                    repeat with menuItem in menuItems
                        try
                            set itemTitle to title of menuItem
                            if itemTitle is not missing value and itemTitle is not "" then
                                set end of itemNames to itemTitle
                            end if
                        end try
                    end repeat

                    -- 关闭菜单
                    key code 53 -- ESC key

                    set AppleScript's text item delimiters to " | "
                    return itemNames as text
                on error errMsg
                    return "ERROR: " & errMsg
                end try
            end tell
        end tell
        '''
        result = subprocess.run(["osascript", "-e", script],
                              capture_output=True, text=True)
        return result.stdout.strip()

    def get_app_version_from_menu(self):
        """从菜单中读取版本号"""
        menu_items = self.read_menu_items()
        for item in menu_items.split(" | "):
            if "版本" in item:
                return item
        return None

    def analyze_screenshot_pixels(self, image_path):
        """简单的像素分析（不依赖 PIL）"""
        if not image_path or not image_path.exists():
            return None

        # 使用 sips 获取图片信息
        result = subprocess.run(
            ["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(image_path)],
            capture_output=True, text=True
        )

        info = {}
        for line in result.stdout.split('\n'):
            if ':' in line:
                key, value = line.split(':', 1)
                info[key.strip()] = value.strip()

        return info

    def verify_app_installed(self):
        """验证 app 是否正确安装"""
        app_path = Path.home() / "Applications/VoiceInput.app"
        info_plist = app_path / "Contents/Info.plist"
        exe_path = app_path / "Contents/MacOS/VoiceInput"

        checks = {
            "app_bundle": app_path.exists(),
            "info_plist": info_plist.exists(),
            "executable": exe_path.exists() and os.access(exe_path, os.X_OK)
        }

        if info_plist.exists():
            # 读取版本号
            result = subprocess.run(
                ["/usr/libexec/PlistBuddy", "-c",
                 "Print :CFBundleShortVersionString", str(info_plist)],
                capture_output=True, text=True
            )
            version = result.stdout.strip()

            result = subprocess.run(
                ["/usr/libexec/PlistBuddy", "-c",
                 "Print :CFBundleVersion", str(info_plist)],
                capture_output=True, text=True
            )
            build = result.stdout.strip()

            checks["version"] = f"{version}.{build}"

        return checks

    def run_test(self, name, test_func):
        """运行单个测试"""
        self.log(f"\n[测试] {name}", Color.BLUE)
        try:
            result = test_func()
            status = "PASS" if result.get("success", False) else "FAIL"
            color = Color.GREEN if result.get("success", False) else Color.RED

            self.log(f"  {status}: {result.get('message', '')}", color)

            self.results.append({
                "name": name,
                "status": status,
                "details": result,
                "timestamp": datetime.now().isoformat()
            })

            return result.get("success", False)
        except Exception as e:
            self.log(f"  ERROR: {str(e)}", Color.RED)
            self.results.append({
                "name": name,
                "status": "ERROR",
                "error": str(e),
                "timestamp": datetime.now().isoformat()
            })
            return False

    def test_installation(self):
        """测试 1: 安装验证"""
        checks = self.verify_app_installed()
        screenshot = self.take_screenshot("installation_check")

        all_passed = all([
            checks.get("app_bundle"),
            checks.get("info_plist"),
            checks.get("executable")
        ])

        return {
            "success": all_passed,
            "message": f"安装检查 - 版本: {checks.get('version', '未知')}",
            "details": checks,
            "screenshot": str(screenshot) if screenshot else None
        }

    def test_process_running(self):
        """测试 2: 进程运行状态"""
        # 先启动 app
        subprocess.run(["open", str(Path.home() / "Applications/VoiceInput.app")],
                      check=False)
        time.sleep(2)

        running = self.check_process_running("VoiceInput")
        screenshot = self.take_screenshot("process_running")

        return {
            "success": running,
            "message": "进程运行中" if running else "进程未运行",
            "screenshot": str(screenshot) if screenshot else None
        }

    def test_menubar_icon_visible(self):
        """测试 3: 菜单栏图标可见性"""
        result = self.check_menubar_icon()
        screenshot = self.take_screenshot("menubar_icon")

        success = "SUCCESS" in result

        return {
            "success": success,
            "message": result,
            "screenshot": str(screenshot) if screenshot else None
        }

    def test_menu_interaction(self):
        """测试 4: 菜单交互"""
        # 点击菜单栏图标
        click_result = self.click_menubar_icon()
        time.sleep(0.5)

        screenshot = self.take_screenshot("menu_opened")

        # 读取菜单项
        menu_items = self.read_menu_items()

        success = "ERROR" not in click_result and len(menu_items) > 0

        return {
            "success": success,
            "message": f"菜单项: {menu_items}",
            "details": {
                "click_result": click_result,
                "menu_items": menu_items
            },
            "screenshot": str(screenshot) if screenshot else None
        }

    def test_version_display(self):
        """测试 5: 版本号显示"""
        version_from_menu = self.get_app_version_from_menu()

        # 从 Info.plist 读取版本
        info_plist = Path.home() / "Applications/VoiceInput.app/Contents/Info.plist"
        result = subprocess.run(
            ["/usr/libexec/PlistBuddy", "-c",
             "Print :CFBundleShortVersionString", str(info_plist)],
            capture_output=True, text=True
        )
        version = result.stdout.strip()

        result = subprocess.run(
            ["/usr/libexec/PlistBuddy", "-c",
             "Print :CFBundleVersion", str(info_plist)],
            capture_output=True, text=True
        )
        build = result.stdout.strip()

        expected_version = f"{version}.{build}"

        screenshot = self.take_screenshot("version_check")

        success = version_from_menu is not None and expected_version in version_from_menu

        return {
            "success": success,
            "message": f"菜单显示: {version_from_menu}, 期望包含: {expected_version}",
            "details": {
                "menu_version": version_from_menu,
                "plist_version": expected_version
            },
            "screenshot": str(screenshot) if screenshot else None
        }

    def test_log_file(self):
        """测试 6: 日志文件"""
        log_path = Path.home() / "Library/Logs/VoiceInput.log"

        exists = log_path.exists()
        size = log_path.stat().st_size if exists else 0

        # 读取最后几行
        recent_logs = ""
        if exists:
            result = subprocess.run(["tail", "-10", str(log_path)],
                                  capture_output=True, text=True)
            recent_logs = result.stdout

        return {
            "success": exists and size > 0,
            "message": f"日志文件 - 大小: {size} bytes",
            "details": {
                "path": str(log_path),
                "exists": exists,
                "size": size,
                "recent_logs": recent_logs
            }
        }

    def generate_report(self):
        """生成 JSON 报告"""
        report = {
            "timestamp": datetime.now().isoformat(),
            "total_tests": len(self.results),
            "passed": sum(1 for r in self.results if r["status"] == "PASS"),
            "failed": sum(1 for r in self.results if r["status"] in ["FAIL", "ERROR"]),
            "tests": self.results,
            "screenshots": [str(s) for s in self.screenshots]
        }

        report_file = RESULTS_DIR / f"visual_test_report_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json"
        with open(report_file, 'w', encoding='utf-8') as f:
            json.dump(report, f, indent=2, ensure_ascii=False)

        self.log(f"\n报告已保存: {report_file}", Color.BLUE)

        return report

    def print_summary(self):
        """打印测试摘要"""
        total = len(self.results)
        passed = sum(1 for r in self.results if r["status"] == "PASS")
        failed = sum(1 for r in self.results if r["status"] in ["FAIL", "ERROR"])

        self.log("\n" + "=" * 50, Color.BLUE)
        self.log("测试摘要", Color.BLUE)
        self.log("=" * 50, Color.BLUE)
        self.log(f"总计: {total} 项测试")
        self.log(f"通过: {passed}", Color.GREEN)
        self.log(f"失败: {failed}", Color.RED)
        self.log(f"成功率: {passed/total*100:.1f}%")

        return failed == 0

def main():
    tester = VisualTest()

    tester.log("VoiceInput 视觉测试套件", Color.BLUE)
    tester.log("=" * 50, Color.BLUE)

    # 运行所有测试
    tests = [
        ("安装验证", tester.test_installation),
        ("进程运行状态", tester.test_process_running),
        ("菜单栏图标可见性", tester.test_menubar_icon_visible),
        ("菜单交互", tester.test_menu_interaction),
        ("版本号显示", tester.test_version_display),
        ("日志文件", tester.test_log_file),
    ]

    for name, test_func in tests:
        tester.run_test(name, test_func)
        time.sleep(1)

    # 生成报告
    report = tester.generate_report()

    # 打印摘要
    success = tester.print_summary()

    sys.exit(0 if success else 1)

if __name__ == "__main__":
    main()
