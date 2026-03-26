import SwiftUI
import ServiceManagement

/// SwiftUI 设置界面，通过 NSHostingView 嵌入 NSWindow
struct SettingsView: View {
    // MARK: - State

    @State private var triggerKeys: Set<TriggerKey> = Config.triggerKeys
    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled

    @State private var volcAppId: String = Config.volcAppId
    @State private var volcAccessToken: String = Config.volcAccessToken
    @State private var volcResourceId: String = Config.volcResourceId
    @State private var asrWebSocketURL: String = Config.asrWebSocketURL
    @State private var boostingTableId: String = Config.boostingTableId

    @State private var replaceRulesFilePath: String = Config.replaceRulesFilePath
    @State private var replaceRules: [ReplaceRule] = TextReplacer.shared.rules
    @State private var selectedRuleIndex: Int? = nil
    @State private var editingRuleFrom: [Int: String] = [:]
    @State private var editingRuleTo: [Int: String] = [:]

    @State private var selectedTab: Int = 0
    @State private var showingAddRule = false
    @State private var newRuleFrom = ""
    @State private var newRuleTo = ""
    @State private var validationError: String? = nil

    var onClose: (() -> Void)? = nil
    var initialTab: Int = 0

    private let labelWidth: CGFloat = 120

    // MARK: - Body

    var body: some View {
        TabView(selection: $selectedTab) {
            generalTab
                .tabItem { Label("通用", systemImage: "gearshape") }
                .tag(0)
            asrConfigTab
                .tabItem { Label("语音识别", systemImage: "mic") }
                .tag(1)
            replaceTab
                .tabItem { Label("词语替换", systemImage: "arrow.left.arrow.right") }
                .tag(2)
        }
        .frame(width: 560, height: 420)
        .onAppear { selectedTab = initialTab }
        .sheet(isPresented: $showingAddRule) {
            addRuleSheet
        }
    }

    // MARK: - Tab 1: 通用

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            // 开机自启动
            sectionHeader("启动")
            Toggle("开机自启动", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { newValue in
                    toggleLaunchAtLogin(newValue)
                }
                .padding(.leading, 4)

            Divider()

            // 触发键
            sectionHeader("触发键（单独按下触发语音输入）")
            LazyVGrid(columns: [
                GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())
            ], alignment: .leading, spacing: 6) {
                ForEach(TriggerKey.allCases, id: \.rawValue) { key in
                    Toggle(key.displayName, isOn: Binding(
                        get: { triggerKeys.contains(key) },
                        set: { isOn in
                            if isOn {
                                triggerKeys.insert(key)
                            } else if triggerKeys.count > 1 {
                                triggerKeys.remove(key)
                            }
                            Config.triggerKeys = triggerKeys
                            Log.log("[Settings] 触发键已更新: \(triggerKeys.map { $0.displayName })")
                        }
                    ))
                    .toggleStyle(.checkbox)
                }
            }
            .padding(.leading, 4)

            Spacer()
        }
        .padding(24)
    }

    // MARK: - Tab 2: 语音识别配置

    private var asrConfigTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("火山引擎 ASR 配置")

            VStack(spacing: 10) {
                formRow("App ID:", text: $volcAppId)
                formRow("Access Token:", text: $volcAccessToken)
                formRow("Resource ID:", text: $volcResourceId)
                formRow("WebSocket URL:", text: $asrWebSocketURL)
                formRow("热词表 ID:", text: $boostingTableId)
            }

            Spacer()

            // 保存按钮
            HStack {
                if let error = validationError {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }
                Spacer()
                Button("保存") {
                    save()
                }
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(24)
    }

    // MARK: - Tab 3: 词语替换

    private var replaceTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("词语替换（识别结果自动替换）")

            // 文件路径行
            HStack(spacing: 8) {
                Text("规则文件:")
                    .frame(width: 70, alignment: .trailing)
                Text(replaceRulesFilePath.isEmpty ? "未选择" : shortenPath(replaceRulesFilePath))
                    .foregroundColor(.secondary)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("选择文件") { chooseReplaceFile() }
                    .controlSize(.small)
                Button("新建") { createReplaceFile() }
                    .controlSize(.small)
            }

            // 规则列表（支持选中编辑）
            HStack(spacing: 0) {
                // 表头
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Text("原词")
                            .font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                        Divider().frame(height: 20)
                        Text("替换为")
                            .font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                    }
                    .background(Color(nsColor: .controlBackgroundColor))
                    Divider()

                    // 规则行列表
                    List(selection: Binding(
                        get: { selectedRuleIndex },
                        set: { newIndex in
                            commitEditingRule()
                            selectedRuleIndex = newIndex
                            if let idx = newIndex, idx < replaceRules.count {
                                editingRuleFrom[idx] = replaceRules[idx].from
                                editingRuleTo[idx] = replaceRules[idx].to
                            }
                        }
                    )) {
                        ForEach(indexedRules) { item in
                            HStack(spacing: 0) {
                                if selectedRuleIndex == item.id {
                                    TextField("原词", text: Binding(
                                        get: { editingRuleFrom[item.id] ?? item.rule.from },
                                        set: { editingRuleFrom[item.id] = $0 }
                                    ))
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 12))
                                    .frame(maxWidth: .infinity)
                                    .padding(.trailing, 4)

                                    TextField("替换为", text: Binding(
                                        get: { editingRuleTo[item.id] ?? item.rule.to },
                                        set: { editingRuleTo[item.id] = $0 }
                                    ))
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 12))
                                    .frame(maxWidth: .infinity)
                                } else {
                                    Text(item.rule.from)
                                        .font(.system(size: 12))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.trailing, 4)
                                    Text(item.rule.to)
                                        .font(.system(size: 12))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .tag(item.id)
                            .padding(.vertical, 2)
                        }
                    }
                    .listStyle(.plain)
                }
                .border(Color(nsColor: .separatorColor), width: 0.5)

                // 排序按钮（右侧竖排）
                VStack(spacing: 4) {
                    Button(action: { moveRuleUp() }) {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .disabled(selectedRuleIndex == nil || selectedRuleIndex == 0)

                    Button(action: { moveRuleDown() }) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .disabled(selectedRuleIndex == nil || selectedRuleIndex == replaceRules.count - 1)
                }
                .padding(.leading, 6)
            }

            HStack(spacing: 8) {
                Button("添加") {
                    if replaceRulesFilePath.isEmpty {
                        validationError = "请先选择或新建规则文件"
                    } else {
                        newRuleFrom = ""
                        newRuleTo = ""
                        showingAddRule = true
                    }
                }
                .controlSize(.small)
                Button("删除") {
                    deleteSelectedRule()
                }
                .controlSize(.small)
                .disabled(selectedRuleIndex == nil)

                Spacer()

                if let error = validationError {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }
        }
        .padding(24)
    }

    // MARK: - Subviews

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .bold))
    }

    private func formRow(_ label: String, text: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .frame(width: labelWidth, alignment: .trailing)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
        }
    }

    private var addRuleSheet: some View {
        VStack(spacing: 16) {
            Text("添加替换规则")
                .font(.headline)
            TextField("原词（被替换的词）", text: $newRuleFrom)
                .textFieldStyle(.roundedBorder)
            TextField("替换为", text: $newRuleTo)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("取消") { showingAddRule = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("添加") {
                    let from = newRuleFrom.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !from.isEmpty {
                        TextReplacer.shared.addRule(from: from, to: newRuleTo.trimmingCharacters(in: .whitespacesAndNewlines))
                        replaceRules = TextReplacer.shared.rules
                        Log.log("[Settings] 添加替换规则: \"\(from)\" → \"\(newRuleTo)\"")
                    }
                    showingAddRule = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 350)
    }

    // MARK: - Helpers

    private struct IndexedRule: Identifiable {
        let id: Int
        let rule: ReplaceRule
    }

    private var indexedRules: [IndexedRule] {
        replaceRules.enumerated().map { IndexedRule(id: $0.offset, rule: $0.element) }
    }

    private func shortenPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    // MARK: - Actions

    private func toggleLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                Log.log("[Settings] 开机自启动已启用")
            } else {
                try SMAppService.mainApp.unregister()
                Log.log("[Settings] 开机自启动已禁用")
            }
        } catch {
            Log.log("[Settings] 开机自启动设置失败: \(error.localizedDescription)")
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func chooseReplaceFile() {
        let panel = NSOpenPanel()
        panel.title = "选择词语替换规则文件"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())

        if panel.runModal() == .OK, let url = panel.url {
            Config.replaceRulesFilePath = url.path
            replaceRulesFilePath = url.path
            TextReplacer.shared.reload()
            replaceRules = TextReplacer.shared.rules
            Log.log("[Settings] 已选择替换规则文件: \(url.path)")
        }
    }

    private func createReplaceFile() {
        let panel = NSSavePanel()
        panel.title = "新建词语替换规则文件"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "replace-rules.json"
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())

        if panel.runModal() == .OK, let url = panel.url {
            let emptyArray = "[\n]\n".data(using: .utf8)!
            do {
                try emptyArray.write(to: url, options: .atomic)
                Config.replaceRulesFilePath = url.path
                replaceRulesFilePath = url.path
                TextReplacer.shared.reload()
                replaceRules = TextReplacer.shared.rules
                Log.log("[Settings] 已创建新替换规则文件: \(url.path)")
            } catch {
                Log.log("[Settings] 创建规则文件失败: \(error.localizedDescription)")
            }
        }
    }

    private func commitEditingRule() {
        guard let index = selectedRuleIndex, index < replaceRules.count else { return }
        let newFrom = (editingRuleFrom[index] ?? replaceRules[index].from).trimmingCharacters(in: .whitespacesAndNewlines)
        let newTo = (editingRuleTo[index] ?? replaceRules[index].to).trimmingCharacters(in: .whitespacesAndNewlines)
        if !newFrom.isEmpty && (newFrom != replaceRules[index].from || newTo != replaceRules[index].to) {
            TextReplacer.shared.updateRule(at: index, from: newFrom, to: newTo)
            replaceRules = TextReplacer.shared.rules
            Log.log("[Settings] 更新替换规则 #\(index): \"\(newFrom)\" → \"\(newTo)\"")
        }
        editingRuleFrom.removeValue(forKey: index)
        editingRuleTo.removeValue(forKey: index)
    }

    private func deleteSelectedRule() {
        guard let index = selectedRuleIndex, index < replaceRules.count else { return }
        editingRuleFrom.removeAll()
        editingRuleTo.removeAll()
        TextReplacer.shared.removeRule(at: index)
        replaceRules = TextReplacer.shared.rules
        selectedRuleIndex = nil
        Log.log("[Settings] 删除替换规则 #\(index)")
    }

    private func moveRuleUp() {
        guard let index = selectedRuleIndex, index > 0 else { return }
        commitEditingRule()
        TextReplacer.shared.swapRules(index, index - 1)
        replaceRules = TextReplacer.shared.rules
        selectedRuleIndex = index - 1
        Log.log("[Settings] 上移替换规则 #\(index) → #\(index - 1)")
    }

    private func moveRuleDown() {
        guard let index = selectedRuleIndex, index < replaceRules.count - 1 else { return }
        commitEditingRule()
        TextReplacer.shared.swapRules(index, index + 1)
        replaceRules = TextReplacer.shared.rules
        selectedRuleIndex = index + 1
        Log.log("[Settings] 下移替换规则 #\(index) → #\(index + 1)")
    }

    private func save() {
        let appId = volcAppId.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = volcAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let resourceId = volcResourceId.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = asrWebSocketURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let boostingId = boostingTableId.trimmingCharacters(in: .whitespacesAndNewlines)

        if appId.isEmpty || token.isEmpty || resourceId.isEmpty || url.isEmpty {
            validationError = "App ID、Access Token、Resource ID 和 WebSocket URL 不能为空"
            return
        }

        validationError = nil

        Config.volcAppId = appId
        Config.volcAccessToken = token
        Config.volcResourceId = resourceId
        Config.asrWebSocketURL = url
        Config.boostingTableId = boostingId

        Log.log("[Settings] 火山引擎配置已保存")
        onClose?()
    }
}
