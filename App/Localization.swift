import Foundation

func L(_ key: String, _ arguments: String..., bundle: Bundle = .main) -> String {
    let text = bundle.localizedString(forKey: key, value: key, table: nil)
    guard !arguments.isEmpty else { return text }
    let values = arguments.map { bundle.localizedString(forKey: $0, value: $0, table: nil) }
    return String(format: text, locale: Locale.current, arguments: values)
}
