import SwiftUI
import ContextCore

struct BrowserOptionsMenu: View {
    @Environment(\.locale) private var locale
    @ObservedObject var model: WorkspaceModel
    var body: some View {
        Menu {
            Button(L("最近打开")) {
                model.browserFilter.sort = .opened; model.browserFilter.ascending = false
            }
            Button(L("最近修改")) {
                model.browserFilter.sort = .modified; model.browserFilter.ascending = false
            }
            Button(L("名称")) {
                model.browserFilter.sort = .name; model.browserFilter.ascending = true
            }
            Divider()
            Menu(L("高级筛选与排序")) {
                Menu(L("日期筛选")) {
                    Picker(L("日期字段"), selection: $model.browserFilter.dateField) {
                        ForEach(FileDateField.allCases, id: \.self) { Text(L10n.text($0.rawValue)).tag($0) }
                    }
                    Divider()
                    Picker(L("早于"), selection: $model.browserFilter.age) {
                        ForEach(FileAge.allCases, id: \.self) { Text(L10n.text($0.rawValue)).tag($0) }
                    }
                }
                Menu(L("格式筛选")) {
                    Button(L("所有格式")) { model.browserFilter.formats = [] }
                    Divider()
                    ForEach(FileFormat.allCases, id: \.self) { format in
                        Toggle(
                            L10n.text(format.rawValue),
                            isOn: Binding(
                                get: { model.browserFilter.formats.contains(format) },
                                set: { value in
                                    if value { model.browserFilter.formats.insert(format) } else { model.browserFilter.formats.remove(format) }
                                }))
                    }
                }
                Menu(L("排序")) {
                    Picker(L("排序依据"), selection: $model.browserFilter.sort) {
                        ForEach(FileSort.allCases, id: \.self) { Text(L10n.text($0.rawValue)).tag($0) }
                    }
                    Divider()
                    Picker(L("顺序"), selection: $model.browserFilter.ascending) {
                        Text(L("升序")).tag(true)
                        Text(L("降序")).tag(false)
                    }
                }
            }
            Divider()
            Menu(L("目录读取上限")) {
                Picker(L("单批索引上限"), selection: Binding(get: { model.scanCapacity }, set: { model.changeScanCapacity($0) })) {
                    ForEach(ScanCapacity.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }.disabled(model.busy || model.saving || model.editorLoading)
            Divider()
            Button(L("重置筛选与排序")) { model.browserFilter = BrowserFilter() }
        } label: {
            Image(systemName: "line.3.horizontal.decrease").font(.system(size: 18, weight: .medium))
                .frame(width: 36, height: 36)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 9))
                .overlay(alignment: .topTrailing) {
                    if model.activeFilterCount > 0 { Circle().fill(Palette.accent).frame(width: 6, height: 6).padding(4) }
                }
                .accessibilityLabel(L("日期、格式与排序"))
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel(L("日期、格式与排序"))
    }
}

struct FolderTreeRow: View {
    @Environment(\.locale) private var locale
    @ObservedObject var model: WorkspaceModel
    let folder: ProjectFolder
    var containsFiles = false
    var body: some View {
        HStack(spacing: 2) {
            if !(model.directoryIndex.children[folder.path] ?? []).isEmpty || containsFiles || model.folderNeedsLoading(folder.path) {
                Button {
                    model.toggleFolder(folder.path)
                } label: {
                    Image(systemName: model.expandedFolders.contains(folder.path) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold)).frame(width: 28, height: 36).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel((model.expandedFolders.contains(folder.path) ? L("收起") : L("展开")) + " " + folder.path)
            } else {
                Color.clear.frame(width: 28, height: 36).accessibilityHidden(true)
            }
            Button {
                model.openFolder(folder.path)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder").font(.system(size: 17)).accessibilityHidden(true)
                    Text(folder.name).font(.system(size: 13)).lineLimit(1)
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, minHeight: 36, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(L("文件夹 \(folder.path)")).disabled(model.busy)
                .accessibilityAddTraits(model.section == .all && model.folder == folder.path ? .isSelected : [])
        }
        .foregroundStyle(model.section == .all && model.folder == folder.path ? Palette.accent : Color.primary)
        .padding(.leading, CGFloat(min(folder.depth, 5)) * 12 + 12).padding(.trailing, 12)
        .background(model.section == .all && model.folder == folder.path ? Palette.accent.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 8)
        .disabled(model.busy)
    }
}

struct FolderLocationBar: View {
    @Environment(\.locale) private var locale
    @ObservedObject var model: WorkspaceModel
    var body: some View {
        HStack(spacing: 6) {
            if !model.folder.isEmpty {
                Button {
                    model.openFolder(DirectoryIndex.parent(of: model.folder))
                } label: {
                    Image(systemName: "chevron.left").font(.system(size: 13)).frame(width: 28, height: 28)
                }.buttonStyle(.borderless).accessibilityLabel(L("上一级文件夹"))
            }
            Menu {
                Button(model.root?.lastPathComponent ?? L("项目根目录")) { model.openFolder("") }
                ForEach(ancestorPaths, id: \.self) { path in
                    Button(path) { model.openFolder(path) }
                }
            } label: {
                Text(model.folder.isEmpty ? model.root?.lastPathComponent ?? L("项目根目录") : model.folder)
                    .font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
            }.menuStyle(.borderlessButton).accessibilityLabel(L("当前文件夹路径"))
            Spacer(minLength: 0)
        }.padding(.horizontal, 12).padding(.bottom, 10)
    }
    private var ancestorPaths: [String] {
        let parts = model.folder.split(separator: "/")
        return parts.indices.map { parts.prefix($0 + 1).joined(separator: "/") }
    }
}
