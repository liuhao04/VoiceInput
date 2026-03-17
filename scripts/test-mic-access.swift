#!/usr/bin/env swift
import AVFoundation
import Foundation

print("测试麦克风访问...")

let status = AVCaptureDevice.authorizationStatus(for: .audio)
print("当前授权状态: \(status.rawValue)")
switch status {
case .notDetermined:
    print("未确定，正在请求权限...")
case .restricted:
    print("受限")
case .denied:
    print("已拒绝")
case .authorized:
    print("已授权")
@unknown default:
    print("未知状态")
}

if status == .notDetermined {
    print("请求麦克风访问...")
    let semaphore = DispatchSemaphore(value: 0)

    AVCaptureDevice.requestAccess(for: .audio) { granted in
        print("权限请求结果: \(granted)")
        if granted {
            print("✅ 用户授予了麦克风权限")
        } else {
            print("❌ 用户拒绝了麦克风权限")
        }
        semaphore.signal()
    }

    print("等待用户响应...")
    semaphore.wait()
} else if status == .authorized {
    print("✅ 已经有麦克风权限")

    // 尝试实际访问麦克风
    print("\n尝试访问麦克风设备...")
    if let device = AVCaptureDevice.default(for: .audio) {
        print("默认麦克风: \(device.localizedName)")
        do {
            let _ = try AVCaptureDeviceInput(device: device)
            print("✅ 成功创建音频输入，麦克风可用")
        } catch {
            print("❌ 创建音频输入失败: \(error)")
        }
    } else {
        print("❌ 没有找到默认麦克风")
    }
} else {
    print("❌ 麦克风权限不可用")
    print("请打开「系统设置」→「隐私与安全性」→「麦克风」")
    print("找到此脚本或 VoiceInput 并启用权限")
}

print("\n测试完成")
