import SwiftUI
import ProgressCore

struct AIClientSettings: View {
    private enum CopyKind { case claudeDesktop, claudeCode, codex }

    let store: AppStore
    @LocalState private var desktopStatus: AIClientConfiguration.DesktopStatus?
    @LocalState private var desktopError: String?
    @LocalState private var copied: CopyKind?

    private var configuration: AIClientConfiguration? {
        guard let executable = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("branchline-cli"),
              FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        return AIClientConfiguration(executable: executable, dataDirectory: store.dataDirectory)
    }

    private var serviceStatus: (title: String, color: Color) {
        if store.automationMode == "off" { return ("已关闭", .secondary) }
        if !store.automationRunning { return ("启动失败", .red) }
        if store.isDemo { return ("示例空间暂停访问", .orange) }
        return ("运行中", .green)
    }

    var body: some View {
        Section("AI 客户端连接（MCP）") {
            Picker("访问权限", selection: Binding(get: { store.automationMode }, set: { store.setAutomationMode($0) })) {
                Text("关闭").tag("off")
                Text("只读").tag("readOnly")
                Text("读取与修改").tag("readWrite")
            }.help("权限适用于所有本机 AI 客户端。编辑器打开时暂停外部写入。客户端可能将读取内容发送给其模型服务。")

            LabeledContent("脉络本机服务") {
                Label {
                    Text(serviceStatus.title)
                } icon: {
                    Image(systemName: "circle.fill").font(.caption2).foregroundStyle(serviceStatus.color)
                }
            }
            if store.automationMode != "off", let error = store.automationStartupError {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }

            if let configuration {
                claudeRow(configuration)
                gptRow(configuration)
            } else {
                Text("应用内缺少 MCP 程序，请使用完整的脉络应用包。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { refreshDesktopStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshDesktopStatus() }
    }

    private func claudeRow(_ configuration: AIClientConfiguration) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            LabeledContent("Claude") {
                HStack {
                    if desktopStatus == .missing {
                        Button("添加到 Claude Desktop") { addToClaudeDesktop(configuration) }
                    } else if desktopStatus == .different || desktopError != nil {
                        Button("打开配置文件") { NSWorkspace.shared.open(AIClientConfiguration.desktopConfigURL) }
                            .disabled(!FileManager.default.fileExists(atPath: AIClientConfiguration.desktopConfigURL.path))
                    }
                    Button(copied == .claudeDesktop ? "已复制" : "复制 Desktop 配置") {
                        copy(.claudeDesktop) { try configuration.desktopJSON() }
                    }.help("手动配置时，将 branchline 合并进 Claude Desktop 设置 → 开发者 → 编辑配置中的 mcpServers。")
                }
            }
            Text(desktopInstructions).font(.caption).foregroundStyle(.secondary)
            if let desktopError { Text(desktopError).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            DisclosureGroup("Claude Code") {
                VStack(alignment: .leading, spacing: 7) {
                    Text("在终端运行添加命令，再用 /mcp 查看 branchline 状态。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(copied == .claudeCode ? "已复制" : "复制 Claude Code 添加命令") {
                        copy(.claudeCode) { configuration.claudeCodeCommand }
                    }.padding(.bottom, 2)
                }
                .padding(.top, 4)
            }.font(.callout)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func gptRow(_ configuration: AIClientConfiguration) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            LabeledContent("GPT（OpenAI）") {
                HStack {
                    if FileManager.default.fileExists(atPath: AIClientConfiguration.codexConfigURL.path) {
                        Button("打开 Codex 配置") { NSWorkspace.shared.open(AIClientConfiguration.codexConfigURL) }
                    }
                    Button(copied == .codex ? "已复制" : "复制 Codex 配置") {
                        copy(.codex) { try configuration.codexTOML() }
                    }.help("在 Codex 的 config.toml 中添加或更新 branchline，再重启 Codex。普通 ChatGPT 聊天需要远程连接器。")
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var desktopInstructions: String {
        switch desktopStatus {
        case .configured: "配置已添加。首次添加后请完全退出并重开 Claude Desktop，然后试着问「通过脉络列出我的项目」。"
        case .different: "已有 branchline 配置，请核对其中的程序路径及参数。"
        case .missing: "添加后重启 Claude Desktop，即可在聊天中使用脉络。"
        case nil: "可复制配置，在 Claude Desktop 的开发者设置中手动添加。"
        }
    }

    private func refreshDesktopStatus() {
        do {
            desktopStatus = try configuration?.desktopStatus()
            desktopError = nil
        } catch {
            desktopStatus = nil
            desktopError = error.localizedDescription
        }
    }

    private func addToClaudeDesktop(_ configuration: AIClientConfiguration) {
        do {
            try configuration.addToClaudeDesktop()
            refreshDesktopStatus()
        } catch { desktopError = error.localizedDescription }
    }

    private func copy(_ kind: CopyKind, content: () throws -> String) {
        do {
            let text = try content()
            NSPasteboard.general.clearContents()
            if NSPasteboard.general.setString(text, forType: .string) { copied = kind }
            else { store.notice = "无法写入剪贴板。" }
        } catch { store.notice = "无法生成配置。\(error.localizedDescription)" }
    }
}
