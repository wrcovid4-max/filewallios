import SwiftUI
import LanguageKit
import LanguageKitUI

/// Adds the 🌐 language menu to the top-right corner of a screen, and applies the chosen language.
/// Right-to-left languages mirror the layout. Text is still English until iOS translations exist.
struct LanguageSelection: ViewModifier {
    @AppStorage(Pref.language) private var languageTag = ""

    private var language: AppLanguage { AppLanguage(rawValue: languageTag) ?? .english }

    func body(content: Content) -> some View {
        content
            .environment(\.locale, language.locale)
            .environment(\.layoutDirection, language.isRightToLeft ? .rightToLeft : .leftToRight)
            .overlay(alignment: .topTrailing) {
                LanguageGlobeMenu(
                    selected: language,
                    texts: LanguageMenuTexts(
                        accessibilityLabel: String(localized: "Languages"),
                        title: String(localized: "Switch language?"),
                        body: String(localized: "Your files and settings are kept."),
                        confirm: String(localized: "Switch"),
                        cancel: String(localized: "Cancel")
                    ),
                    onSelect: { languageTag = $0.rawValue }
                )
                .padding(.trailing, 12)
                .padding(.top, 4)
            }
    }
}

extension View {
    /// Adds the language menu and applies the chosen language to this screen.
    func languageSelection() -> some View {
        modifier(LanguageSelection())
    }
}
