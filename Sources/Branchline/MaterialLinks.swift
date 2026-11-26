import SwiftUI
import AppKit
import ProgressCore

extension AppStore {
    func openMaterial(_ url: URL) {
        guard MaterialLink.canOpen(url) else { return }
        if url.isFileURL && !FileManager.default.fileExists(atPath: url.path) {
            error = "找不到资料「\(url.lastPathComponent)」。请确认文件已同步到这台 Mac，或在记录里更新路径。"
            return
        }
        if !NSWorkspace.shared.open(url) { error = "无法打开该资料，请检查地址和本机的默认打开应用。" }
    }
}

struct MaterialLinkFields: View {
    @Bindable var store: AppStore
    @Binding var links: [MaterialLink]?
    @LocalState private var address = ""
    @LocalState private var title = ""
    @LocalState private var error: String?

    var body: some View {
        ForEach(Array((links ?? []).enumerated()), id: \.offset) { index, link in
            HStack {
                Image(systemName: link.url.isFileURL ? "doc" : "link")
                VStack(alignment: .leading, spacing: 2) {
                    Text(link.title).lineLimit(2)
                    Text(link.url.isFileURL ? link.url.path : link.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button { remove(at: index) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless).accessibilityLabel("移除资料链接：\(link.title)")
            }
        }
        VStack(alignment: .leading, spacing: 8) {
            Text("资料地址").font(.callout.weight(.medium))
            TextField("资料地址", text: $address, prompt: Text("粘贴网页链接或本机路径"))
                .labelsHidden().textFieldStyle(.roundedBorder).accessibilityIdentifier("materialAddress")
            HStack(spacing: 8) {
                TextField("显示名称", text: $title, prompt: Text("显示名称（选填）"))
                    .labelsHidden().textFieldStyle(.roundedBorder)
                Button("添加链接") { addAddress() }
                    .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("选择文件或文件夹…") { pickFiles() }.disabled(store.fileDialogPending)
            }.buttonStyle(.bordered)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
    }

    private func remove(at index: Int) {
        guard var current = links, current.indices.contains(index) else { return }
        current.remove(at: index)
        links = current.isEmpty ? nil : current
    }

    private func addAddress() {
        guard let link = MaterialLink(address: address, title: title) else {
            error = "请输入完整的网页地址（http 或 https），或以 / 开头的本机路径。"
            return
        }
        add([link])
        address = ""
        title = ""
    }

    private func add(_ additions: [MaterialLink]) {
        var current = links ?? []
        for link in additions where !current.contains(where: { $0.url == link.url }) { current.append(link) }
        if current.count != (links?.count ?? 0) { links = current }
        error = nil
    }

    private func pickFiles() {
        guard !store.fileDialogPending else { return }
        let panel = NSOpenPanel()
        panel.prompt = "添加资料"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        if !store.chooseMaterialFiles(panel, completion: { urls in
            add(urls.compactMap { MaterialLink(address: $0.absoluteString) })
        }) {
            error = "无法打开文件选择窗口。可以粘贴资料路径。"
        }
    }
}
