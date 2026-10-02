import SwiftUI
import LedgerCore

struct LedgerPanel: Identifiable {
    enum Destination {
        case entry(EntryKind, LedgerEntry?)
        case detail(LedgerEntry)
        case rules
    }

    let id = UUID()
    let destination: Destination

    var preferredSize: CGSize {
        switch destination {
        case .entry(.buy, _): CGSize(width: 580, height: 420)
        case .entry(.transfer, _): CGSize(width: 600, height: 580)
        case .detail: CGSize(width: 600, height: 420)
        case .rules: CGSize(width: 650, height: 620)
        }
    }
}

/// The overlay follows the available window area without imposing the form's
/// preferred size on the parent window. Only the backdrop cancels on a click.
struct LedgerPanelOverlay: View {
    let panel: LedgerPanel
    let onDismiss: () -> Void
    let onEdit: (LedgerEntry) -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Button(action: onDismiss) {
                    Rectangle().fill(.black.opacity(0.25)).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .accessibilityHidden(true)
                .accessibilityIdentifier("panel.backdrop")

                content
                    .id(panel.id)
                    .frame(width: min(panel.preferredSize.width, max(0, geometry.size.width - 40)),
                           height: min(panel.preferredSize.height, max(0, geometry.size.height - 40)))
                    .background {
                        Color(nsColor: .windowBackgroundColor)
                            .contentShape(Rectangle())
                            .onTapGesture { } // Empty space inside the panel must not cancel.
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color(nsColor: .separatorColor).opacity(0.5)))
                    .shadow(color: .black.opacity(0.22), radius: 20, y: 8)
                    .accessibilityElement(children: .contain)
                    .accessibilityAddTraits(.isModal)
                    .accessibilityIdentifier("panel.content")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private var content: some View {
        switch panel.destination {
        case .entry(let kind, let existing):
            EntryEditor(kind: kind, existing: existing, onDismiss: onDismiss)
        case .detail(let entry):
            EntryDetail(entry: entry, onEdit: { onEdit(entry) }, onDismiss: onDismiss)
        case .rules:
            RulesView(onDismiss: onDismiss)
        }
    }
}

struct PanelHeader: View {
    let title: String
    let onClose: () -> Void
    @AccessibilityFocusState private var titleFocused: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Text(title).font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($titleFocused)
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
            .help("取消并返回（Esc）")
            .accessibilityLabel("关闭操作窗口")
            .accessibilityIdentifier("panel.close")
        }
        .padding(20)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { titleFocused = true }
    }
}
