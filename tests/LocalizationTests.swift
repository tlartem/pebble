import Foundation

@main struct LocalizationTests {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let ru = Bundle(url: root.appendingPathComponent("ru.lproj"))!
        let en = Bundle(url: root.appendingPathComponent("en.lproj"))!
        precondition(L("Today", bundle: ru) == "Сегодня")
        precondition(L("Today", bundle: en) == "Today")
        precondition(L("Securing the connection", bundle: ru) == "Защита соединения")
        precondition(L("%@%% battery", "73", bundle: ru) == "Заряд: 73%")
        precondition(L("Every %@ steps · %@", "2500", "Double", bundle: ru) == "Каждые 2500 шагов · Два сигнала")
        precondition(L("Your own history", bundle: ru) == "Ваша история")
        precondition(L("device-identifier-123", bundle: ru) == "device-identifier-123")
        precondition(L("The light shows battery: white above 20%, red below. Its colour is set by the band’s firmware and can’t be changed by apps.", bundle: ru).contains("20%"))
        let format = try NSRegularExpression(pattern: #"%(?:%|(?:\d+\$)?(?:\.\d+)?(?:ll)?[@df])"#)
        func placeholders(_ text: String) -> [String] {
            format.matches(in: text, range: NSRange(text.startIndex..., in: text))
                .map { (text as NSString).substring(with: $0.range) }.filter { $0 != "%%" }.sorted()
        }
        for table in ["Localizable", "InfoPlist", "AppShortcuts"] {
            func entries(_ language: String) throws -> [String: String] {
                let url = root.appendingPathComponent("\(language).lproj/\(table).strings")
                return try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as! [String: String]
            }
            let english = try entries("en"), russian = try entries("ru")
            precondition(Set(english.keys) == Set(russian.keys))
            for (key, text) in russian {
                precondition(!text.isEmpty && placeholders(english[key]!) == placeholders(text), key)
            }
        }
        print("PASS: Russian/English resources, formatted messages, nested labels, percent escaping and identifier fallback")
    }
}
