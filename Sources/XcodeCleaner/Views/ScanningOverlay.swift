import SwiftUI

extension View {
    /// The same indication in every section that a scan fills: a table quietly filling with
    /// spinners does not tell the user that anything is happening.
    func scanningOverlay(_ isScanning: Bool) -> some View {
        overlay {
            if isScanning {
                ProgressView("Сканирование…")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}
