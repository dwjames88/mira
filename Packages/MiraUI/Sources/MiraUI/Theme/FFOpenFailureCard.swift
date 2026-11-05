import SwiftUI

private typealias T = FieldFramesTheme

/// Shown when Photos never hands over the editable original: the message, then RETRY and BACK.
public struct FFOpenFailureCard: View {
    nonisolated public static let defaultMessage = "Photos didn't hand over this photo."

    private let message: String
    private let detail: String?
    private let onRetry: () -> Void
    private let onBack: () -> Void

    public init(message: String = FFOpenFailureCard.defaultMessage, detail: String? = nil,
                onRetry: @escaping () -> Void, onBack: @escaping () -> Void) {
        self.message = message
        self.detail = detail
        self.onRetry = onRetry
        self.onBack = onBack
    }

    public var body: some View {
        VStack(spacing: T.rows(1)) {
            Text(message)
                .font(T.display(26, weight: .regular))
                .foregroundStyle(T.paper)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail)
                    .ffLabel(size: 11)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: T.cells(2)) {
                Button("RETRY", action: onRetry)
                    .buttonStyle(FFButtonStyle(prominent: true))
                    .accessibilityIdentifier("OpenFailureRetry")
                Button("BACK", action: onBack)
                    .buttonStyle(FFButtonStyle())
                    .accessibilityIdentifier("OpenFailureBack")
            }
            .padding(.top, T.rows(1))
        }
        .padding(T.cells(4))
        .frame(maxWidth: T.cells(48))
        .background { FFPanelBackground() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("OpenFailureCard")
    }
}
