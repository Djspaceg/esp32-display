import AppKit
import SwiftUI

/// Where a dragged saved network lands, apart from any view so a test can
/// check every direction.
///
/// The offsets mean what `NSTableView` and SwiftUI's `onMove` mean by them:
/// `row` is the gap a row is dropped into, counted before the move, so 0 is
/// above the first row and `count` is below the last.
enum WifiNetworkReorder {
    /// The drop the table shows and performs for one it proposed.
    ///
    /// A table proposes "on" a row while the pointer is over the row's middle
    /// and "above" one near its edges. Saying no to "on" hid the indicator
    /// whenever the pointer crossed a row's middle and brought it back at the
    /// edge - the flicker - so "on" is turned into the gap above that row, or
    /// below it for the lower half, and every position shows a line.
    static func retargeted(
        row: Int, dropOperation: NSTableView.DropOperation, lowerHalf: Bool,
        rowCount: Int
    ) -> Int {
        let gap = dropOperation == .on && lowerHalf ? row + 1 : row
        return min(max(gap, 0), rowCount)
    }

    /// The order after dropping the rows at `rows` into gap `row`.
    static func reordered(_ names: [String], dragging rows: IndexSet, to row: Int) -> [String] {
        PanelManager.moving(names, fromOffsets: rows, toOffset: row)
    }
}

/// The saved-network rows: an `NSTableView`, for its own drag-and-drop
/// reorder, selection and Delete key.
///
/// A SwiftUI `List` nested in the grouped form reordered only intermittently
/// - a row could move down but the bottom one never up - and its drop
/// indicator flickered, because the list resized itself to its content while
/// the drag was under way. Here the height is the row count times a fixed
/// row height, the rows are not rebuilt while a drag is in progress, and the
/// drop target is always a gap (`WifiNetworkReorder.retargeted`).
struct WifiNetworkTable: NSViewRepresentable {
    struct Row: Equatable {
        var ssid: String
        var isOpen: Bool
    }

    static let rowHeight: CGFloat = 28

    var rows: [Row]
    @Binding var selection: String?
    /// The add or edit form is open: the pencils are greyed out.
    var editingDisabled: Bool
    /// A drag dropped the rows at the first offsets into the gap at the
    /// second, as `onMove` would be told.
    var onMove: (IndexSet, Int) -> Void
    var onEdit: (String) -> Void
    /// The Delete key, on a selected row.
    var onDelete: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let table = Coordinator.makeTable(coordinator)
        let scroll = PassThroughScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .none
        coordinator.table = table
        update(coordinator)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        update(context.coordinator)
        // The one column is the table's width, so the pencil sits at the
        // right edge whatever width the pane is.
        context.coordinator.table?.sizeLastColumnToFit()
    }

    private func update(_ coordinator: Coordinator) {
        coordinator.onMove = onMove
        coordinator.onEdit = onEdit
        coordinator.onDelete = onDelete
        coordinator.onSelect = { selection = $0 }
        coordinator.apply(.init(rows: rows, selection: selection, editingDisabled: editingDisabled))
    }

    /// The table's data source and delegate.
    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        struct State: Equatable {
            var rows: [Row]
            var selection: String?
            var editingDisabled: Bool
        }

        static let rowType = NSPasteboard.PasteboardType("com.espdisplay.sender.saved-network-row")

        weak var table: NSTableView?
        var onMove: (IndexSet, Int) -> Void = { _, _ in }
        var onEdit: (String) -> Void = { _ in }
        var onDelete: () -> Void = {}
        var onSelect: (String?) -> Void = { _ in }

        private(set) var state = State(rows: [], selection: nil, editingDisabled: false)
        /// A state that arrived while a drag was under way, applied when it ends.
        private var deferred: State?
        private(set) var isDragging = false
        /// How many times the rows were rebuilt, for the test that a drag
        /// does not rebuild them under the pointer.
        private(set) var reloadCount = 0
        /// Set while the table's selection is being set to match `state`, so
        /// that is not reported back as the user's choice.
        private var applyingSelection = false

        static func makeTable(_ coordinator: Coordinator) -> NSTableView {
            let table = DeletingTableView()
            table.onDelete = { [weak coordinator] in coordinator?.onDelete() }
            let column = NSTableColumn(identifier: .init("network"))
            column.resizingMask = .autoresizingMask
            table.addTableColumn(column)
            table.headerView = nil
            table.style = .plain
            table.rowHeight = WifiNetworkTable.rowHeight
            table.intercellSpacing = NSSize(width: 0, height: 0)
            table.backgroundColor = .clear
            table.allowsMultipleSelection = false
            table.allowsEmptySelection = true
            table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
            table.focusRingType = .none
            table.draggingDestinationFeedbackStyle = .regular
            table.registerForDraggedTypes([rowType])
            table.setDraggingSourceOperationMask(.move, forLocal: true)
            table.dataSource = coordinator
            table.delegate = coordinator
            coordinator.table = table
            return table
        }

        /// Show `next`, unless a drag is under way: rebuilding the rows under
        /// the pointer is what makes a drop indicator flicker, so the state
        /// waits for the drag to end.
        func apply(_ next: State) {
            if isDragging {
                deferred = next
                return
            }
            let rowsChanged = next.rows != state.rows
                || next.editingDisabled != state.editingDisabled
            state = next
            guard let table else { return }
            if rowsChanged {
                // A reload that trims the selection is not the user's choice.
                applyingSelection = true
                table.reloadData()
                applyingSelection = false
                reloadCount += 1
            }
            let wanted = next.selection.flatMap { ssid in
                next.rows.firstIndex { $0.ssid == ssid }
            }
            if table.selectedRow != (wanted ?? -1) {
                applyingSelection = true
                if let wanted {
                    table.selectRowIndexes([wanted], byExtendingSelection: false)
                } else {
                    table.deselectAll(nil)
                }
                applyingSelection = false
            }
        }

        /// A drop into gap `row`, as the table's drop handler performs it.
        func performDrop(rows source: IndexSet, to row: Int) {
            guard !source.isEmpty else { return }
            onMove(source, row)
        }

        // MARK: data source

        func numberOfRows(in tableView: NSTableView) -> Int { state.rows.count }

        /// The dragged network by name, not by row: the list can change
        /// while the drag is under way (`deferred`), and a row number taken
        /// at the start would then move a different network.
        func tableView(
            _ tableView: NSTableView, pasteboardWriterForRow row: Int
        ) -> (any NSPasteboardWriting)? {
            guard state.rows.indices.contains(row) else { return nil }
            let item = NSPasteboardItem()
            item.setString(state.rows[row].ssid, forType: Self.rowType)
            return item
        }

        func tableView(
            _ tableView: NSTableView, draggingSession session: NSDraggingSession,
            willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet
        ) {
            isDragging = true
        }

        func tableView(
            _ tableView: NSTableView, draggingSession session: NSDraggingSession,
            endedAt screenPoint: NSPoint, operation: NSDragOperation
        ) {
            endDrag()
        }

        /// The drag is over, dropped or not: the state that arrived meanwhile
        /// - the new order, above all - is shown now.
        func endDrag() {
            isDragging = false
            if let deferred {
                self.deferred = nil
                apply(deferred)
            }
        }

        /// Marks a drag as under way, for tests; a real one starts in
        /// `draggingSession(_:willBeginAt:forRowIndexes:)`.
        func beginDrag() { isDragging = true }

        func tableView(
            _ tableView: NSTableView, validateDrop info: any NSDraggingInfo,
            proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation
        ) -> NSDragOperation {
            // Only this table's own rows are reordered here.
            guard (info.draggingSource as AnyObject?) === tableView else { return [] }
            var lowerHalf = false
            if dropOperation == .on, row >= 0, row < tableView.numberOfRows {
                let point = tableView.convert(info.draggingLocation, from: nil)
                lowerHalf = point.y > tableView.rect(ofRow: row).midY
            }
            let gap = WifiNetworkReorder.retargeted(
                row: row, dropOperation: dropOperation, lowerHalf: lowerHalf,
                rowCount: tableView.numberOfRows)
            tableView.setDropRow(gap, dropOperation: .above)
            return .move
        }

        func tableView(
            _ tableView: NSTableView, acceptDrop info: any NSDraggingInfo,
            row: Int, dropOperation: NSTableView.DropOperation
        ) -> Bool {
            let names = (info.draggingPasteboard.pasteboardItems ?? []).compactMap {
                $0.string(forType: Self.rowType)
            }
            return acceptDrop(of: names, to: row)
        }

        /// The drop of the networks named `names` into gap `row` of the rows
        /// the table shows. Refused when the list changed during the drag:
        /// the gap was chosen among rows that are no longer the list.
        func acceptDrop(of names: [String], to row: Int) -> Bool {
            if let deferred, deferred.rows != state.rows { return false }
            let source = IndexSet(names.compactMap { name in
                state.rows.firstIndex { $0.ssid == name }
            })
            guard !source.isEmpty else { return false }
            performDrop(rows: source, to: row)
            return true
        }

        // MARK: delegate

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !applyingSelection, let table else { return }
            let row = table.selectedRow
            let ssid = state.rows.indices.contains(row) ? state.rows[row].ssid : nil
            state.selection = ssid
            onSelect(ssid)
        }

        /// A separator under every row but the last, which the footer's own
        /// divider follows - a grid would double that line and draw rules in
        /// an empty list.
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view = SeparatedRowView()
            view.showsSeparator = row < state.rows.count - 1
            return view
        }

        func tableView(
            _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
        ) -> NSView? {
            guard state.rows.indices.contains(row) else { return nil }
            let cell = (tableView.makeView(withIdentifier: NetworkCell.identifier, owner: nil)
                as? NetworkCell) ?? NetworkCell()
            cell.show(state.rows[row], index: row, editingDisabled: state.editingDisabled,
                      target: self, action: #selector(editClicked(_:)))
            return cell
        }

        @objc func editClicked(_ sender: NSButton) {
            guard let ssid = sender.identifier?.rawValue else { return }
            onEdit(ssid)
        }
    }
}

/// One saved network: its slot, its name, "Open" when it has no password,
/// and the pencil that edits it.
final class NetworkCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("saved-network-cell")

    let slotLabel = NSTextField(labelWithString: "")
    let nameLabel = NSTextField(labelWithString: "")
    let openLabel = NSTextField(labelWithString: "Open")
    let editButton = NSButton()

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        slotLabel.textColor = .secondaryLabelColor
        slotLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        openLabel.textColor = .secondaryLabelColor
        openLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        editButton.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: "Edit")
        editButton.isBordered = false
        editButton.imagePosition = .imageOnly
        editButton.setButtonType(.momentaryPushIn)
        textField = nameLabel

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let stack = NSStackView(views: [slotLabel, nameLabel, openLabel, spacer, editButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            slotLabel.widthAnchor.constraint(equalToConstant: 64),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(
        _ row: WifiNetworkTable.Row, index: Int, editingDisabled: Bool,
        target: AnyObject, action: Selector
    ) {
        let slots = WifiPresetSlotPlan.capacity
        let copied = index < slots
        // Words rather than a dash past the tenth row, which beside the
        // footer's minus would read as a control.
        slotLabel.stringValue = copied ? "Slot \(index + 1)" : "Not copied"
        slotLabel.font = copied
            ? .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            : .systemFont(ofSize: NSFont.smallSystemFontSize)
        slotLabel.toolTip = copied
            ? "The preset slot this network fills on every display"
            : "Displays have \(slots) preset slots; drag this network up to copy it"
        nameLabel.stringValue = row.ssid
        nameLabel.textColor = copied ? .labelColor : .secondaryLabelColor
        openLabel.isHidden = !row.isOpen
        editButton.identifier = NSUserInterfaceItemIdentifier(row.ssid)
        editButton.target = target
        editButton.action = action
        editButton.isEnabled = !editingDisabled
        editButton.toolTip = "Edit \"\(row.ssid)\""
        editButton.setAccessibilityLabel("Edit \(row.ssid)")
    }
}

final class SeparatedRowView: NSTableRowView {
    var showsSeparator = true

    override func drawSeparator(in dirtyRect: NSRect) {
        guard showsSeparator else { return }
        NSColor.separatorColor.setFill()
        NSRect(x: 10, y: bounds.maxY - 1, width: bounds.width - 20, height: 1).fill()
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        drawSeparator(in: dirtyRect)
    }
}

/// The table's Delete key removes the selected network, after asking.
final class DeletingTableView: NSTableView {
    var onDelete: () -> Void = {}

    override func keyDown(with event: NSEvent) {
        // Delete and Forward Delete.
        if event.keyCode == 51 || event.keyCode == 117 {
            onDelete()
            return
        }
        super.keyDown(with: event)
    }
}

/// Holds the table at its full height without scrolling, and hands the
/// scroll wheel on, so the Settings pane scrolls while the pointer is over
/// the list.
final class PassThroughScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}
