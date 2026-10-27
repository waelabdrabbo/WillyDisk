import SwiftUI
import DiskLocalization

/// One scan option: the consequence spelled out beside its switch.
///
/// The source screen's Scan Options sheet and the Settings window both use this
/// row, so the title, the explanation, and the switch position cannot drift
/// between the two places that edit the same store.
struct ScanOptionToggle: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: DS.Spacing.medium) {
            VStack(alignment: .leading, spacing: DS.Spacing.hairline) {
                Text(title)
                    .font(DS.Typography.body)
                Text(detail)
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel(title)
                .accessibilityValue(L10n.string(isOn ? "On" : "Off"))
        }
    }
}
