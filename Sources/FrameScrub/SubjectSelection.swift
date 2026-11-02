import Foundation

/// "Main people" (spike): of a mask's people, only the big ones stay. The mask (8-bit, ≥ 128 counted as a person) is cut
/// into connected regions; a region stays when it is at least `keep` of the largest one, or `stay` of it when it stayed
/// in the frame before (so a person close to the line does not blink); the rest, with its soft edge, is cleared outside
/// the kept regions grown by `grow` px. On a runway: the walking models stay, the audience's heads at the edges and a
/// model far down the runway go. About 1 ms for a 512×288 mask (M4 Max).
struct SubjectSelection {
    static let keep = 0.25, stay = 0.12
    static let grow = 6

    private var kept: [Bool] = []

    /// Forgets the frame before (a seek, a cut, another file).
    mutating func reset() { kept = [] }

    /// `mask` (w×h, rows top first) with only the main people; `continuous`: the frame follows the one before.
    mutating func apply(_ mask: inout [UInt8], _ w: Int, _ h: Int, continuous: Bool) {
        let n = w * h
        guard mask.count == n, n > 0 else { return }
        if !continuous || kept.count != n { kept = [] }
        // connected regions (4-neighbours) of the pixels ≥ 128
        var label = [Int32](repeating: -1, count: n)
        var areas: [Int] = [], touches: [Bool] = []
        var stack: [Int] = []
        for start in 0..<n where mask[start] >= 128 && label[start] < 0 {
            let id = Int32(areas.count)
            var area = 0, touched = false
            label[start] = id
            stack.append(start)
            while let i = stack.popLast() {
                area += 1
                if !kept.isEmpty, kept[i] { touched = true }
                let x = i % w, y = i / w
                if x > 0, mask[i - 1] >= 128, label[i - 1] < 0 { label[i - 1] = id; stack.append(i - 1) }
                if x < w - 1, mask[i + 1] >= 128, label[i + 1] < 0 { label[i + 1] = id; stack.append(i + 1) }
                if y > 0, mask[i - w] >= 128, label[i - w] < 0 { label[i - w] = id; stack.append(i - w) }
                if y < h - 1, mask[i + w] >= 128, label[i + w] < 0 { label[i + w] = id; stack.append(i + w) }
            }
            areas.append(area)
            touches.append(touched)
        }
        guard let largest = areas.max(), areas.count > 1 else {
            kept = label.map { $0 >= 0 }
            return
        }
        let stays = areas.indices.map { k in
            Double(areas[k]) >= Self.keep * Double(largest) || (touches[k] && Double(areas[k]) >= Self.stay * Double(largest))
        }
        var keepNow = [Bool](repeating: false, count: n)
        for i in 0..<n where label[i] >= 0 && stays[Int(label[i])] { keepNow[i] = true }
        kept = keepNow
        // the kept regions grown by `grow` px (separable max), so their soft edge stays; everything else cleared
        var row = [Bool](repeating: false, count: n)
        for y in 0..<h {
            var last = Int.min / 2
            for x in 0..<w { if keepNow[y * w + x] { last = x }; if x - last <= Self.grow { row[y * w + x] = true } }
            last = Int.max / 2
            for x in stride(from: w - 1, through: 0, by: -1) { if keepNow[y * w + x] { last = x }; if last - x <= Self.grow { row[y * w + x] = true } }
        }
        var grown = [Bool](repeating: false, count: n)
        for x in 0..<w {
            var last = Int.min / 2
            for y in 0..<h { if row[y * w + x] { last = y }; if y - last <= Self.grow { grown[y * w + x] = true } }
            last = Int.max / 2
            for y in stride(from: h - 1, through: 0, by: -1) { if row[y * w + x] { last = y }; if last - y <= Self.grow { grown[y * w + x] = true } }
        }
        for i in 0..<n where !grown[i] { mask[i] = 0 }
    }
}
