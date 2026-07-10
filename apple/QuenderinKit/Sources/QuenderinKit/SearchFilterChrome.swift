#if canImport(SwiftUI)
import SwiftUI

// MARK: - Quenderin hybrid filter chrome
//
// Product filters are app chrome (not System Settings). Use brand surfaces + primary tint;
// keep native Menu / Toggle *behavior* under the hood. Active state changes COLOR only
// (UI_DESIGN_RULES: no geometry jump on :active / checked).

/// Fixed outer size for every chip / menu trigger so selection never reflows the row.
private enum FilterChromeMetrics {
    static let chipH: CGFloat = 30
    static let chipPadH: CGFloat = 12
    static let hairline: CGFloat = 1
    static let panelRadius: CGFloat = 12
}

/// Preset or toggle-looking pill. Active = brand tint + primary text/border (same padding).
struct QFilterChip: View {
    let title: String
    var systemImage: String? = nil
    let active: Bool
    let palette: QuenderinPalette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.caption2.weight(.semibold))
                }
                Text(title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
            .foregroundStyle(active ? palette.primary : palette.onSurface)
            .padding(.horizontal, FilterChromeMetrics.chipPadH)
            .frame(height: FilterChromeMetrics.chipH)
            .background(
                Capsule().fill(active ? palette.primary.opacity(0.14) : palette.surface)
            )
            .overlay(
                Capsule().strokeBorder(
                    active ? palette.primary.opacity(0.55) : palette.onSurfaceVariant.opacity(0.18),
                    lineWidth: FilterChromeMetrics.hairline
                )
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }
}

/// Chip-shaped menu trigger; menu body is native (keyboard / a11y), look is Quenderin.
struct QFilterMenuChip<T: Hashable>: View {
    let title: String
    let selection: Binding<T?>
    let options: [(T?, String)]
    let palette: QuenderinPalette

    private var currentLabel: String {
        options.first(where: { $0.0 == selection.wrappedValue })?.1 ?? title
    }

    private var isActive: Bool {
        selection.wrappedValue != nil
    }

    var body: some View {
        Menu {
            ForEach(Array(options.enumerated()), id: \.offset) { _, opt in
                Button {
                    selection.wrappedValue = opt.0
                } label: {
                    if opt.0 == selection.wrappedValue {
                        Label(opt.1, systemImage: "checkmark")
                    } else {
                        Text(opt.1)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(currentLabel)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(isActive ? palette.primary : palette.onSurface)
            .padding(.horizontal, FilterChromeMetrics.chipPadH)
            .frame(height: FilterChromeMetrics.chipH)
            .background(
                Capsule().fill(isActive ? palette.primary.opacity(0.14) : palette.surface)
            )
            .overlay(
                Capsule().strokeBorder(
                    isActive ? palette.primary.opacity(0.55) : palette.onSurfaceVariant.opacity(0.18),
                    lineWidth: FilterChromeMetrics.hairline
                )
            )
        }
        .menuStyle(.borderlessButton)
        .qHideMenuIndicator()
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// Sort menu with the same chip chrome.
struct QFilterSortChip: View {
    @Binding var sort: ModelSearchFilters.Sort
    let palette: QuenderinPalette

    private var label: String {
        switch sort {
        case .downloads: return "Downloads"
        case .paramsAsc: return "Smallest first"
        case .paramsDesc: return "Largest first"
        case .name: return "Name"
        }
    }

    var body: some View {
        Menu {
            ForEach(ModelSearchFilters.Sort.allCases, id: \.self) { s in
                Button {
                    sort = s
                } label: {
                    if s == sort {
                        Label(sortTitle(s), systemImage: "checkmark")
                    } else {
                        Text(sortTitle(s))
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.caption2.weight(.semibold))
                Text(label)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(palette.onSurface)
            .padding(.horizontal, FilterChromeMetrics.chipPadH)
            .frame(height: FilterChromeMetrics.chipH)
            .background(Capsule().fill(palette.surface))
            .overlay(
                Capsule().strokeBorder(palette.onSurfaceVariant.opacity(0.18), lineWidth: FilterChromeMetrics.hairline)
            )
        }
        .menuStyle(.borderlessButton)
        .qHideMenuIndicator()
        .fixedSize(horizontal: true, vertical: false)
    }

    private func sortTitle(_ s: ModelSearchFilters.Sort) -> String {
        switch s {
        case .downloads: return "Most downloads"
        case .paramsAsc: return "Smallest first"
        case .paramsDesc: return "Largest first"
        case .name: return "Name A–Z"
        }
    }
}

/// Native switch behavior, brand ON color — not system blue/gray mush.
struct QFilterToggle: View {
    let title: String
    @Binding var isOn: Bool
    let palette: QuenderinPalette

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
                .font(.caption)
                .foregroundStyle(palette.onSurface)
                .fixedSize(horizontal: false, vertical: true)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .tint(palette.primary)
    }
}

/// Hairline panel wrapping expert filters (no card shadow).
struct QFilterPanel<Content: View>: View {
    let palette: QuenderinPalette
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: FilterChromeMetrics.panelRadius, style: .continuous)
                    .fill(palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: FilterChromeMetrics.panelRadius, style: .continuous)
                    .strokeBorder(palette.onSurfaceVariant.opacity(0.14), lineWidth: FilterChromeMetrics.hairline)
            )
    }
}

private extension View {
    /// Hide the system menu chevron when we draw our own (macOS 14+ / iOS 17+).
    @ViewBuilder
    func qHideMenuIndicator() -> some View {
        if #available(macOS 14.0, iOS 17.0, *) {
            self.menuIndicator(.hidden)
        } else {
            self
        }
    }
}
#endif
