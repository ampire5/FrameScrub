import AppKit
import FrameScrubCore
import InfoPanelKit

/// The key cheat sheet (`?`): the bindings in effect, by section, in columns on a glass backdrop in the middle of
/// the video. Never takes clicks; `?` or Esc closes it.
final class KeyHelpView: NSView {
    private let backdrop = GlassBackdrop(cornerRadius: 14)
    /// Darkens the glass: dense small text must read over a bright frame.
    private let dim = NSView()
    private let columns = NSStackView()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop)
        dim.wantsLayer = true
        dim.layer?.backgroundColor = NSColor(white: 0, alpha: 0.55).cgColor
        dim.layer?.cornerRadius = 14
        dim.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dim)
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.translatesAutoresizingMaskIntoConstraints = false
        addSubview(columns)
        NSLayoutConstraint.activate([
            columns.centerXAnchor.constraint(equalTo: centerXAnchor),
            columns.centerYAnchor.constraint(equalTo: centerYAnchor),
            backdrop.leadingAnchor.constraint(equalTo: columns.leadingAnchor, constant: -20),
            backdrop.trailingAnchor.constraint(equalTo: columns.trailingAnchor, constant: 22),
            backdrop.topAnchor.constraint(equalTo: columns.topAnchor, constant: -16),
            backdrop.bottomAnchor.constraint(equalTo: columns.bottomAnchor, constant: 18),
            dim.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            dim.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            dim.topAnchor.constraint(equalTo: backdrop.topAnchor),
            dim.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var isShown: Bool { !isHidden }

    /// Lays the sheet out in three columns, or two, at the largest text size (12…9 pt) that fits the view.
    func show(_ map: InputMap) {
        let sections = KeyHelp.sections(for: map)
        let room = CGSize(width: bounds.width - 66, height: bounds.height - 58)   // the backdrop's padding and a margin
        layout: for size in stride(from: 12.0, through: 9, by: -1) {
            for count in [3, 2] {
                fill(sections, columns: count, size: size)
                let needed = columns.fittingSize
                if needed.width <= room.width && needed.height <= room.height { break layout }
            }
        }
        isHidden = false
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; animator().alphaValue = 1 }
    }

    private func fill(_ sections: [(section: KeyHelp.Section, entries: [KeyHelp.Entry])], columns count: Int, size: CGFloat) {
        columns.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for group in Self.balance(sections, into: count) {
            columns.addArrangedSubview(Self.grid(group, size: size))
        }
        columns.spacing = size * 2.3
        columns.layoutSubtreeIfNeeded()
    }

    func hide() { isHidden = true }

    /// Splits whole sections, in order, into `count` columns so that the longest column is as short as possible.
    private static func balance(_ sections: [(section: KeyHelp.Section, entries: [KeyHelp.Entry])],
                                into count: Int) -> [[(section: KeyHelp.Section, entries: [KeyHelp.Entry])]] {
        let sizes = sections.map { $0.entries.count + 2 }   // a heading takes about two rows
        func splits(_ start: Int, _ columns: Int) -> (longest: Int, cuts: [Int]) {
            let rest = sizes[start...].reduce(0, +)
            guard columns > 1, start < sizes.count - 1 else { return (rest, []) }
            var best = (longest: rest, cuts: [Int]())
            var first = 0
            for end in start + 1 ..< sizes.count {
                first += sizes[end - 1]
                let tail = splits(end, columns - 1)
                let longest = max(first, tail.longest)
                if longest < best.longest { best = (longest, [end] + tail.cuts) }
            }
            return best
        }
        let bounds = [0] + splits(0, count).cuts + [sections.count]
        return zip(bounds, bounds.dropFirst()).map { Array(sections[$0 ..< $1]) }
    }

    /// One column: per section a heading row, then rows of keys (right-aligned) and what they do.
    private static func grid(_ sections: [(section: KeyHelp.Section, entries: [KeyHelp.Entry])], size: CGFloat) -> NSGridView {
        func label(_ text: String, font: NSFont, alpha: CGFloat) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = font
            label.textColor = NSColor(white: 1, alpha: alpha)
            label.lineBreakMode = .byClipping
            return label
        }
        let grid = NSGridView()
        grid.columnSpacing = size
        grid.rowSpacing = size * 0.25
        var headings: [Int] = []
        for (i, group) in sections.enumerated() {
            let heading = label(group.section.title.uppercased(), font: .systemFont(ofSize: size - 1.5, weight: .bold), alpha: 0.55)
            let row = grid.addRow(with: [heading, NSGridCell.emptyContentView])
            row.mergeCells(in: NSRange(location: 0, length: 2))
            row.topPadding = i > 0 ? size * 0.8 : 0
            row.bottomPadding = size * 0.1
            headings.append(grid.numberOfRows - 1)
            for entry in group.entries {
                grid.addRow(with: [label(entry.keys.joined(separator: "  "), font: .systemFont(ofSize: size, weight: .semibold), alpha: 1),
                                   label(entry.action, font: .systemFont(ofSize: size), alpha: 0.8)])
            }
        }
        grid.column(at: 0).xPlacement = .trailing
        for index in headings { grid.cell(atColumnIndex: 0, rowIndex: index).xPlacement = .leading }
        grid.setContentHuggingPriority(.required, for: .vertical)   // a shorter column must not spread its rows
        grid.setContentCompressionResistancePriority(.required, for: .vertical)
        return grid
    }
}
