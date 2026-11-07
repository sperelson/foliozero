import CoreGraphics
import Foundation

/// Orders OCR lines for reading: top to bottom, then left to right. Lines that
/// overlap vertically by at least half the height of the smaller line form one
/// row and are joined with a space. A vertical gap larger than the median line
/// height starts a new paragraph (blank line).
public enum ReadingOrder {
    /// Groups `lines` into rows in reading order.
    public static func rows(_ lines: [OCRLine]) -> [[OCRLine]] {
        let sorted = lines
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { a, b in
                a.boundingBox.minY == b.boundingBox.minY ? a.boundingBox.minX < b.boundingBox.minX
                    : a.boundingBox.minY < b.boundingBox.minY
            }
        var rows: [[OCRLine]] = []
        var rowTop: CGFloat = 0
        var rowBottom: CGFloat = 0
        var rowMinHeight: CGFloat = 0

        for line in sorted {
            let box = line.boundingBox
            if !rows.isEmpty {
                let overlap = min(rowBottom, box.maxY) - max(rowTop, box.minY)
                if overlap >= 0.5 * min(rowMinHeight, box.height), overlap > 0 {
                    rows[rows.count - 1].append(line)
                    rowTop = min(rowTop, box.minY)
                    rowBottom = max(rowBottom, box.maxY)
                    rowMinHeight = min(rowMinHeight, box.height)
                    continue
                }
            }
            rows.append([line])
            rowTop = box.minY
            rowBottom = box.maxY
            rowMinHeight = box.height
        }
        return rows.map { $0.sorted { $0.boundingBox.minX < $1.boundingBox.minX } }
    }

    /// Lines flattened in reading order.
    public static func sorted(_ lines: [OCRLine]) -> [OCRLine] {
        rows(lines).flatMap { $0 }
    }

    /// Page text in reading order.
    public static func text(_ lines: [OCRLine]) -> String {
        let rows = rows(lines)
        guard !rows.isEmpty else { return "" }
        let heights = lines.map(\.boundingBox.height).sorted()
        let median = heights[heights.count / 2]

        var output = ""
        var previousBottom: CGFloat?
        for row in rows {
            let top = row.map(\.boundingBox.minY).min() ?? 0
            if let previousBottom {
                output += (top - previousBottom) > median ? "\n\n" : "\n"
            }
            output += row.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: " ")
            previousBottom = row.map(\.boundingBox.maxY).max() ?? top
        }
        return output
    }
}
