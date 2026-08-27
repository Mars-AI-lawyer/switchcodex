import AppKit
import UserNotifications
import ServiceManagement

// MARK: - 路径常量（~/.codex 是 Codex CLI 与 ChatGPT 桌面端共用的配置目录）

let fm = FileManager.default

/// 默认使用真实用户目录；设置环境变量 SWITCHCODEX_HOME 后改用该目录下的 .codex，便于隔离测试
let codexDir: URL = {
    if let root = ProcessInfo.processInfo.environment["SWITCHCODEX_HOME"] {
        return URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(".codex")
    }
    return fm.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
}()
let configPath = codexDir.appendingPathComponent("config.toml")
let modelsJsonPath = codexDir.appendingPathComponent("models.json")
let storageDir = codexDir.appendingPathComponent("switchcodex")
let gptSnapshotPath = storageDir.appendingPathComponent("gpt-config.toml")
let deepseekSnapshotPath = storageDir.appendingPathComponent("deepseek-config.toml")
let bigmodelSnapshotPath = storageDir.appendingPathComponent("bigmodel-config.toml")
let settingsPath = storageDir.appendingPathComponent("settings.json")

// MARK: - 提供商与模型定义

struct ProviderSpec {
    let id: String        // 写入 config.toml 的 provider 标识
    let baseURL: String   // Responses 协议端点
}

let deepseekProviderID = "deepseek"
let bigmodelProviderID = "bigmodel"

// DeepSeek 官方 Responses API 端点
let deepseekSpec = ProviderSpec(id: deepseekProviderID, baseURL: "https://api.deepseek.com/")
// 智谱 BigModel 官方 Codex 专属 OpenAI Response 协议端点（docs.bigmodel.cn/cn/coding-plan/tool/codex）
let bigmodelSpec = ProviderSpec(id: bigmodelProviderID, baseURL: "https://open.bigmodel.cn/api/v1")

let providerSpecs: [String: ProviderSpec] = [
    deepseekProviderID: deepseekSpec,
    bigmodelProviderID: bigmodelSpec,
]

let flashModelID = "deepseek-v4-flash"
let proModelID = "deepseek-v4-pro"
let visionModelID = "deepseek-v4-flash-vision-exp"
let glmFlashModelID = "glm-5.3-flash"
let glmFullModelID = "glm-5.3"

/// 思考程度可选项（与两家模型的 reasoning 档位对齐）
let reasoningEfforts = ["low", "high", "max"]
let defaultReasoningEffort = "high"

/// 一个可切换目标：提供商 + 模型 + 展示信息。
/// token 是内部短代号，也是命令行 --set 的别名之一。
struct ModelTarget {
    let token: String
    let providerID: String
    let modelID: String
    let title: String       // 菜单里的完整名称
    let statusTitle: String // 菜单栏缩写
    let color: NSColor
    let aliases: [String]
}

let targetTable: [ModelTarget] = [
    ModelTarget(token: "flash", providerID: deepseekProviderID, modelID: flashModelID,
                title: "DeepSeek V4 Flash", statusTitle: "DS·F", color: .systemBlue,
                aliases: ["dsf", "dsflash"]),
    ModelTarget(token: "pro", providerID: deepseekProviderID, modelID: proModelID,
                title: "DeepSeek V4 Pro", statusTitle: "DS·P", color: .systemPurple,
                aliases: ["dsp", "dspro"]),
    ModelTarget(token: "vision", providerID: deepseekProviderID, modelID: visionModelID,
                title: "DeepSeek V4 Flash Vision（实验）", statusTitle: "DS·V", color: .systemTeal,
                aliases: ["dsv", "dsvision", "vexp"]),
    ModelTarget(token: "glmflash", providerID: bigmodelProviderID, modelID: glmFlashModelID,
                title: "GLM-5.3-Flash（智谱）", statusTitle: "GLM·F", color: .systemIndigo,
                aliases: ["glmf", "glm-flash", "zflash"]),
    ModelTarget(token: "glm", providerID: bigmodelProviderID, modelID: glmFullModelID,
                title: "GLM-5.3（智谱）", statusTitle: "GLM·5", color: .systemPink,
                aliases: ["glmfull", "glm5", "glm53", "zglm"]),
]

func targetByToken(_ token: String) -> ModelTarget? {
    targetTable.first { $0.token == token }
}

/// 支持短别名或完整模型 slug；"gpt" 单独处理
func resolveTargetAlias(_ raw: String) -> ModelTarget? {
    if raw == "gpt" { return nil }
    for t in targetTable where t.token == raw || t.modelID == raw || t.aliases.contains(raw) {
        return t
    }
    return nil
}

func isValidKey(_ providerID: String, _ key: String) -> Bool {
    if providerID == deepseekProviderID { return key.hasPrefix("sk-") }
    // 智谱 Key 形如 id.secret，无固定前缀，做长度兜底校验
    return key.count >= 20
}

// MARK: - 设置（保存在 ~/.codex/switchcodex/settings.json，权限 600）

struct Settings: Codable {
    var deepseekApiKey = ""
    var bigmodelApiKey = ""
    var deepseekModel = flashModelID
    var bigmodelModel = glmFlashModelID
    var reasoningEffort = defaultReasoningEffort
    var lastToken = "" // 左键/无参数 toggle 时回到的目标

    private enum CodingKeys: String, CodingKey {
        case deepseekApiKey, bigmodelApiKey, deepseekModel, bigmodelModel
        case reasoningEffort, lastTarget
        case apiKey // 旧版本字段：DeepSeek API Key
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deepseekApiKey = try c.decodeIfPresent(String.self, forKey: .deepseekApiKey)
            ?? c.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        bigmodelApiKey = try c.decodeIfPresent(String.self, forKey: .bigmodelApiKey) ?? ""
        deepseekModel = try c.decodeIfPresent(String.self, forKey: .deepseekModel) ?? flashModelID
        bigmodelModel = try c.decodeIfPresent(String.self, forKey: .bigmodelModel) ?? glmFlashModelID
        reasoningEffort = try c.decodeIfPresent(String.self, forKey: .reasoningEffort)
            ?? defaultReasoningEffort
        lastToken = try c.decodeIfPresent(String.self, forKey: .lastTarget) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(deepseekApiKey, forKey: .deepseekApiKey)
        try c.encode(bigmodelApiKey, forKey: .bigmodelApiKey)
        try c.encode(deepseekModel, forKey: .deepseekModel)
        try c.encode(bigmodelModel, forKey: .bigmodelModel)
        try c.encode(reasoningEffort, forKey: .reasoningEffort)
        try c.encode(lastToken, forKey: .lastTarget)
    }
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
    case invalidApiKey(providerID: String)

    var description: String {
        switch self {
        case .missingConfig:
            return "未找到 ~/.codex/config.toml，请先运行一次 Codex / ChatGPT 桌面端。"
        case .missingSnapshot:
            return "缺少 GPT 配置快照，无法安全恢复。请先在 Codex 中恢复 GPT 配置，再重新选择第三方模型。"
        case .invalidGPTSnapshot:
            return "现有 GPT 配置快照实际是第三方模型配置，已拒绝恢复。请先在 Codex 中恢复 GPT 配置，再重新选择第三方模型。"
        case .invalidApiKey(let providerID):
            if providerID == bigmodelProviderID {
                return "智谱 Bigmodel API Key 无效。请点击菜单「修改智谱 Bigmodel API Key」重新输入。"
            }
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
    for url in [configPath, settingsPath, gptSnapshotPath, deepseekSnapshotPath, bigmodelSnapshotPath] {
        if fm.fileExists(atPath: url.path) {
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}

func snapshotPath(for providerID: String) -> URL {
    providerID == bigmodelProviderID ? bigmodelSnapshotPath : deepseekSnapshotPath
}

func bundledModelsJSONURL() -> URL? {
    var candidates: [URL] = []
    if let r = Bundle.main.resourceURL { candidates.append(r) }
    candidates.append(Bundle.main.bundleURL)
    let exeDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    candidates.append(exeDir)
    for dir in candidates {
        let src = dir.appendingPathComponent("models.json")
        if fm.fileExists(atPath: src.path) { return src }
    }
    return nil
}

private func catalogSlugs(_ url: URL?) -> Set<String>? {
    guard let url = url, let data = try? Data(contentsOf: url),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let models = obj["models"] as? [[String: Any]] else { return nil }
    return Set(models.compactMap { $0["slug"] as? String })
}

/// 确保 ~/.codex/models.json 存在，并在内置目录新增了模型时升级旧副本
/// （否则老版本留下的目录缺少 vision/GLM 模型条目）。
func ensureModelsJson() throws {
    guard let bundled = bundledModelsJSONURL(),
          let bundledSlugs = catalogSlugs(bundled) else { return }

    let needFreshCopy = !fm.fileExists(atPath: modelsJsonPath.path)
    if !needFreshCopy,
       let installedSlugs = catalogSlugs(modelsJsonPath),
       installedSlugs.isSuperset(of: bundledSlugs) {
        return // 已是最新
    }

    if fm.fileExists(atPath: modelsJsonPath.path) {
        try fm.removeItem(at: modelsJsonPath)
    }
    try fm.copyItem(at: bundled, to: modelsJsonPath)
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

struct ModeInfo {
    let providerID: String // "gpt" / deepseek / bigmodel
    let model: String
}

/// 解析当前生效的提供商和模型；无法识别为已知第三方时一律视为 GPT 原生配置。
func detectState(_ content: String) -> ModeInfo {
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
    guard let pv = providerValue, let spec = providerSpecs[pv] else {
        return ModeInfo(providerID: "gpt", model: "")
    }
    // 只要有已知的 model_provider 就按该提供商处理，
    // 避免自定义模型名的第三方配置被当成 GPT 而污染快照
    let m = modelValue ?? defaultModelID(for: spec.id)
    return ModeInfo(providerID: spec.id, model: m)
}

func detectMode(_ content: String) -> String {
    detectState(content).providerID
}

func currentMode() -> String {
    guard let content = readConfigString() else { return "gpt" }
    return detectMode(content)
}

func currentInfo() -> ModeInfo {
    guard let content = readConfigString() else {
        return ModeInfo(providerID: "gpt", model: "")
    }
    return detectState(content)
}

func defaultModelID(for providerID: String) -> String {
    providerID == bigmodelProviderID ? glmFlashModelID : flashModelID
}

/// 当前模式对应的切换目标 token（用于菜单栏标题、--state 输出）
func currentToken() -> String {
    let info = currentInfo()
    if info.providerID == "gpt" { return "gpt" }
    if let row = targetTable.first(where: { $0.providerID == info.providerID && $0.modelID == info.model }) {
        return row.token
    }
    return info.providerID == bigmodelProviderID ? "glm" : "flash"
}

/// 只接受实际处于 GPT 模式的恢复快照，避免把第三方配置误当成 GPT。
func readValidGPTSnapshot() throws -> String {
    guard let snapshot = try? String(contentsOf: gptSnapshotPath, encoding: .utf8) else {
        throw AppError.missingSnapshot
    }
    guard detectMode(snapshot) == "gpt" else {
        throw AppError.invalidGPTSnapshot
    }
    return snapshot
}

/// 初始化存储。只有当前配置确认为 GPT 时才创建或修复 GPT 快照；
/// 首次看到的 DeepSeek / Bigmodel 配置也各自留存一份快照备查。
func prepareStorage() throws {
    try fm.createDirectory(at: storageDir, withIntermediateDirectories: true)
    try ensureModelsJson()
    try secureSensitiveFiles()

    guard let current = readConfigString() else { return }
    let curProvider = detectMode(current)
    let existingSnapshot = try? String(contentsOf: gptSnapshotPath, encoding: .utf8)
    let snapshotIsValid = existingSnapshot.map { detectMode($0) == "gpt" } ?? false

    if curProvider == "gpt" {
        if !snapshotIsValid {
            try writeAtomic(current, to: gptSnapshotPath)
        }
    } else {
        let snap = snapshotPath(for: curProvider)
        if !fm.fileExists(atPath: snap.path) {
            try writeAtomic(current, to: snap)
        }
    }

    try secureSensitiveFiles()
}

// MARK: - TOML 行级编辑（与 DeepSeek / Bigmodel 官方一键脚本的处理规则对齐）

let targetKeys = ["model", "model_provider", "preferred_auth_method",
                  "forced_login_method", "model_reasoning_effort", "model_catalog_json"]

let deleteKeysA = ["profile", "oss_provider", "openai_base_url"]

let deleteKeysB = ["model_context_window", "model_auto_compact_token_limit",
                   "model_auto_compact_token_limit_scope", "base_instructions",
                   "model_instructions_file", "compact_prompt",
                   "experimental_compact_prompt_file", "service_tier",
                   "model_verbosity", "model_reasoning_summary",
                   "plan_mode_reasoning_effort", "experimental_use_unified_exec_tool"]

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

/// 由 GPT 配置生成指定提供商的配置（不修改原内容，返回新文本）
func buildNonGPTConfig(from source: String, spec: ProviderSpec,
                       apiKey: String, model: String, effort: String) -> String {
    func topLevelValue(_ key: String) -> String {
        switch key {
        case "model": return "\"\(model)\""
        case "model_provider": return "\"\(spec.id)\""
        case "preferred_auth_method": return "\"apikey\""
        case "forced_login_method": return "\"api\""
        case "model_reasoning_effort": return "\"\(effort)\""
        case "model_catalog_json": return "\"~/.codex/models.json\""
        default: return ""
        }
    }

    // 本工具管理的两个 provider 段一律重建，避免残留另一家的旧段
    let managedSections = ["model_providers.\(deepseekProviderID)", "model_providers.\(bigmodelProviderID)"]
    func isManagedSection(_ name: String) -> Bool {
        managedSections.contains(name)
            || name.hasPrefix("model_providers.\(deepseekProviderID).")
            || name.hasPrefix("model_providers.\(bigmodelProviderID).")
    }

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
            skipSection = isManagedSection(name) || name == "profiles" || name.hasPrefix("profiles.")
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
                out.append("\(k) = \(topLevelValue(k))")
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
        var insertLines = missing.map { "\($0) = \(topLevelValue($0))" }
        if insertAt < out.count,
           out[insertAt].trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[") {
            insertLines.append("")
        }
        out.insert(contentsOf: insertLines, at: insertAt)
    }

    // 末尾追加目标 provider 段
    while let last = out.last, last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        out.removeLast()
    }
    out.append("")
    out.append("[model_providers.\(spec.id)]")
    out.append("name = \"\(spec.id)\"")
    out.append("base_url = \"\(spec.baseURL)\"")
    out.append("wire_api = \"responses\"")
    out.append("experimental_bearer_token = \"\(apiKey)\"")
    out.append("")
    return out.joined(separator: "\n")
}

// MARK: - 切换核心逻辑

/// 仅替换顶层（首个段头之前）的某个 `key = ...` 行
func updateTopLevelValue(in content: String, key: String, value: String) -> String {
    let lines = content.components(separatedBy: .newlines)
    var out: [String] = []
    var replaced = false
    for line in lines {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if !replaced, t.hasPrefix("[") {
            out.append(line)
            continue
        }
        if !replaced, keyOf(line) == key {
            out.append("\(key) = \(value)")
            replaced = true
            continue
        }
        out.append(line)
    }
    return out.joined(separator: "\n")
}

func updateModelLine(in content: String, to model: String) -> String {
    updateTopLevelValue(in: content, key: "model", value: "\"\(model)\"")
}

/// 显式切换到指定模式：gpt 或 targetTable 中的任一目标
@discardableResult
func applyTarget(_ target: ModelTarget?) throws -> String {
    try fm.createDirectory(at: storageDir, withIntermediateDirectories: true)

    // GPT：完整恢复 GPT 快照
    guard let row = target else {
        if currentMode() == "gpt" { return "gpt" }
        let snap = try readValidGPTSnapshot()
        try writeAtomic(snap, to: configPath)
        return "gpt"
    }

    let spec = providerSpecs[row.providerID]!
    var s = loadSettings()
    if !reasoningEfforts.contains(s.reasoningEffort) {
        s.reasoningEffort = defaultReasoningEffort
    }
    let apiKey = row.providerID == bigmodelProviderID ? s.bigmodelApiKey : s.deepseekApiKey
    guard isValidKey(row.providerID, apiKey) else {
        throw AppError.invalidApiKey(providerID: row.providerID)
    }

    let cur = currentInfo()
    if cur.providerID == row.providerID {
        // 同一提供商内切换（Flash ⇄ Pro ⇄ Vision 等）：仅改顶层 model 行，其余保持不变
        guard let content = readConfigString() else { throw AppError.missingConfig }
        let updated = updateModelLine(in: content, to: row.modelID)
        try writeAtomic(updated, to: configPath)
        try writeAtomic(updated, to: snapshotPath(for: row.providerID))
    } else {
        // 跨提供商：从干净的 GPT 快照重新生成，保证不携带上一家的残留配置
        let sourceContent: String
        if cur.providerID == "gpt" {
            guard let gpt = readConfigString() else { throw AppError.missingConfig }
            // 先刷新 GPT 快照（保留用户近期改动），再生成并写入目标配置
            try writeAtomic(gpt, to: gptSnapshotPath)
            sourceContent = gpt
        } else {
            sourceContent = try readValidGPTSnapshot()
        }
        let built = buildNonGPTConfig(from: sourceContent, spec: spec,
                                      apiKey: apiKey, model: row.modelID,
                                      effort: s.reasoningEffort)
        try writeAtomic(built, to: configPath)
        try writeAtomic(built, to: snapshotPath(for: row.providerID))
    }

    if row.providerID == bigmodelProviderID {
        s.bigmodelModel = row.modelID
    } else {
        s.deepseekModel = row.modelID
    }
    s.lastToken = row.token
    try saveSettings(s)
    return row.token
}

/// 左键一键切换：GPT ⇄ 上次使用的第三方模型
@discardableResult
func performToggle() throws -> String {
    if currentMode() != "gpt" {
        return try applyTarget(nil)
    }
    let s = loadSettings()
    let last = resolveTargetAlias(s.lastToken) ?? targetByToken("flash")!
    return try applyTarget(last)
}

/// 更新思考程度（model_reasoning_effort）；当前若处于第三方模式则同步改写配置。
/// 非法值一律回落到默认档位，入口处也应自行校验。
func setReasoningEffort(_ effort: String) throws {
    var s = loadSettings()
    s.reasoningEffort = reasoningEfforts.contains(effort) ? effort : defaultReasoningEffort
    try saveSettings(s)

    let info = currentInfo()
    guard info.providerID != "gpt",
          let content = readConfigString() else { return }
    let updated = updateTopLevelValue(in: content, key: "model_reasoning_effort",
                                      value: "\"\(effort)\"")
    try writeAtomic(updated, to: configPath)
    try writeAtomic(updated, to: snapshotPath(for: info.providerID))
}

// MARK: - 无界面命令行模式（用于自动化测试）

func runHeadless(_ args: [String]) -> Int32 {
    func valueAfter(_ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    func importKeysIfNeeded() throws {
        var s = loadSettings()
        var dirty = false
        if let k = valueAfter("--key"), !k.isEmpty {
            s.deepseekApiKey = k
            dirty = true
        }
        if let k = valueAfter("--bkey"), !k.isEmpty {
            s.bigmodelApiKey = k
            dirty = true
        }
        if let m = valueAfter("--model"), let row = resolveTargetAlias(m) {
            if row.providerID == bigmodelProviderID {
                s.bigmodelModel = row.modelID
            } else {
                s.deepseekModel = row.modelID
            }
            dirty = true
        }
        if dirty { try saveSettings(s) }
    }

    if args.contains("--state") {
        print(currentToken())
        return 0
    }

    if args.contains("--effort") {
        guard let e = valueAfter("--effort"), reasoningEfforts.contains(e) else {
            print("ERROR: --effort 仅支持 \(reasoningEfforts.joined(separator: " / "))")
            return 1
        }
        do {
            try prepareStorage()
            try setReasoningEffort(e)
            print("reasoning effort = \(e)")
            return 0
        } catch {
            print("ERROR: \(error)")
            return 1
        }
    }

    if args.contains("--set") {
        let raw = valueAfter("--set") ?? ""
        let row = resolveTargetAlias(raw)
        guard raw == "gpt" || row != nil else {
            print("ERROR: --set 仅支持 gpt / \(targetTable.map { $0.token }.joined(separator: " / "))")
            return 1
        }
        do {
            try prepareStorage()
            try importKeysIfNeeded()
            let newToken = try applyTarget(row)
            print("switched to \(newToken)")
            return 0
        } catch {
            print("ERROR: \(error)")
            return 1
        }
    }

    if args.contains("--toggle") {
        do {
            try prepareStorage()
            try importKeysIfNeeded()
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

        if loadSettings().deepseekApiKey.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.promptForApiKey(providerID: deepseekProviderID, completion: nil)
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

    private func displayName(for token: String) -> String {
        if token == "gpt" { return "GPT" }
        return targetByToken(token)?.title ?? "GPT"
    }

    func refreshUI() {
        guard let button = statusItem?.button else { return }
        let token = currentToken()
        let title: String
        let color: NSColor
        let tooltip: String
        if token == "gpt" {
            title = "GPT"
            color = .systemGreen
            tooltip = "Codex 当前：GPT。点击选择模型"
        } else if let row = targetByToken(token) {
            title = row.statusTitle
            color = row.color
            tooltip = "Codex 当前：\(row.title)。点击选择模型"
        } else {
            title = "???"
            color = .systemGray
            tooltip = "Codex 当前配置无法识别，点击选择模型"
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
        let token = currentToken()

        let infoItem = NSMenuItem(
            title: "当前模型：\(displayName(for: token))",
            action: nil, keyEquivalent: "")
        infoItem.isEnabled = false
        menu.addItem(infoItem)
        menu.addItem(.separator())

        // GPT
        let gptItem = makeSwitchItem(title: "GPT", represented: "gpt", isOn: token == "gpt")
        menu.addItem(gptItem)

        // DeepSeek 组
        for row in targetTable where row.providerID == deepseekProviderID {
            menu.addItem(makeSwitchItem(title: row.title, represented: row.token,
                                        isOn: token == row.token))
        }

        // 智谱 Bigmodel 组
        let bmHeader = NSMenuItem(title: "智谱 Bigmodel", action: nil, keyEquivalent: "")
        bmHeader.isEnabled = false
        menu.addItem(bmHeader)
        for row in targetTable where row.providerID == bigmodelProviderID {
            menu.addItem(makeSwitchItem(title: row.title, represented: row.token,
                                        isOn: token == row.token))
        }

        menu.addItem(.separator())

        // 思考程度（model_reasoning_effort，两家模型均支持 low / high / max）
        let effort = loadSettings().reasoningEffort
        let effortItem = NSMenuItem(title: "思考程度", action: nil, keyEquivalent: "")
        let effortSub = NSMenu(title: "思考程度")
        for lvl in reasoningEfforts {
            let item = NSMenuItem(title: lvl, action: #selector(setEffortFromMenu(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = lvl
            item.state = effort == lvl ? .on : .off
            effortSub.addItem(item)
        }
        effortItem.submenu = effortSub
        menu.addItem(effortItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "修改 DeepSeek API Key…",
                     action: #selector(changeDeepseekKey(_:)), keyEquivalent: "k")
            .target = self
        menu.addItem(withTitle: "修改智谱 Bigmodel API Key…",
                     action: #selector(changeBigmodelKey(_:)), keyEquivalent: "b")
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

    private func makeSwitchItem(title: String, represented: String, isOn: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(switchFromMenu(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = represented
        item.state = isOn ? .on : .off
        return item
    }

    @objc func switchFromMenu(_ sender: NSMenuItem) {
        guard let represented = sender.representedObject as? String else { return }
        if represented == "gpt" {
            doApply(nil)
            return
        }
        guard let row = targetByToken(represented) else { return }
        beginApply(row)
    }

    @objc func setEffortFromMenu(_ sender: NSMenuItem) {
        guard let lvl = sender.representedObject as? String,
              reasoningEfforts.contains(lvl) else { return }
        do {
            try prepareStorage()
            try setReasoningEffort(lvl)
            sendNotification(title: "思考程度已调整",
                             body: "model_reasoning_effort = \(lvl)。新开任务后生效。")
        } catch {
            showAlert(error: error)
        }
    }

    @objc func changeDeepseekKey(_ sender: Any?) {
        promptForApiKey(providerID: deepseekProviderID, completion: nil)
    }

    @objc func changeBigmodelKey(_ sender: Any?) {
        promptForApiKey(providerID: bigmodelProviderID, completion: nil)
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

    /// 目标提供商还没有可用 API Key 时，先弹窗要求输入（第一次进入即为该流程）
    private func beginApply(_ row: ModelTarget) {
        let s = loadSettings()
        let existing = row.providerID == bigmodelProviderID ? s.bigmodelApiKey : s.deepseekApiKey
        if isValidKey(row.providerID, existing) {
            doApply(row)
        } else {
            promptForApiKey(providerID: row.providerID) { [weak self] ok in
                if ok { self?.doApply(row) }
            }
        }
    }

    private func doApply(_ row: ModelTarget?) {
        do {
            let newToken = try applyTarget(row)
            refreshUI()
            let name = displayName(for: newToken)
            let body: String
            if newToken == "gpt" {
                body = "原 GPT 配置已完整恢复"
            } else if let r = targetByToken(newToken) {
                body = "模型：\(r.modelID)，思考程度：\(loadSettings().reasoningEffort)。跨提供商切换需重启 ChatGPT 客户端生效"
            } else {
                body = "切换后请重启 ChatGPT 客户端生效"
            }
            sendNotification(title: "已切换为 \(name)", body: body)
        } catch {
            refreshUI()
            showAlert(error: error)
        }
    }

    // MARK: API Key 输入框

    private func promptForApiKey(providerID: String, completion: ((Bool) -> Void)?) {
        let isBigmodel = providerID == bigmodelProviderID
        let alertTitle = isBigmodel ? "设置智谱 Bigmodel API Key" : "设置 DeepSeek API Key"
        let informative = isBigmodel
            ? "在 https://open.bigmodel.cn 用户中心的 API Keys 页面创建。\nKey 仅保存在本机 ~/.codex/switchcodex/settings.json。\n可直接在输入框内按 Command+V 粘贴，或点击「粘贴」按钮。"
            : "在 https://platform.deepseek.com/api_keys 创建（sk- 开头）。\nKey 仅保存在本机 ~/.codex/switchcodex/settings.json。\n可直接在输入框内按 Command+V 粘贴，或点击「粘贴」按钮。"

        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            var current = loadSettings().apiKeyText(providerID: providerID)
            while true {
                let alert = NSAlert()
                alert.messageText = alertTitle
                alert.informativeText = informative
                let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
                field.placeholderString = isBigmodel ? "xxxxxxxx.yyyyyyyy" : "sk-..."
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
                    if isValidKey(providerID, key) {
                        var s = loadSettings()
                        if isBigmodel {
                            s.bigmodelApiKey = key
                        } else {
                            s.deepseekApiKey = key
                        }
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
                    self.showAlert(message: isBigmodel
                        ? "API Key 看起来不完整，请检查后重试。"
                        : "API Key 必须以 sk- 开头，未保存。")
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

extension Settings {
    /// GUI 弹窗回显用：取某一家的现有 Key
    func apiKeyText(providerID: String) -> String {
        providerID == bigmodelProviderID ? bigmodelApiKey : deepseekApiKey
    }
}

// MARK: - 入口

let args = CommandLine.arguments
if args.contains("--toggle") || args.contains("--set") || args.contains("--state")
    || args.contains("--effort") {
    exit(runHeadless(args))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
