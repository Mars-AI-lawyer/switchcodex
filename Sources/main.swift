import AppKit
import UserNotifications
import ServiceManagement

// MARK: - 路径常量（~/.codex 是 Codex CLI 与 ChatGPT 桌面端共用的配置目录）

let fm = FileManager.default
let codexDir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
let configPath = codexDir.appendingPathComponent("config.toml")
let modelsJsonPath = codexDir.appendingPathComponent("models.json")
let storageDir = codexDir.appendingPathComponent("switchcodex")
let gptSnapshotPath = storageDir.appendingPathComponent("gpt-config.toml")
let deepseekSnapshotPath = storageDir.appendingPathComponent("deepseek-config.toml")
let settingsPath = storageDir.appendingPathComponent("settings.json")

let providerID = "deepseek"
let deepseekBaseURL = "https://api.deepseek.com/"
let flashModelID = "deepseek-v4-flash"
let proModelID = "deepseek-v4-pro"
let defaultDeepSeekModel = flashModelID

// MARK: - 设置（保存在 ~/.codex/switchcodex/settings.json，权限 600）

struct Settings: Codable {
    var apiKey: String = ""
    var deepseekModel: String = defaultDeepSeekModel
}

func loadSettings() -> Settings {
    if let data = try? Data(contentsOf: settingsPath),
       let s = try? JSONDecoder().decode(Settings.self, from: data) {
        return s
    }
    return Settings()
}

func saveSettings(_ s: Settings) throws {
    try fm.createDirectory(at: storageDir, withIntermediateDirectories: true)
    let data = try JSONEncoder().encode(s)
    try data.write(to: settingsPath, options: .atomic)
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsPath.path)
}

// MARK: - 错误

enum AppError: Error, CustomStringConvertible {
    case missingConfig
    case missingSnapshot
    case invalidGPTSnapshot
    case invalidApiKey

    var description: String {
        switch self {
        case .missingConfig:
            return "未找到 ~/.codex/config.toml，请先运行一次 Codex / ChatGPT 桌面端。"
        case .missingSnapshot:
            return "缺少 GPT 配置快照，无法安全恢复。请先在 Codex 中恢复 GPT 配置，再重新选择 DeepSeek。"
        case .invalidGPTSnapshot:
            return "现有 GPT 配置快照实际是 DeepSeek 配置，已拒绝恢复。请先在 Codex 中恢复 GPT 配置，再重新选择 DeepSeek。"
        case .invalidApiKey:
            return "DeepSeek API Key 无效（必须以 sk- 开头）。请点击菜单「修改 DeepSeek API Key」重新输入。"
        }
    }
}

// MARK: - 文件读写

func readConfigString() -> String? {
    try? String(contentsOf: configPath, encoding: .utf8)
}

func writeAtomic(_ content: String, to url: URL) throws {
    try content.data(using: .utf8)!.write(to: url, options: .atomic)
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

/// 收紧历史版本已经生成的敏感配置文件权限。
func secureSensitiveFiles() throws {
    for url in [configPath, settingsPath, gptSnapshotPath, deepseekSnapshotPath] {
        if fm.fileExists(atPath: url.path) {
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}

/// 确保 ~/.codex/models.json 存在（复制应用内置的官方模型目录）
func ensureModelsJson() throws {
    if fm.fileExists(atPath: modelsJsonPath.path) { return }
    var candidates: [URL] = []
    if let r = Bundle.main.resourceURL { candidates.append(r) }
    candidates.append(Bundle.main.bundleURL)
    let exeDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    candidates.append(exeDir)
    for dir in candidates {
        let src = dir.appendingPathComponent("models.json")
        if fm.fileExists(atPath: src.path) {
            try fm.copyItem(at: src, to: modelsJsonPath)
            return
        }
    }
}

// MARK: - 模式检测（以 config.toml 实际内容为准，比 settings 更可靠）

func sectionName(_ trimmed: String) -> String {
    var s = trimmed
    if s.hasPrefix("[[") { s = String(s.dropFirst(2)) } else { s = String(s.dropFirst()) }
    while s.last == "]" { s = String(s.dropLast()) }
    s = s.replacingOccurrences(of: "\"", with: "")
        .replacingOccurrences(of: "'", with: "")
    return s.trimmingCharacters(in: .whitespaces)
}

/// 去掉字符串值两端的引号
func unquote(_ s: String) -> String {
    var v = s.trimmingCharacters(in: .whitespaces)
    for q in ["\"", "'"] {
        if v.hasPrefix(q), v.hasSuffix(q), v.count >= 2 {
            v = String(v.dropFirst().dropLast())
        }
    }
    return v
}

/// 检测当前模式：gpt / flash / pro（以 config.toml 实际内容为准）
func detectState(_ content: String) -> (mode: String, dsModel: String?) {
    var modelValue: String?
    var providerValue: String?
    var seenSection = false
    for line in content.components(separatedBy: .newlines) {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("["), t.hasSuffix("]") {
            seenSection = true
            continue
        }
        if !seenSection, let key = keyOf(line), let value = valueOf(line) {
            if key == "model", modelValue == nil {
                modelValue = unquote(value)
            } else if key == "model_provider", providerValue == nil {
                providerValue = unquote(value)
            }
        }
    }
    guard providerValue == providerID else { return ("gpt", nil) }
    let m = modelValue ?? defaultDeepSeekModel
    return (m == proModelID ? "pro" : "flash", m)
}

func detectMode(_ content: String) -> String {
    detectState(content).mode
}

func currentMode() -> String {
    guard let content = readConfigString() else { return "gpt" }
    return detectMode(content)
}

/// 只接受实际处于 GPT 模式的恢复快照，避免把 DeepSeek 配置误当成 GPT。
func readValidGPTSnapshot() throws -> String {
    guard let snapshot = try? String(contentsOf: gptSnapshotPath, encoding: .utf8) else {
        throw AppError.missingSnapshot
    }
    guard detectMode(snapshot) == "gpt" else {
        throw AppError.invalidGPTSnapshot
    }
    return snapshot
}

/// 初始化存储。只有当前配置确认为 GPT 时才创建或修复 GPT 快照。
func prepareStorage() throws {
    try fm.createDirectory(at: storageDir, withIntermediateDirectories: true)
    try ensureModelsJson()
    try secureSensitiveFiles()

    guard let current = readConfigString() else { return }
    let currentIsGPT = detectMode(current) == "gpt"
    let existingSnapshot = try? String(contentsOf: gptSnapshotPath, encoding: .utf8)
    let snapshotIsValid = existingSnapshot.map { detectMode($0) == "gpt" } ?? false

    if currentIsGPT, !snapshotIsValid {
        try writeAtomic(current, to: gptSnapshotPath)
    } else if !currentIsGPT, !fm.fileExists(atPath: deepseekSnapshotPath.path) {
        // 保留首次看到的 DeepSeek 配置，但绝不冒充 GPT 恢复点。
        try writeAtomic(current, to: deepseekSnapshotPath)
    }

    try secureSensitiveFiles()
}

// MARK: - TOML 行级编辑（与 DeepSeek 官方一键脚本的处理规则对齐）

let targetKeys = ["model", "model_provider", "preferred_auth_method",
                  "forced_login_method", "model_reasoning_effort", "model_catalog_json"]

let deleteKeysA = ["profile", "oss_provider", "openai_base_url"]

let deleteKeysB = ["model_context_window", "model_auto_compact_token_limit",
                   "model_auto_compact_token_limit_scope", "base_instructions",
                   "model_instructions_file", "compact_prompt",
                   "experimental_compact_prompt_file", "service_tier",
                   "model_verbosity", "model_reasoning_summary",
                   "plan_mode_reasoning_effort", "experimental_use_unified_exec_tool"]

func targetValue(for key: String, model: String) -> String {
    switch key {
    case "model": return "\"\(model)\""
    case "model_provider": return "\"\(providerID)\""
    case "preferred_auth_method": return "\"apikey\""
    case "forced_login_method": return "\"api\""
    case "model_reasoning_effort": return "\"high\""
    case "model_catalog_json": return "\"~/.codex/models.json\""
    default: return ""
    }
}

func keyOf(_ line: String) -> String? {
    let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.isEmpty || t.hasPrefix("#") || t.hasPrefix("[") { return nil }
    guard let eq = t.firstIndex(of: "=") else { return nil }
    var k = String(t[..<eq]).trimmingCharacters(in: .whitespaces)
    k = k.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "")
    return k.isEmpty ? nil : k
}

func valueOf(_ line: String) -> String? {
    let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let eq = t.firstIndex(of: "=") else { return nil }
    return String(t[t.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
}

/// 简化版 TOML 行扫描：维护括号深度与多行字符串状态，
/// 用于正确吞掉跨多行的数组 / 多行字符串赋值。
func scanLine(_ line: String, _ depth: inout Int, _ inMLS: inout String) {
    if !inMLS.isEmpty {
        if line.range(of: inMLS) != nil { inMLS = "" }
        return
    }
    let chars = Array(line)
    var idx = 0
    var inStr = false
    var quote: Character = "\""
    while idx < chars.count {
        let c = chars[idx]
        if inStr {
            if c == quote { inStr = false }
            idx += 1
            continue
        }
        switch c {
        case "\"":
            if idx + 2 < chars.count, chars[idx + 1] == "\"", chars[idx + 2] == "\"" {
                if line.components(separatedBy: "\"\"\"").count > 2 {
                    inStr = true; quote = "\""  // 三引号同行闭合，当作普通字符串
                } else {
                    inMLS = "\"\"\""
                    return
                }
            } else {
                inStr = true; quote = "\""
            }
        case "'":
            if idx + 2 < chars.count, chars[idx + 1] == "'", chars[idx + 2] == "'" {
                inMLS = "'''"
                return
            } else {
                inStr = true; quote = "'"
            }
        case "[": depth += 1
        case "]": depth -= 1
        default: break
        }
        idx += 1
    }
}

/// 吞掉从 lines[idx] 开始的整条赋值（含多行值），idx 前进到赋值之后
func consumeAssignment(_ lines: [String], _ idx: inout Int, _ depth: inout Int, _ ml: inout String) {
    if idx < lines.count {
        scanLine(lines[idx], &depth, &ml)
        idx += 1
    }
    while (ml != "" || depth != 0), idx < lines.count {
        scanLine(lines[idx], &depth, &ml)
        idx += 1
    }
}

/// 由 GPT 配置生成 DeepSeek 配置（不修改原内容，返回新文本）
func buildDeepseekConfig(from source: String, apiKey: String, model: String) -> String {
    var out: [String] = []
    var depth = 0
    var ml = ""
    var curSection = ""
    var skipSection = false
    var seen = Set<String>()

    let lines = source.components(separatedBy: .newlines)
    var idx = 0
    while idx < lines.count {
        let line = lines[idx]
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let isHeader = ml.isEmpty && depth == 0 && t.hasPrefix("[")

        if isHeader {
            let name = sectionName(t)
            curSection = name
            skipSection = (name == "model_providers.\(providerID)"
                || name.hasPrefix("model_providers.\(providerID).")
                || name == "profiles" || name.hasPrefix("profiles."))
            scanLine(line, &depth, &ml)
            idx += 1
            if !skipSection { out.append(line) }
            continue
        }

        if skipSection {
            scanLine(line, &depth, &ml)
            idx += 1
            continue
        }

        if !curSection.isEmpty {
            // 段内：wire_api = "chat" 会导致 Codex 无法启动，修正为 responses
            if keyOf(line) == "wire_api", let v = valueOf(line), v == "\"chat\"" || v == "'chat'" {
                let indent = String(line.prefix { $0 == " " || $0 == "\t" })
                out.append(indent + "wire_api = \"responses\"")
            } else {
                out.append(line)
            }
            scanLine(line, &depth, &ml)
            idx += 1
            continue
        }

        // 顶层（首段之前的 leading area）
        if let k = keyOf(line) {
            if targetKeys.contains(k) {
                consumeAssignment(lines, &idx, &depth, &ml)
                out.append("\(k) = \(targetValue(for: k, model: model))")
                seen.insert(k)
                continue
            }
            if deleteKeysA.contains(k) || deleteKeysB.contains(k) {
                consumeAssignment(lines, &idx, &depth, &ml)
                continue
            }
        }
        out.append(line)
        scanLine(line, &depth, &ml)
        idx += 1
    }

    // 补齐缺失的目标键，插到第一个段头之前
    let missing = targetKeys.filter { !seen.contains($0) }
    if !missing.isEmpty {
        var insertAt = out.count
        for (i, l) in out.enumerated() {
            if l.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[") {
                insertAt = i
                break
            }
        }
        var insertLines = missing.map { "\($0) = \(targetValue(for: $0, model: model))" }
        if insertAt < out.count,
           out[insertAt].trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[") {
            insertLines.append("")
        }
        out.insert(contentsOf: insertLines, at: insertAt)
    }

    // 末尾追加 DeepSeek provider 段
    while let last = out.last, last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        out.removeLast()
    }
    out.append("")
    out.append("[model_providers.\(providerID)]")
    out.append("name = \"\(providerID)\"")
    out.append("base_url = \"\(deepseekBaseURL)\"")
    out.append("wire_api = \"responses\"")
    out.append("experimental_bearer_token = \"\(apiKey)\"")
    out.append("")
    return out.joined(separator: "\n")
}

// MARK: - 切换核心逻辑

/// 显式切换到指定模式：gpt / flash / pro
@discardableResult
func applyMode(_ mode: String) throws -> String {
    try fm.createDirectory(at: storageDir, withIntermediateDirectories: true)
    let cur = currentMode()

    if mode == "gpt" {
        if cur == "gpt" { return "gpt" }
        // DeepSeek → GPT：完整恢复 GPT 快照
        let snap = try readValidGPTSnapshot()
        try writeAtomic(snap, to: configPath)
        return "gpt"
    }

    let model = (mode == "pro") ? proModelID : flashModelID
    if cur == "gpt" {
        // GPT → DeepSeek：先刷新 GPT 快照（保留用户近期改动），再生成并写入 DeepSeek 配置
        guard let gpt = readConfigString() else { throw AppError.missingConfig }
        try writeAtomic(gpt, to: gptSnapshotPath)
        let s = loadSettings()
        guard s.apiKey.hasPrefix("sk-") else { throw AppError.invalidApiKey }
        let ds = buildDeepseekConfig(from: gpt, apiKey: s.apiKey, model: model)
        try writeAtomic(ds, to: configPath)
        try writeAtomic(ds, to: deepseekSnapshotPath)
    } else {
        // 已在 DeepSeek 模式（Flash ⇄ Pro）：仅改顶层 model 行，其余保持不变
        guard let ds = readConfigString() else { throw AppError.missingConfig }
        let updated = updateModelLine(in: ds, to: model)
        try writeAtomic(updated, to: configPath)
        try writeAtomic(updated, to: deepseekSnapshotPath)
    }

    var s = loadSettings()
    s.deepseekModel = model
    try saveSettings(s)
    return (model == proModelID) ? "pro" : "flash"
}

/// 仅替换顶层（首个段头之前）的 model = "..." 行
func updateModelLine(in content: String, to model: String) -> String {
    let lines = content.components(separatedBy: .newlines)
    var out: [String] = []
    var replaced = false
    for line in lines {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if !replaced, t.hasPrefix("[") {
            out.append(line)
            continue
        }
        if !replaced, keyOf(line) == "model" {
            out.append("model = \"\(model)\"")
            replaced = true
            continue
        }
        out.append(line)
    }
    return out.joined(separator: "\n")
}

/// 左键一键切换：GPT ⇄ DeepSeek（DeepSeek 侧使用上次选定的模型）
@discardableResult
func performToggle() throws -> String {
    let cur = currentMode()
    if cur == "gpt" {
        let s = loadSettings()
        return try applyMode(s.deepseekModel == proModelID ? "pro" : "flash")
    }
    return try applyMode("gpt")
}

// MARK: - 无界面命令行模式（用于自动化测试）

func runHeadless(_ args: [String]) -> Int32 {
    if args.contains("--state") {
        print(currentMode())
        return 0
    }

    func prepare() throws {
        try prepareStorage()
    }

    if args.contains("--set") {
        guard let i = args.firstIndex(of: "--set"), i + 1 < args.count else {
            print("ERROR: --set 需要参数 gpt / flash / pro")
            return 1
        }
        let target = args[i + 1]
        guard ["gpt", "flash", "pro"].contains(target) else {
            print("ERROR: --set 仅支持 gpt / flash / pro")
            return 1
        }
        do {
            try prepare()
            let newMode = try applyMode(target)
            print("switched to \(newMode)")
            return 0
        } catch {
            print("ERROR: \(error)")
            return 1
        }
    }

    if args.contains("--toggle") {
        do {
            try prepare()
            if let i = args.firstIndex(of: "--key"), i + 1 < args.count {
                var s = loadSettings()
                s.apiKey = args[i + 1]
                try saveSettings(s)
            }
            if let i = args.firstIndex(of: "--model"), i + 1 < args.count {
                let m = args[i + 1]
                guard m == flashModelID || m == proModelID else {
                    print("ERROR: --model 仅支持 \(flashModelID) / \(proModelID)")
                    return 1
                }
                var s = loadSettings()
                s.deepseekModel = m
                try saveSettings(s)
            }
            let newMode = try performToggle()
            print("switched to \(newMode)")
            return 0
        } catch {
            print("ERROR: \(error)")
            return 1
        }
    }
    return 0
}

// MARK: - GUI：菜单栏应用

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let statusMenu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try prepareStorage()
        } catch {
            showAlert(error: error)
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let icon = NSImage(
                systemSymbolName: "arrow.triangle.2.circlepath",
                accessibilityDescription: "切换模型"
            )?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            ) {
                icon.isTemplate = true
                button.image = icon
                button.imagePosition = .imageLeading
            }
        }
        statusMenu.delegate = self
        statusItem.menu = statusMenu

        // LSUIElement 应用没有菜单栏，需手动注册主菜单，
        // 否则输入框的 Command+V / Command+C / Command+A 等快捷键无法使用
        setupMainMenu()

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        refreshUI()

        if loadSettings().apiKey.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.promptForApiKey(completion: nil)
            }
        }
    }

    // MARK: 主菜单（提供编辑快捷键派发）

    func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 SwitchCodex",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 SwitchCodex",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    func refreshUI() {
        guard let button = statusItem?.button else { return }
        let mode = currentMode()
        let title: String
        let color: NSColor
        let tooltip: String
        switch mode {
        case "pro":
            title = "DS·P"
            color = .systemPurple
            tooltip = "Codex 当前：DeepSeek V4 Pro。点击选择模型"
        case "flash":
            title = "DS·F"
            color = .systemBlue
            tooltip = "Codex 当前：DeepSeek V4 Flash。点击选择模型"
        default:
            title = "GPT"
            color = .systemGreen
            tooltip = "Codex 当前：GPT。点击选择模型"
        }
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: color,
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
        ])
        button.toolTip = tooltip
    }

    // MARK: 菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let mode = currentMode()

        let infoItem = NSMenuItem(
            title: "当前模型：\(displayName(for: mode))",
            action: nil, keyEquivalent: "")
        infoItem.isEnabled = false
        menu.addItem(infoItem)
        menu.addItem(.separator())

        // 三档切换：GPT / DeepSeek V4 Flash / DeepSeek V4 Pro
        let gptItem = NSMenuItem(title: "GPT", action: #selector(switchFromMenu(_:)), keyEquivalent: "")
        gptItem.target = self
        gptItem.tag = 0
        gptItem.state = mode == "gpt" ? .on : .off
        menu.addItem(gptItem)

        let flashItem = NSMenuItem(title: "DeepSeek V4 Flash", action: #selector(switchFromMenu(_:)), keyEquivalent: "")
        flashItem.target = self
        flashItem.tag = 1
        flashItem.state = mode == "flash" ? .on : .off
        menu.addItem(flashItem)

        let proItem = NSMenuItem(title: "DeepSeek V4 Pro", action: #selector(switchFromMenu(_:)), keyEquivalent: "")
        proItem.target = self
        proItem.tag = 2
        proItem.state = mode == "pro" ? .on : .off
        menu.addItem(proItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "修改 DeepSeek API Key…",
                     action: #selector(changeApiKey(_:)), keyEquivalent: "k")
            .target = self
        menu.addItem(withTitle: "打开 ~/.codex 配置目录",
                     action: #selector(openConfigDir(_:)), keyEquivalent: "")
            .target = self

        let loginItem = NSMenuItem(
            title: "开机自启",
            action: #selector(toggleLoginItem(_:)), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = loginItemEnabled() ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 SwitchCodex",
                     action: #selector(quitApp(_:)), keyEquivalent: "q")
            .target = self
    }

    @objc func switchFromMenu(_ sender: NSMenuItem) {
        let targets = ["gpt", "flash", "pro"]
        guard sender.tag >= 0, sender.tag < targets.count else { return }
        applyModelMode(targets[sender.tag])
    }

    @objc func changeApiKey(_ sender: Any?) {
        promptForApiKey(completion: nil)
    }

    @objc func openConfigDir(_ sender: Any?) {
        NSWorkspace.shared.open(codexDir)
    }

    @objc func quitApp(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    @objc func toggleLoginItem(_ sender: Any?) {
        setLoginItem(!loginItemEnabled())
    }

    // MARK: 切换动作

    func applyModelMode(_ target: String) {
        if target != "gpt", loadSettings().apiKey.isEmpty {
            promptForApiKey { [weak self] ok in
                if ok { self?.doApply(target) }
            }
        } else {
            doApply(target)
        }
    }

    func doApply(_ target: String) {
        do {
            let newMode = try applyMode(target)
            refreshUI()
            let name = displayName(for: newMode)
            let body = newMode == "gpt"
                ? "原 GPT 配置已完整恢复"
                : "模型：\(loadSettings().deepseekModel)。切换后请重启 ChatGPT 客户端生效"
            sendNotification(title: "已切换为 \(name)", body: body)
        } catch {
            showAlert(error: error)
        }
    }

    func displayName(for mode: String) -> String {
        switch mode {
        case "pro": return "DeepSeek V4 Pro"
        case "flash": return "DeepSeek V4 Flash"
        default: return "GPT"
        }
    }

    // MARK: API Key 输入框

    func promptForApiKey(completion: ((Bool) -> Void)?) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            var current = loadSettings().apiKey
            while true {
                let alert = NSAlert()
                alert.messageText = "设置 DeepSeek API Key"
                alert.informativeText = "在 https://platform.deepseek.com/api_keys 创建（sk- 开头）。\nKey 仅保存在本机 ~/.codex/switchcodex/settings.json。\n可直接在输入框内按 Command+V 粘贴，或点击「粘贴」按钮。"
                let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
                field.placeholderString = "sk-..."
                field.stringValue = current
                alert.accessoryView = field
                alert.addButton(withTitle: "保存")
                alert.addButton(withTitle: "粘贴")
                alert.addButton(withTitle: "取消")
                alert.window.initialFirstResponder = field
                let response = alert.runModal()
                switch response {
                case .alertFirstButtonReturn:
                    let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    if key.hasPrefix("sk-") {
                        var s = loadSettings()
                        s.apiKey = key
                        do {
                            try saveSettings(s)
                            completion?(true)
                        } catch {
                            self.showAlert(error: error)
                            completion?(false)
                        }
                        return
                    }
                    current = key
                    self.showAlert(message: "API Key 必须以 sk- 开头，未保存。")
                case .alertSecondButtonReturn:
                    if let text = NSPasteboard.general.string(forType: .string) {
                        current = text
                    }
                default:
                    completion?(false)
                    return
                }
            }
        }
    }

    // MARK: 通知

    func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: 开机自启（SMAppService，macOS 13+）

    func loginItemEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    func setLoginItem(_ enable: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enable {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                showAlert(message: "开机自启设置失败：\(error.localizedDescription)\n（应用需位于 /Applications 目录）")
            }
        } else {
            showAlert(message: "系统版本过低，不支持开机自启。")
        }
    }

    // MARK: 弹窗

    func showAlert(error: Error) {
        showAlert(message: error.localizedDescription)
    }

    func showAlert(message: String) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "SwitchCodex"
            alert.informativeText = message
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
    }
}

// MARK: - 入口

let args = CommandLine.arguments
if args.contains("--toggle") || args.contains("--set") || args.contains("--state") {
    exit(runHeadless(args))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
