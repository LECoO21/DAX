import Foundation

enum TextNormalizer {
    static func apply(_ text: String, preferences: Preferences) -> String {
        var value = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if preferences.repairHyphenation {
            value = value.replacingOccurrences(of: "(?<=[A-Za-z])-\\s*\\n\\s*(?=[A-Za-z])", with: "", options: .regularExpression)
        }
        if preferences.stripComments {
            value = value.replacingOccurrences(of: "(?m)^\\s*(?://+|/\\*+|\\*+/|\\*|#)\\s?", with: "", options: .regularExpression)
        }
        if preferences.splitIdentifiers {
            value = value.replacingOccurrences(of: "([A-Z]+)([A-Z][a-z])", with: "$1 $2", options: .regularExpression)
            value = value.replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
            value = value.replacingOccurrences(of: "(?<=[\\p{L}\\p{N}])_+(?=[\\p{L}\\p{N}])", with: " ", options: .regularExpression)
        }
        if preferences.joinLines {
            value = value.components(separatedBy: .newlines).joined(separator: " ")
        } else if preferences.smartParagraphs {
            value = paragraphs(value)
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func paragraphs(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        var output = ""
        var previous = ""
        for line in lines {
            if !output.isEmpty {
                let list = line.range(of: "^(?:[-*•]|[0-9]+[.)、])\\s", options: .regularExpression) != nil
                let endsSentence = previous.last.map { ".!?。！？：:".contains($0) } ?? false
                if previous.isEmpty || line.isEmpty || list || endsSentence {
                    output += "\n"
                } else if !(isCJK(previous.last) && isCJK(line.first)) {
                    output += " "
                }
            }
            output += line
            previous = line
        }
        return output
    }

    private static func isCJK(_ character: Character?) -> Bool {
        guard let character, let scalar = character.unicodeScalars.first else { return false }
        return (0x3400...0x9FFF).contains(scalar.value)
    }
}
