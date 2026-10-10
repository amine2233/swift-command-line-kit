import Foundation

extension String {
    /// Create a filename using a specific rule
    ///
    /// If we have `junit.xml` with position `0` and `1` then the result will be `junit.xml` and
    /// `junit-1.xml`.
    ///
    /// If we have `junit.test.xml` with position `0` and `1` then the result will be `junit.test.xml` and
    /// `junit.test-1.xml`.
    ///
    /// If we have `junit` with position `0` and `1` then the result will be `junit` and `junit-1`.
    ///
    /// - Parameters:
    ///   - position: The position of file
    ///   - separator: The seperator
    /// - Returns: The new filename
    public func createFileName(position: Int, separator: String = "-") -> String {
        if position == 0 { return self }
        var names = split(separator: ".")
        guard let fileExtension = names.last,
              names.count > 2 else { return appending(separator).appending("\(position)") }

        _ = names.removeLast()
        return names.joined(separator: ".") + separator + "\(position)" + "." + fileExtension
    }
}
