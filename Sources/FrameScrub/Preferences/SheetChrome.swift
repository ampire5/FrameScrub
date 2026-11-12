import SwiftUI

/// Shared hierarchy for the player sheets. Keep the native window, focus and button behavior.
struct SheetHeading: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 20, weight: .medium))
                .accessibilityAddTraits(.isHeader)
            Text(detail).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SheetActions<Action: View>: View {
    let onCancel: () -> Void
    @ViewBuilder let action: Action

    var body: some View {
        VStack(spacing: 12) {
            Divider()
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                action
            }
        }
    }
}
