import SwiftUI
import ServiceManagement

/// SwiftUI 设置界面，通过 NSHostingView 嵌入 NSWindow
struct SettingsView: View {
    // MARK: - State

    @State private var triggerKeys: Set<TriggerKey> = Config.triggerKeys
    @State private var triggerActivation: TriggerActivation = Config.triggerActivation
    @State private var customBindings: [HotkeyBinding] = Config.customTriggerBindings
    @State private var pendingNewCustomBinding: HotkeyBinding? = nil
    @State private var pasteLastBinding: HotkeyBinding? = Config.pasteLastHotkey
    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled

    @State private var volcAppId: String = Config.volcAppId
    @State private var volcAccessToken: String = Config.volcAccessToken
    @State private var volcResourceId: String = Config.volcResourceId
    @State private var asrMode: ASRMode = Config.asrMode
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
    var onPasteLastHotkeyChanged: (() -> Void)? = nil
    var onCustomTriggerBindingsChanged: (() -> Void)? = nil
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
        .frame(width: 560, height: 520)
        .onAppear { selectedTab = initialTab }
        .sheet(isPresented: $showingAddRule) {
            addRuleSheet
        }
    }

    // MARK: - Tab 1: 通用

    private var generalTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // 开机自启动
                sectionHeader("启动")
                Toggle("开机自启动", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { newValue in
                        toggleLaunchAtLogin(newValue)
                    }
                    .padding(.leading, 4)

                Divider()

                // 触发键
                HStack {
                    sectionHeader("触发键（单独按下触发语音输入）")
                    Spacer()
                    Picker("", selection: $triggerActivation) {
                        ForEach(TriggerActivation.allCases, id: \.rawValue) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 90)
                    .onChange(of: triggerActivation) { newValue in
                        Config.triggerActivation = newValue
                        Log.log("[Settings] 触发方式已更新: \(newValue.displayName)")
                    }
                }

                LazyVGrid(columns: [
                    GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())
                ], alignment: .leading, spacing: 6) {
                    ForEach(TriggerKey.allCases, id: \.rawValue) { key in
                        Toggle(key.displayName, isOn: Binding(
                            get: { triggerKeys.contains(key) },
                            set: { isOn in
                                if isOn {
                                    triggerKeys.insert(key)
                                } else if triggerKeys.count > 1 || !customBindings.isEmpty {
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

                // 自定义触发键：内联录入（支持单修饰键或组合键如 ⌘⇧A）
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Text("自定义触发键:").font(.system(size: 12))
                        HotkeyRecorderView(
                            binding: $pendingNewCustomBinding,
                            mode: .trigger,
                            placeholder: "点击录入（单修饰键或组合键）",
                            onChange: { commitPendingCustomBinding() }
                        )
                        Spacer()
                    }
                    if !customBindings.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(Array(customBindings.enumerated()), id: \.offset) { idx, b in
                                HStack(spacing: 2) {
                                    Text(b.displayName).font(.system(size: 12))
                                    Button(action: { removeCustomBinding(at: idx) }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.12))
                                .cornerRadius(4)
                            }
                            Spacer()
                        }
                    }
                }
                .padding(.leading, 4)

                // 使用提示
                (Text("ℹ️ 若常有误触发，切换到\"双击\"。") +
                 Text("macOS 系统偏好「键盘 → 听写」可能把 fn 双击设为系统听写快捷键 —— 若冲突请在系统偏好关闭听写快捷键。")
                    .foregroundColor(.secondary))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 4)

                Divider()

                // 全局快捷键
                sectionHeader("全局快捷键")
                HStack(spacing: 10) {
                    Text("粘贴最后识别结果：").font(.system(size: 12))
                    HotkeyRecorderView(
                        binding: $pasteLastBinding,
                        mode: .combo,
                        placeholder: "未设置（点击录入）",
                        onChange: { savePasteLastHotkey() }
                    )
                    if pasteLastBinding != nil {
                        Button("清除") {
                            pasteLastBinding = nil
                            savePasteLastHotkey()
                        }
                        .controlSize(.small)
                    }
                }
                .padding(.leading, 4)

                Spacer(minLength: 12)
            }
            .padding(24)
        }
    }

    private func commitPendingCustomBinding() {
        guard let b = pendingNewCustomBinding else { return }
        let isDuplicate: Bool
        if b.deviceFlag != 0 {
            isDuplicate = customBindings.contains { $0.deviceFlag == b.deviceFlag }
        } else {
            isDuplicate = customBindings.contains { $0.keyCode == b.keyCode && $0.modifiers == b.modifiers }
        }
        if !isDuplicate {
            customBindings.append(b)
            Config.customTriggerBindings = customBindings
            onCustomTriggerBindingsChanged?()
            Log.log("[Settings] 添加自定义触发键: \(b.displayName)")
        }
        pendingNewCustomBinding = nil
    }

    private func removeCustomBinding(at idx: Int) {
        guard idx < customBindings.count else { return }
        let removed = customBindings.remove(at: idx)
        Config.customTriggerBindings = customBindings
        onCustomTriggerBindingsChanged?()
        Log.log("[Settings] 移除自定义触发键: \(removed.displayName)")
    }

    private func savePasteLastHotkey() {
        Config.pasteLastHotkey = pasteLastBinding
        onPasteLastHotkeyChanged?()
        Log.log("[Settings] 粘贴最后识别结果快捷键已更新: \(pasteLastBinding?.displayName ?? "(清除)")")
    }

    // MARK: - Tab 2: 语音识别配置

    private var asrConfigTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("火山引擎 ASR 配置")

            VStack(spacing: 10) {
                formRow("App ID:", text: $volcAppId)
                formRow("Access Token:", text: $volcAccessToken)
                formRow("Resource ID:", text: $volcResourceId)
                HStack(spacing: 8) {
                    Text("识别模式:")
                        .frame(width: labelWidth, alignment: .trailing)
                    Picker("", selection: $asrMode) {
                        ForEach(ASRMode.allCases, id: \.rawValue) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                formRow("热词表 ID:", text: $boostingTableId)
            }

            // 凭证来源与热词说明
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Text("凭证从")
                    Link("火山引擎语音控制台",
                         destination: URL(string: "https://console.volcengine.com/speech/app")!)
                    Text("获取。")
                }
                Text("热词表需在火山引擎控制台的「热词管理」中创建，本应用目前仅接收 ID，暂不提供 App 内创建/编辑。")
                    .foregroundColor(.secondary)
            }
            .font(.caption)

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
        let boostingId = boostingTableId.trimmingCharacters(in: .whitespacesAndNewlines)

        if appId.isEmpty || token.isEmpty || resourceId.isEmpty {
            validationError = "App ID、Access Token、Resource ID 不能为空"
            return
        }

        validationError = nil

        Config.volcAppId = appId
        Config.volcAccessToken = token
        Config.volcResourceId = resourceId
        Config.asrMode = asrMode
        Config.boostingTableId = boostingId

        Log.log("[Settings] 火山引擎配置已保存 (mode=\(asrMode.rawValue))")
        onClose?()
    }
}
