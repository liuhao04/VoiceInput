#!/usr/bin/env python3
"""
生成 VoiceInput 应用图标
使用 PIL 创建一个简洁的麦克风图标，支持深色和浅色模式
"""

from PIL import Image, ImageDraw, ImageFont
import os

def create_icon(size):
    """创建指定尺寸的图标"""
    # 创建带透明背景的图像
    img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # 渐变蓝色背景（模拟 macOS Big Sur 风格）
    # 从浅蓝到深蓝
    for y in range(size):
        ratio = y / size
        r = int(70 + (30 - 70) * ratio)
        g = int(150 + (100 - 150) * ratio)
        b = int(255 + (200 - 255) * ratio)
        draw.rectangle([(0, y), (size, y+1)], fill=(r, g, b, 255))

    # 添加圆角
    mask = Image.new('L', (size, size), 0)
    mask_draw = ImageDraw.Draw(mask)
    corner_radius = int(size * 0.225)  # macOS 图标圆角比例
    mask_draw.rounded_rectangle([(0, 0), (size, size)], corner_radius, fill=255)
    img.putalpha(mask)

    # 绘制麦克风图标 (白色)
    padding = size * 0.25
    mic_color = (255, 255, 255, 255)

    # 麦克风主体 (胶囊形状)
    mic_width = size * 0.18
    mic_height = size * 0.3
    mic_x = size / 2
    mic_y = size * 0.35

    # 绘制麦克风胶囊
    draw.rounded_rectangle(
        [(mic_x - mic_width, mic_y - mic_height/2),
         (mic_x + mic_width, mic_y + mic_height/2)],
        radius=mic_width,
        fill=mic_color
    )

    # 麦克风底座支架 (U形)
    stand_width = size * 0.25
    stand_height = size * 0.18
    stand_y = mic_y + mic_height/2 + size * 0.05
    stand_thickness = size * 0.05

    # 绘制 U 形支架
    draw.arc(
        [(mic_x - stand_width, stand_y),
         (mic_x + stand_width, stand_y + stand_height * 2)],
        start=0, end=180,
        fill=mic_color,
        width=int(stand_thickness)
    )

    # 底部横线
    bottom_y = stand_y + stand_height
    draw.line(
        [(mic_x - stand_width, bottom_y),
         (mic_x + stand_width, bottom_y)],
        fill=mic_color,
        width=int(stand_thickness)
    )

    # 底部垂直线
    draw.line(
        [(mic_x, stand_y + stand_height/2),
         (mic_x, bottom_y)],
        fill=mic_color,
        width=int(stand_thickness)
    )

    # 添加声波效果 (圆弧)
    wave_count = 2
    for i in range(wave_count):
        wave_offset = size * (0.15 + i * 0.08)
        alpha = int(200 - i * 80)
        wave_thickness = max(2, int(size * 0.03 - i * 0.01))

        # 左侧声波
        draw.arc(
            [(mic_x - mic_width - wave_offset, mic_y - wave_offset),
             (mic_x - mic_width, mic_y + wave_offset)],
            start=-45, end=45,
            fill=(255, 255, 255, alpha),
            width=wave_thickness
        )

        # 右侧声波
        draw.arc(
            [(mic_x + mic_width, mic_y - wave_offset),
             (mic_x + mic_width + wave_offset, mic_y + wave_offset)],
            start=135, end=225,
            fill=(255, 255, 255, alpha),
            width=wave_thickness
        )

    return img

def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_dir = os.path.dirname(script_dir)

    # 创建 Assets 目录
    assets_dir = os.path.join(project_dir, "Assets")
    os.makedirs(assets_dir, exist_ok=True)

    # 创建 AppIcon.appiconset 目录
    iconset_dir = os.path.join(assets_dir, "AppIcon.appiconset")
    os.makedirs(iconset_dir, exist_ok=True)

    # macOS 需要的图标尺寸
    sizes = [
        (16, "icon_16x16.png", 1),
        (32, "icon_16x16@2x.png", 2),
        (32, "icon_32x32.png", 1),
        (64, "icon_32x32@2x.png", 2),
        (128, "icon_128x128.png", 1),
        (256, "icon_128x128@2x.png", 2),
        (256, "icon_256x256.png", 1),
        (512, "icon_256x256@2x.png", 2),
        (512, "icon_512x512.png", 1),
        (1024, "icon_512x512@2x.png", 2),
    ]

    print("生成图标...")
    for size, filename, scale in sizes:
        print(f"  生成 {filename} ({size}x{size})")
        icon = create_icon(size)
        icon.save(os.path.join(iconset_dir, filename))

    # 创建 Contents.json
    contents = {
        "images": [
            {"size": "16x16", "idiom": "mac", "filename": "icon_16x16.png", "scale": "1x"},
            {"size": "16x16", "idiom": "mac", "filename": "icon_16x16@2x.png", "scale": "2x"},
            {"size": "32x32", "idiom": "mac", "filename": "icon_32x32.png", "scale": "1x"},
            {"size": "32x32", "idiom": "mac", "filename": "icon_32x32@2x.png", "scale": "2x"},
            {"size": "128x128", "idiom": "mac", "filename": "icon_128x128.png", "scale": "1x"},
            {"size": "128x128", "idiom": "mac", "filename": "icon_128x128@2x.png", "scale": "2x"},
            {"size": "256x256", "idiom": "mac", "filename": "icon_256x256.png", "scale": "1x"},
            {"size": "256x256", "idiom": "mac", "filename": "icon_256x256@2x.png", "scale": "2x"},
            {"size": "512x512", "idiom": "mac", "filename": "icon_512x512.png", "scale": "1x"},
            {"size": "512x512", "idiom": "mac", "filename": "icon_512x512@2x.png", "scale": "2x"},
        ],
        "info": {
            "version": 1,
            "author": "xcode"
        }
    }

    import json
    with open(os.path.join(iconset_dir, "Contents.json"), 'w') as f:
        json.dump(contents, f, indent=2)

    # 生成 .icns 文件用于 app bundle
    print("\n生成 .icns 文件...")
    icns_path = os.path.join(assets_dir, "AppIcon.icns")
    os.system(f'iconutil -c icns "{iconset_dir}" -o "{icns_path}"')

    print(f"\n✅ 图标生成完成!")
    print(f"   iconset: {iconset_dir}")
    print(f"   icns: {icns_path}")
    print(f"\n下一步：将 AppIcon.icns 复制到 app bundle 的 Resources 目录")

if __name__ == "__main__":
    main()
