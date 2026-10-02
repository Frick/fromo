import Foundation

public enum CSV {
    // A malformed logical record is represented by [] so readers can warn once and continue.
    public static func records(_ text: String) -> [[String]] {
        enum Mode { case start, unquoted, quoted, afterQuote }
        var bytes = Array(text.utf8)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        var records: [[String]] = []
        var fields: [String] = []
        var field: [UInt8] = []
        var mode = Mode.start
        var invalid = false
        var dirty = false
        var index = 0
        func finishField() { fields.append(String(decoding: field, as: UTF8.self)); field = []; mode = .start }
        func finishRecord() {
            if dirty || !fields.isEmpty || !field.isEmpty {
                finishField()
                records.append(invalid ? [] : fields)
            }
            fields = []; field = []; invalid = false; dirty = false; mode = .start
        }
        while index < bytes.count {
            let byte = bytes[index]
            if mode == .quoted {
                if byte == 34 { mode = .afterQuote }
                else { field.append(byte) }
            } else if mode == .afterQuote && byte == 34 {
                field.append(34); mode = .quoted
            } else if byte == 44 {
                dirty = true; finishField()
            } else if byte == 10 || byte == 13 {
                finishRecord()
                if byte == 13 && index + 1 < bytes.count && bytes[index + 1] == 10 { index += 1 }
            } else if byte == 34 {
                dirty = true
                if mode == .start { mode = .quoted }
                else { invalid = true; mode = .unquoted }
            } else {
                dirty = true
                if mode == .afterQuote { invalid = true }
                field.append(byte); mode = .unquoted
            }
            index += 1
        }
        if mode == .quoted { invalid = true }
        finishRecord()
        return records
    }
}
