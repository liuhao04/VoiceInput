#!/usr/bin/env swift
import AVFoundation
import Foundation

print("直接测试麦克风和 AVAudioEngine")
print("Bundle ID: \(Bundle.main.bundleIdentifier ?? "none")")

// 1. 检查权限
let status = AVCaptureDevice.authorizationStatus(for: .audio)
print("麦克风权限状态: \(status.rawValue) (0=未确定, 2=拒绝, 3=已授权)")

if status != .authorized {
    print("权限未授予，正在请求...")
    let sem = DispatchSemaphore(value: 0)
    AVCaptureDevice.requestAccess(for: .audio) { granted in
        print("权限请求结果: \(granted)")
        sem.signal()
    }
    sem.wait()
}

// 2. 测试 AVAudioEngine
print("\n创建 AVAudioEngine...")
let engine = AVAudioEngine()

print("访问 inputNode（这可能会阻塞）...")
let start = Date()
let inputNode = engine.inputNode
let elapsed = Date().timeIntervalSince(start)
print("✓ inputNode 获取成功！耗时: \(String(format: "%.3f", elapsed))秒")

let inputFormat = inputNode.outputFormat(forBus: 0)
print("输入格式: \(inputFormat.sampleRate) Hz, \(inputFormat.channelCount) channels")

// 3. 尝试启动引擎
print("\n启动音频引擎...")
do {
    // 安装 tap
    inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, time in
        print("收到音频缓冲区: \(buffer.frameLength) frames")
    }

    try engine.start()
    print("✓ 引擎启动成功！")

    print("\n录制 2 秒...")
    sleep(2)

    engine.stop()
    inputNode.removeTap(onBus: 0)
    print("✓ 测试完成")
} catch {
    print("❌ 引擎启动失败: \(error)")
    exit(1)
}
