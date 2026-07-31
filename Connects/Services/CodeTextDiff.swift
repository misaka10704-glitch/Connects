import Foundation
import UIKit

enum CodeDiffLineKind {
    case unchanged
    case removed
    case added
}

struct CodeDiffLine {
    let kind: CodeDiffLineKind
    let text: String
}

enum CodeDiffHunkDecision {
    case pending
    case kept
    case undone
}

struct CodeDiffHunk {
    var removed: [String]
    var added: [String]
    var decision: CodeDiffHunkDecision

    var isPending: Bool { decision == .pending }
}

enum CodeDiffSegment {
    case unchanged([String])
    case hunk(CodeDiffHunk)
}

enum CodeTextDiff {
    /// Abort Myers and emit a single replace hunk when edit distance grows this large.
    /// Prevents O(ND)≈O(N²) freezes on near-total rewrites.
    private static let myersMaxD = 2_500
    /// Classical LCS only for tiny middles (tests / micro edits).
    private static let lcsProductLimit = 40_000

    /// Line-oriented diff. `before` may be empty (full add / write).
    /// Uses common prefix/suffix strip + Myers O(ND); falls back to a single
    /// replace hunk when the middle is a near-total rewrite.
    static func lines(before: String, after: String) -> [CodeDiffLine] {
        let a = before.components(separatedBy: "\n")
        let b = after.components(separatedBy: "\n")
        if a == b {
            return a.map { CodeDiffLine(kind: .unchanged, text: $0) }
        }

        var start = 0
        let minCount = min(a.count, b.count)
        while start < minCount, a[start] == b[start] {
            start += 1
        }
        var endA = a.count
        var endB = b.count
        while endA > start, endB > start, a[endA - 1] == b[endB - 1] {
            endA -= 1
            endB -= 1
        }

        var result: [CodeDiffLine] = []
        result.reserveCapacity(a.count + b.count - start)
        if start > 0 {
            for i in 0..<start {
                result.append(CodeDiffLine(kind: .unchanged, text: a[i]))
            }
        }

        let aMid = Array(a[start..<endA])
        let bMid = Array(b[start..<endB])
        result.append(contentsOf: diffMiddle(aMid, bMid))

        if endA < a.count {
            for i in endA..<a.count {
                result.append(CodeDiffLine(kind: .unchanged, text: a[i]))
            }
        }
        return result
    }

    /// Group consecutive remove/add runs into hunks interleaved with unchanged spans.
    static func segments(from lines: [CodeDiffLine]) -> [CodeDiffSegment] {
        var result: [CodeDiffSegment] = []
        var unchangedBuf: [String] = []
        var removedBuf: [String] = []
        var addedBuf: [String] = []

        func flushUnchanged() {
            guard !unchangedBuf.isEmpty else { return }
            result.append(.unchanged(unchangedBuf))
            unchangedBuf = []
        }
        func flushHunk() {
            guard !removedBuf.isEmpty || !addedBuf.isEmpty else { return }
            result.append(.hunk(CodeDiffHunk(removed: removedBuf, added: addedBuf, decision: .pending)))
            removedBuf = []
            addedBuf = []
        }

        for line in lines {
            switch line.kind {
            case .unchanged:
                flushHunk()
                unchangedBuf.append(line.text)
            case .removed:
                flushUnchanged()
                removedBuf.append(line.text)
            case .added:
                flushUnchanged()
                addedBuf.append(line.text)
            }
        }
        flushHunk()
        flushUnchanged()
        return result
    }

    static func compose(_ segments: [CodeDiffSegment], pendingAsUndone: Bool = true) -> String {
        var parts: [String] = []
        for seg in segments {
            switch seg {
            case .unchanged(let lines):
                parts.append(contentsOf: lines)
            case .hunk(let hunk):
                switch hunk.decision {
                case .kept:
                    parts.append(contentsOf: hunk.added)
                case .undone:
                    parts.append(contentsOf: hunk.removed)
                case .pending:
                    parts.append(contentsOf: pendingAsUndone ? hunk.removed : hunk.added)
                }
            }
        }
        return parts.joined(separator: "\n")
    }

    static func pendingHunkIndices(in segments: [CodeDiffSegment]) -> [Int] {
        segments.enumerated().compactMap { idx, seg in
            if case .hunk(let h) = seg, h.isPending { return idx }
            return nil
        }
    }

    static func attributedString(segments: [CodeDiffSegment],
                                 font: UIFont,
                                 textColor: UIColor,
                                 highlightHunkIndex: Int?) -> (NSAttributedString, [Int: NSRange]) {
        let removeBG = UIColor(red: 0.85, green: 0.15, blue: 0.15, alpha: 0.18)
        let addBG = UIColor(red: 0.12, green: 0.65, blue: 0.30, alpha: 0.18)

        // Collect plain text + per-line paint ranges, then one attributed paint pass.
        var body = ""
        body.reserveCapacity(segments.reduce(0) { sum, seg in
            switch seg {
            case .unchanged(let lines): return sum + lines.reduce(0) { $0 + $1.count + 3 }
            case .hunk(let h):
                return sum
                    + h.removed.reduce(0) { $0 + $1.count + 3 }
                    + h.added.reduce(0) { $0 + $1.count + 3 }
            }
        })
        var utf16Len = 0
        var paints: [(range: NSRange, bg: UIColor)] = []
        var hunkRanges: [Int: NSRange] = [:]

        func appendLines(_ lines: [String], prefix: String, bg: UIColor?) {
            for line in lines {
                let start = utf16Len
                body.append(prefix)
                body.append(line)
                body.append("\n")
                // prefix is ASCII; newline is ASCII; line may contain non-BMP.
                utf16Len += prefix.utf16.count + line.utf16.count + 1
                let len = utf16Len - start
                if let bg = bg, len > 0 {
                    paints.append((NSRange(location: start, length: len), bg))
                }
            }
        }

        for (idx, seg) in segments.enumerated() {
            let start = utf16Len
            switch seg {
            case .unchanged(let lines):
                appendLines(lines, prefix: "  ", bg: nil)
            case .hunk(let hunk):
                let focused = highlightHunkIndex == idx
                switch hunk.decision {
                case .pending:
                    // Keep red/green visible; focus = stronger tint (no solid blue wash).
                    let rem = focused
                        ? UIColor(red: 0.85, green: 0.15, blue: 0.15, alpha: 0.34)
                        : removeBG
                    let add = focused
                        ? UIColor(red: 0.12, green: 0.65, blue: 0.30, alpha: 0.34)
                        : addBG
                    appendLines(hunk.removed, prefix: "− ", bg: rem)
                    appendLines(hunk.added, prefix: "+ ", bg: add)
                case .kept:
                    // Kept lines look like normal source — no residual tint / focus wash.
                    appendLines(hunk.added, prefix: "  ", bg: nil)
                case .undone:
                    appendLines(hunk.removed, prefix: "  ", bg: nil)
                }
                let len = utf16Len - start
                if len > 0 {
                    hunkRanges[idx] = NSRange(location: start, length: len)
                }
            }
        }

        if body.hasSuffix("\n") {
            body.removeLast()
            utf16Len -= 1
            for (k, r) in hunkRanges {
                if NSMaxRange(r) > utf16Len {
                    hunkRanges[k] = NSRange(location: r.location, length: max(0, utf16Len - r.location))
                }
            }
            paints = paints.compactMap { paint in
                if paint.range.location >= utf16Len { return nil }
                let len = min(paint.range.length, utf16Len - paint.range.location)
                return (NSRange(location: paint.range.location, length: len), paint.bg)
            }
        }

        let result = NSMutableAttributedString(
            string: body,
            attributes: [.font: font, .foregroundColor: textColor]
        )
        for paint in paints {
            guard paint.range.length > 0,
                  NSMaxRange(paint.range) <= result.length else { continue }
            result.addAttribute(.backgroundColor, value: paint.bg, range: paint.range)
        }
        return (result, hunkRanges)
    }

    // MARK: - Diff engines

    private static func diffMiddle(_ a: [String], _ b: [String]) -> [CodeDiffLine] {
        if a.isEmpty {
            return b.map { CodeDiffLine(kind: .added, text: $0) }
        }
        if b.isEmpty {
            return a.map { CodeDiffLine(kind: .removed, text: $0) }
        }
        let product = a.count * b.count
        if product <= lcsProductLimit {
            return lcsDiff(a, b)
        }
        if let myers = myersDiff(a, b) {
            return myers
        }
        // Near-total rewrite — one coarse hunk (still Keep/Undo correct).
        return replaceHunk(a, b)
    }

    private static func replaceHunk(_ a: [String], _ b: [String]) -> [CodeDiffLine] {
        var out: [CodeDiffLine] = []
        out.reserveCapacity(a.count + b.count)
        out.append(contentsOf: a.map { CodeDiffLine(kind: .removed, text: $0) })
        out.append(contentsOf: b.map { CodeDiffLine(kind: .added, text: $0) })
        return out
    }

    private static func lcsDiff(_ a: [String], _ b: [String]) -> [CodeDiffLine] {
        let table = lcsTable(a, b)
        var stack: [CodeDiffLine] = []
        stack.reserveCapacity(a.count + b.count)
        var i = a.count
        var j = b.count
        while i > 0 || j > 0 {
            if i > 0, j > 0, a[i - 1] == b[j - 1] {
                stack.append(CodeDiffLine(kind: .unchanged, text: a[i - 1]))
                i -= 1
                j -= 1
            } else if j > 0, (i == 0 || table[i][j - 1] >= table[i - 1][j]) {
                stack.append(CodeDiffLine(kind: .added, text: b[j - 1]))
                j -= 1
            } else if i > 0 {
                stack.append(CodeDiffLine(kind: .removed, text: a[i - 1]))
                i -= 1
            }
        }
        return stack.reversed()
    }

    private static func lcsTable(_ a: [String], _ b: [String]) -> [[Int]] {
        var t = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 1...a.count {
            for j in 1...b.count {
                if a[i - 1] == b[j - 1] {
                    t[i][j] = t[i - 1][j - 1] + 1
                } else {
                    t[i][j] = max(t[i - 1][j], t[i][j - 1])
                }
            }
        }
        return t
    }

    /// Myers O(ND). Returns `nil` when D exceeds `myersMaxD` (caller uses replace hunk).
    private static func myersDiff(_ a: [String], _ b: [String]) -> [CodeDiffLine]? {
        let n = a.count
        let m = b.count
        let maxD = min(n + m, myersMaxD)
        let offset = maxD
        var v = Array(repeating: 0, count: 2 * maxD + 1)
        v[offset + 1] = 0
        var trace: [[Int]] = []
        trace.reserveCapacity(maxD + 1)

        var done = false
        for d in 0...maxD {
            for k in stride(from: -d, through: d, by: 2) {
                let idx = k + offset
                var x: Int
                if k == -d || (k != d && v[idx - 1] < v[idx + 1]) {
                    x = v[idx + 1]
                } else {
                    x = v[idx - 1] + 1
                }
                var y = x - k
                while x < n, y < m, a[x] == b[y] {
                    x += 1
                    y += 1
                }
                v[idx] = x
                if x >= n, y >= m {
                    done = true
                    break
                }
            }
            trace.append(v)
            if done { break }
            if d == maxD, !done {
                return nil
            }
        }
        guard done else { return nil }
        return backtrackMyers(a: a, b: b, trace: trace, offset: offset)
    }

    private static func backtrackMyers(a: [String],
                                       b: [String],
                                       trace: [[Int]],
                                       offset: Int) -> [CodeDiffLine] {
        var x = a.count
        var y = b.count
        var edits: [CodeDiffLine] = []
        edits.reserveCapacity(a.count + b.count)

        for d in stride(from: trace.count - 1, through: 0, by: -1) {
            let v = trace[d]
            let k = x - y
            let prevK: Int
            if k == -d || (k != d && v[k - 1 + offset] < v[k + 1 + offset]) {
                prevK = k + 1
            } else {
                prevK = k - 1
            }
            let prevX = v[prevK + offset]
            let prevY = prevX - prevK

            while x > prevX, y > prevY {
                x -= 1
                y -= 1
                edits.append(CodeDiffLine(kind: .unchanged, text: a[x]))
            }
            if d == 0 { break }
            if x > prevX {
                x -= 1
                edits.append(CodeDiffLine(kind: .removed, text: a[x]))
            } else if y > prevY {
                y -= 1
                edits.append(CodeDiffLine(kind: .added, text: b[y]))
            }
        }
        return edits.reversed()
    }
}
