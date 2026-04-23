# VoiceInput 发布计划

> 创建日期：2026-03-27
> 目标：尽快将产品发布给公众使用

## 现状总结

- 核心功能已完整：全局热键、流式语音识别、自动粘贴、实时预览、历史记录、文本替换
- 文档齐全：中英文 README、CONTRIBUTING、CHANGELOG
- CI/CD 已配置：GitHub Actions 自动构建和发布 DMG
- 代码质量良好：零 TODO/FIXME，完善的测试体系

---

## P0 - 必须做（不做就不能发布）

### 1. 代码签名 + 公证（Notarization）

- [ ] 注册 Apple Developer Program（$99/年），获取 Developer ID Application 证书
- [ ] 在 GitHub Actions release.yml 中配置签名流程
- [ ] 使用 `notarytool` 提交公证，生成 stapled DMG
- [ ] 测试：从 GitHub Release 下载 DMG，确认无 Gatekeeper 拦截

**为什么必须做：** 没有签名公证，普通用户下载后会看到"无法验证开发者"弹窗，大部分人会直接放弃。

### 2. 隐私政策

- [ ] 撰写隐私政策，说明：
  - 麦克风录音仅用于语音识别，不存储音频
  - 音频数据发送到火山引擎进行 ASR 处理
  - 识别历史仅存储在本地 / 用户 iCloud
  - 不收集任何用户分析数据
- [ ] 发布到 GitHub Pages（或项目 docs/ 目录）
- [ ] 在 README 和 app 菜单中添加隐私政策链接

---

## P1 - 强烈建议做（显著提升产品竞争力）

### 3. 自动更新（Sparkle）

- [ ] 集成 [Sparkle 2](https://sparkle-project.org/) 框架
- [ ] 在服务端（GitHub Pages 或 Release）托管 appcast.xml
- [ ] 在 release.yml 中自动生成签名的 appcast 条目
- [ ] 测试：旧版本能检测到新版本并自动更新

**为什么重要：** 没有自动更新，用户永远停留在旧版本，bug 修复和新功能无法触达。

### 4. Homebrew Cask

- [ ] 创建 Cask formula，支持 `brew install --cask voiceinput`
- [ ] 提交到 [homebrew-cask](https://github.com/Homebrew/homebrew-cask)（需要先完成代码签名）
- [ ] 在 README 中添加 Homebrew 安装方式

**为什么重要：** macOS 开发者/技术用户最熟悉的安装方式，大幅降低安装门槛。

### 5. Demo GIF

- [ ] 录制 15-20 秒演示视频：按 F5 → 说话 → 文字出现 → 自动粘贴
- [ ] 转为 GIF 或上传视频，替换 README 中的 TODO 占位符
- [ ] 建议同时准备中英文版本

**为什么重要：** README 的 demo 是用户决定是否试用的第一印象。

### 6. Landing Page（产品主页）

- [ ] 用 GitHub Pages 创建单页网站，内容包括：
  - 产品截图 / demo 动图
  - 核心特性介绍
  - 下载链接（指向 GitHub Release）
  - 隐私政策链接
- [ ] 绑定自定义域名（可选）

---

## P2 - 后续迭代

### 7. 英文本地化

- [ ] 添加 Localizable.strings 基础设施
- [ ] 翻译 SettingsView、菜单项等 UI 文本
- [ ] 扩大国际用户群

### 8. 崩溃上报

- [ ] 考虑轻量方案（如 [PLCrashReporter](https://github.com/nicklama/plcrash) 或 Sentry）
- [ ] 帮助追踪线上崩溃问题

### 9. DMG 美化

- [ ] 添加背景图和 Applications 文件夹快捷方式
- [ ] 使用 [create-dmg](https://github.com/create-dmg/create-dmg) 工具自动化

---

## 建议的发布路径

### 最快路径（1-2 天）
> 签名公证 + 隐私政策 → GitHub Release → 社区推广（V2EX、少数派等）

### 推荐路径（约 1 周）
> P0 全部 + Sparkle 自动更新 + Homebrew Cask + demo GIF + 简单主页

---

## 推广渠道建议

- [V2EX](https://v2ex.com/) - /t/create 节点：macOS / 分享创造
- [少数派](https://sspai.com/) - 投稿或 Matrix 社区
- [Product Hunt](https://producthunt.com/) - 国际推广
- [Hacker News](https://news.ycombinator.com/) - Show HN
- GitHub trending - 保持活跃的 commit 和 release
- Twitter/X、即刻等社交媒体
