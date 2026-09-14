import AppKit

func colorMenuDot(hex: String?) -> NSImage {
    NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
        let dot = NSBezierPath(ovalIn: NSRect(x: 3, y: 3, width: 10, height: 10))
        if let hex, let rgb = UInt32(hex.dropFirst(), radix: 16) {
            NSColor(
                srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                green: CGFloat((rgb >> 8) & 255) / 255,
                blue: CGFloat(rgb & 255) / 255, alpha: 1
            ).setFill()
            dot.fill()
        } else {
            let colors: [NSColor] = [
                .systemRed, .systemOrange, .systemYellow, .systemGreen,
                .systemBlue, .systemPurple,
            ]
            let center = NSPoint(x: 8, y: 8)
            for (index, color) in colors.enumerated() {
                let wedge = NSBezierPath()
                wedge.move(to: center)
                wedge.appendArc(
                    withCenter: center, radius: 5,
                    startAngle: CGFloat(index) * 60 + 90,
                    endAngle: CGFloat(index + 1) * 60 + 90)
                wedge.close()
                color.setFill()
                wedge.fill()
            }
        }
        NSColor.labelColor.withAlphaComponent(0.25).setStroke()
        dot.lineWidth = 0.5
        dot.stroke()
        return true
    }
}

private final class ThemeColorWell: NSColorWell {
    override var color: NSColor {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let pill = NSBezierPath(
            roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        color.setFill()
        pill.fill()
    }

    override func drawFocusRingMask() {
        NSBezierPath(
            roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2
        ).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }
}

private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class JoinedResolutionControls: NSStackView {
    override func draw(_ dirtyRect: NSRect) {
        let outline = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        NSColor.quaternaryLabelColor.setFill()
        outline.fill()
        NSColor.separatorColor.setStroke()
        outline.lineWidth = 0.5
        outline.stroke()
        if let button = arrangedSubviews.last, !button.isHidden {
            NSColor.separatorColor.setFill()
            NSRect(x: button.frame.minX, y: 4, width: 1, height: bounds.height - 8).fill()
        }
    }

    override func layout() {
        super.layout()
        needsDisplay = true
    }
}

private final class PersistentScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { false }
}

private final class OverflowScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        let documentHeight = documentView?.frame.height ?? 0
        verticalScrollElasticity = documentHeight > contentView.bounds.height ? .allowed : .none
        super.scrollWheel(with: event)
    }
}

// Every view in this controller is AppKit. Calendar text is always plain text.
final class EditorViewController: NSViewController, NSMenuItemValidation, NSTableViewDataSource,
    NSTableViewDelegate,
    NSTextFieldDelegate
{
    var onChange: (([String: Any]) -> Void)?
    var onInclude: ((String, Bool) -> Void)?
    var onExport: ((Bool, String?) -> Void)?
    var canExport: (() -> Bool)?
    private(set) var editor: [String: Any] = [:]
    private(set) var events: [[String: Any]] = []
    private var suggestions: [[String: Any]] = []
    let preview = NSImageView()
    let tabs = NSTabView()
    let summary = NSTextField(labelWithString: "Loading calendar…")
    let warning = NSTextField(wrappingLabelWithString: "")
    private var warningScroll: NSScrollView!
    let error = NSTextField(wrappingLabelWithString: "")
    let table = NSTableView()
    let details = NSTextView()
    let mode = NSSegmentedControl()
    let theme = NSSegmentedControl()
    let colorTheme = NSPopUpButton()
    let calendarColors = NSButton(
        checkboxWithTitle: "Use calendar colors", target: nil, action: nil)
    private var customColorFields: NSStackView!
    private(set) var colorWells: [String: NSColorWell] = [:]
    private var customColors: [String: [String: String]] = [:]
    let eventStyle = NSSegmentedControl()
    let resolution = NSPopUpButton()
    private var customSizeAlert: NSAlert?
    private let customWidth = NSTextField()
    private let customHeight = NSTextField()
    let displayResolution = NSButton(title: "Use display resolution", target: nil, action: nil)
    let displaySizes = NSTextField(wrappingLabelWithString: "")
    let name = NSTextField()
    let start = NSDatePicker()
    let end = NSDatePicker()
    let month = NSDatePicker()
    let showTitle = NSButton(checkboxWithTitle: "Show title", target: nil, action: nil)
    let rooms = NSButton(checkboxWithTitle: "Show locations", target: nil, action: nil)
    let includeWeekends = NSButton(
        checkboxWithTitle: "Include Saturdays and Sundays", target: nil, action: nil)
    let iconSpace = NSButton(
        checkboxWithTitle: "Leave room for desktop icons", target: nil, action: nil)
    let exportMenu = NSPopUpButton(frame: .zero, pullsDown: true)
    let appearanceToggle = NSButton(checkboxWithTitle: "Appearance", target: nil, action: nil)
    private(set) var appearanceFields: NSStackView!
    private var moduleFields: NSStackView!
    private var monthField: NSStackView!
    private let suggestionList = NSStackView()
    private var suggestionSignature = ""
    private let dateFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func stack(_ views: [NSView], vertical: Bool = true, spacing: CGFloat = 10)
        -> NSStackView
    {
        let stack = NSStackView(views: views)
        stack.orientation = vertical ? .vertical : .horizontal
        stack.alignment = vertical ? .leading : .centerY
        stack.spacing = spacing
        return stack
    }
    private func field(_ title: String, _ control: NSView) -> NSStackView {
        control.setAccessibilityLabel(title)
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        let stack = Self.stack([label, control], spacing: 5)
        control.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }
    private func dateField(_ title: String, _ picker: NSDatePicker) -> NSStackView {
        // Keep a native text-field bezel while giving the date segments a larger inset.
        let container = NSView()
        let bezel = NSTextField()
        bezel.isEditable = false
        bezel.isSelectable = false
        bezel.setAccessibilityElement(false)
        picker.isBezeled = false
        picker.isBordered = false
        picker.drawsBackground = false
        for view in [bezel, picker] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            bezel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bezel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -21),
            bezel.topAnchor.constraint(equalTo: container.topAnchor),
            bezel.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            picker.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            picker.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            picker.topAnchor.constraint(equalTo: container.topAnchor),
            picker.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        picker.setAccessibilityLabel(title)
        return field(title, container)
    }
    private func scroll(_ content: NSView) -> NSScrollView {
        let document = FlippedDocumentView()
        document.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        let scroll = OverflowScrollView()
        scroll.autohidesScrollers = true
        scroll.hasVerticalScroller = true
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .none
        scroll.drawsBackground = false
        scroll.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.topAnchor.constraint(equalTo: document.topAnchor, constant: 12),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -12),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -12),
        ])
        return scroll
    }
    override func loadView() {
        view = NSView()
        for (control, labels) in [
            (mode, ["Module", "Month"]),
            (theme, ["System", "Light", "Dark"]), (eventStyle, ["Text", "Boxes"]),
        ] {
            control.segmentCount = labels.count
            control.trackingMode = .selectOne
            control.segmentStyle = .rounded
            control.segmentDistribution = .fillEqually
            for (index, label) in labels.enumerated() {
                control.setLabel(label, forSegment: index)
            }
        }
        for control: NSControl in [mode, theme, colorTheme, eventStyle, resolution] {
            control.target = self
            control.action = #selector(changeControl(_:))
        }
        name.delegate = self
        name.setAccessibilityIdentifier("module-name")
        for picker in [start, end, month] {
            picker.datePickerStyle = .textFieldAndStepper
            picker.datePickerElements = picker === month ? .yearMonth : .yearMonthDay
            picker.calendar = Calendar(identifier: .gregorian)
            picker.timeZone = TimeZone(secondsFromGMT: 0)
            picker.target = self
            picker.action = #selector(changeControl(_:))
        }
        for control in [showTitle, rooms, includeWeekends, iconSpace, calendarColors] {
            control.target = self
            control.action = #selector(changeControl(_:))
        }
        for picker in [start, end] {
            picker.controlSize = .small
            picker.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        }
        let dateRange = Self.stack(
            [dateField("First day", start), dateField("Last day", end)],
            vertical: false, spacing: 8)
        dateRange.distribution = .fillEqually
        moduleFields = Self.stack([field("Module name", name), dateRange])
        monthField = field("Month", month)
        exportMenu.addItem(withTitle: "Export")
        for (title, action) in [
            ("PNG · Current appearance…", #selector(exportPNG)),
            ("PNG · Light…", #selector(exportLightPNG)),
            ("PNG · Dark…", #selector(exportDarkPNG)),
            ("HEIC · Light and dark…", #selector(exportHEIC)),
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            exportMenu.menu?.addItem(item)
        }
        exportMenu.setAccessibilityLabel("Export wallpaper")
        displaySizes.font = .systemFont(ofSize: 11)
        displaySizes.textColor = .secondaryLabelColor
        displaySizes.isHidden = true
        let lightHeading = NSTextField(labelWithString: "Light")
        let darkHeading = NSTextField(labelWithString: "Dark")
        for heading in [lightHeading, darkHeading] {
            heading.font = .systemFont(ofSize: 11, weight: .medium)
            heading.textColor = .secondaryLabelColor
        }
        var colorRows: [[NSView]] = [[NSGridCell.emptyContentView, lightHeading, darkHeading]]
        for (key, title) in [("bg", "Background"), ("text", "Text"), ("accent", "Accent")] {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 12)
            var row: [NSView] = [label]
            for appearance in ["light", "dark"] {
                let well = ThemeColorWell()
                well.colorWellStyle = .minimal
                well.controlSize = .small
                well.isBordered = false
                if #available(macOS 14.0, *) { well.supportsAlpha = false }
                well.widthAnchor.constraint(equalToConstant: 32).isActive = true
                well.heightAnchor.constraint(equalToConstant: 20).isActive = true
                well.target = self
                well.action = #selector(changeColor(_:))
                well.setAccessibilityLabel("\(appearance.capitalized) \(title.lowercased()) color")
                colorWells["\(appearance).\(key)"] = well
                row.append(well)
            }
            colorRows.append(row)
        }
        let colorGrid = NSGridView(views: colorRows)
        colorGrid.columnSpacing = 24
        colorGrid.rowSpacing = 8
        colorGrid.yPlacement = .center
        colorGrid.column(at: 0).xPlacement = .leading
        for index in 1...2 {
            colorGrid.column(at: index).width = 32
            colorGrid.column(at: index).xPlacement = .center
        }
        customColorFields = Self.stack([colorGrid])
        colorGrid.widthAnchor.constraint(equalTo: customColorFields.widthAnchor).isActive = true
        customColorFields.isHidden = true
        for control: NSControl in [resolution, displayResolution] {
            control.controlSize = .small
            control.font = .systemFont(ofSize: NSFont.systemFontSize)
            control.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        resolution.isBordered = false
        displayResolution.isBordered = false
        displayResolution.setButtonType(.momentaryChange)
        displayResolution.contentTintColor = .labelColor
        let resolutionRow = JoinedResolutionControls(views: [resolution, displayResolution])
        resolutionRow.orientation = .horizontal
        resolutionRow.alignment = .centerY
        resolutionRow.distribution = .fillEqually
        resolutionRow.spacing = 0
        resolutionRow.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        let imageSizeFields = Self.stack([resolutionRow, displaySizes], spacing: 6)
        resolutionRow.widthAnchor.constraint(equalTo: imageSizeFields.widthAnchor).isActive = true
        let colorThemeRow = Self.stack([colorTheme, calendarColors], vertical: false, spacing: 6)
        colorTheme.setAccessibilityLabel("Color theme")
        calendarColors.setContentHuggingPriority(.required, for: .horizontal)
        calendarColors.setContentCompressionResistancePriority(.required, for: .horizontal)
        appearanceFields = Self.stack(
            [
                field("Image size", imageSizeFields),
                field("Preview appearance", theme),
                field("Color theme", colorThemeRow),
                customColorFields!,
                field("Event style", eventStyle),
                showTitle,
                rooms, iconSpace,
            ], spacing: 14)
        appearanceFields.isHidden = true
        displaySizes.widthAnchor.constraint(equalTo: resolutionRow.widthAnchor).isActive = true
        appearanceToggle.setButtonType(.onOff)
        appearanceToggle.isBordered = false
        appearanceToggle.image = NSImage(
            systemSymbolName: "chevron.right", accessibilityDescription: nil)
        appearanceToggle.imagePosition = .imageLeft
        appearanceToggle.alignment = .left
        appearanceToggle.title = "Appearance"
        appearanceToggle.font = .systemFont(ofSize: 13, weight: .semibold)
        appearanceToggle.target = self
        appearanceToggle.action = #selector(toggleAppearance)
        appearanceToggle.setAccessibilityLabel("Show appearance options")
        let heading = NSTextField(labelWithString: "Schedule")
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        let separator = NSBox()
        separator.boxType = .separator
        let settings = Self.stack(
            [
                heading, field("View", mode), moduleFields, monthField,
                includeWeekends, separator, appearanceToggle,
                appearanceFields!,
            ], spacing: 18)
        for child in settings.arrangedSubviews {
            child.widthAnchor.constraint(equalTo: settings.widthAnchor).isActive = true
        }
        for group in [moduleFields!, appearanceFields!] {
            for child in group.arrangedSubviews {
                child.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
            }
        }
        let sidebar = scroll(settings)
        sidebar.hasVerticalScroller = false
        sidebar.widthAnchor.constraint(equalToConstant: 270).isActive = true

        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.setAccessibilityLabel(
            "Wallpaper preview. Full event information is available in Exclude events.")
        preview.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        preview.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        let previewTab = NSTabViewItem(identifier: "preview")
        previewTab.label = "Preview"
        previewTab.view = preview
        tabs.addTabViewItem(previewTab)

        for (id, title, width) in [
            ("included", "Include", 65.0), ("date", "Date and time", 175.0),
            ("title", "Session", 280.0), ("source", "Calendar", 120.0),
        ] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = id == "included" ? 65 : 80
            table.addTableColumn(column)
        }
        table.delegate = self
        table.dataSource = self
        table.rowHeight = 30
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.setAccessibilityLabel("Calendar events")
        let tableScroll = NSScrollView()
        tableScroll.autohidesScrollers = true
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.hasHorizontalScroller = true
        tableScroll.verticalScroller = PersistentScroller()
        tableScroll.horizontalScroller = PersistentScroller()
        tableScroll.scrollerStyle = .legacy
        details.isEditable = false
        details.isSelectable = true
        details.isRichText = false
        details.font = .systemFont(ofSize: 13)
        details.textContainerInset = NSSize(width: 12, height: 12)
        details.autoresizingMask = [.width]
        details.isHorizontallyResizable = false
        details.textContainer?.widthTracksTextView = true
        details.setAccessibilityLabel("Full event details")
        details.string = "Click on an event to see its full details."
        let detailScroll = NSScrollView()
        detailScroll.autohidesScrollers = true
        detailScroll.documentView = details
        detailScroll.hasVerticalScroller = true
        detailScroll.verticalScroller = PersistentScroller()
        detailScroll.scrollerStyle = .legacy
        let eventSplit = NSSplitView()
        eventSplit.isVertical = false
        eventSplit.dividerStyle = .thin
        eventSplit.addArrangedSubview(tableScroll)
        eventSplit.addArrangedSubview(detailScroll)
        tableScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
        detailScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        let eventView = NSView()
        eventView.autoresizingMask = [.width, .height]
        eventView.addSubview(eventSplit)
        eventSplit.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            eventSplit.topAnchor.constraint(equalTo: eventView.topAnchor),
            eventSplit.bottomAnchor.constraint(equalTo: eventView.bottomAnchor),
            eventSplit.leadingAnchor.constraint(equalTo: eventView.leadingAnchor),
            eventSplit.trailingAnchor.constraint(equalTo: eventView.trailingAnchor),
        ])
        let eventTab = NSTabViewItem(identifier: "events")
        eventTab.label = "Exclude events"
        eventTab.view = eventView
        tabs.addTabViewItem(eventTab)

        suggestionList.orientation = .vertical
        suggestionList.alignment = .leading
        suggestionList.spacing = 18
        let suggestionTab = NSTabViewItem(identifier: "suggestions")
        suggestionTab.label = "Suggested modules"
        suggestionTab.view = scroll(suggestionList)
        tabs.addTabViewItem(suggestionTab)
        summary.font = .systemFont(ofSize: 12)
        summary.textColor = .secondaryLabelColor
        warning.font = .systemFont(ofSize: 12)
        warning.textColor = .secondaryLabelColor
        error.font = .systemFont(ofSize: 12)
        error.textColor = .systemRed
        error.isHidden = true
        warningScroll = scroll(warning)
        warningScroll.heightAnchor.constraint(equalToConstant: 80).isActive = true
        warningScroll.isHidden = true
        let main = Self.stack([error, tabs, summary, warningScroll!])
        main.distribution = .fill
        tabs.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        for child in main.arrangedSubviews {
            child.widthAnchor.constraint(equalTo: main.widthAnchor).isActive = true
        }
        let body = Self.stack([sidebar, main], vertical: false, spacing: 16)
        body.alignment = .top
        view.addSubview(body)
        body.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            body.topAnchor.constraint(equalTo: view.topAnchor),
            body.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sidebar.heightAnchor.constraint(equalTo: body.heightAnchor),
            main.heightAnchor.constraint(equalTo: body.heightAnchor),
            main.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -286),
        ])
        setReady(false)
    }

    func setReady(_ ready: Bool) {
        for control: NSControl in [
            mode, theme, colorTheme, calendarColors, eventStyle, resolution, name, start,
            end, month, showTitle, rooms,
            includeWeekends, iconSpace, exportMenu,
        ] { control.isEnabled = ready }
        for well in colorWells.values { well.isEnabled = ready }
    }
    func showError(_ message: String) {
        error.stringValue = message
        error.isHidden = message.isEmpty
        if !message.isEmpty { NSAccessibility.post(element: error, notification: .valueChanged) }
    }
    func display(_ snapshot: [String: Any]) {
        let selected =
            events.indices.contains(table.selectedRow)
            ? events[table.selectedRow]["uid"] as? String : nil
        editor = snapshot["editor"] as? [String: Any] ?? [:]
        events = snapshot["events"] as? [[String: Any]] ?? []
        mode.selectedSegment = editor["mode"] as? String == "month" ? 1 : 0
        eventStyle.selectedSegment = editor["eventStyle"] as? String == "boxes" ? 1 : 0
        theme.selectedSegment =
            ["system": 0, "light": 1, "dark": 2][editor["theme"] as? String ?? "system"] ?? 0
        colorTheme.removeAllItems()
        for preset in snapshot["colorThemes"] as? [[String: String]] ?? [] {
            colorTheme.addItem(withTitle: preset["name"] ?? "")
            colorTheme.lastItem?.representedObject = preset["id"]
            colorTheme.lastItem?.image = colorMenuDot(hex: preset["accent"])
        }
        colorTheme.addItem(withTitle: "Custom")
        colorTheme.lastItem?.representedObject = "custom"
        colorTheme.lastItem?.image = colorMenuDot(hex: nil)
        let selectedTheme = editor["colorTheme"] as? String ?? "forest"
        colorTheme.select(
            colorTheme.itemArray.first { $0.representedObject as? String == selectedTheme })
        customColorFields.isHidden = selectedTheme != "custom"
        calendarColors.state = editor["calendarColors"] as? Bool == false ? .off : .on
        customColors = snapshot["customColors"] as? [String: [String: String]] ?? [:]
        for (id, well) in colorWells {
            let parts = id.components(separatedBy: ".")
            if let hex = customColors[parts[0]]?[parts[1]],
                let rgb = UInt32(hex.dropFirst(), radix: 16)
            {
                well.color = NSColor(
                    srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                    green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1
                )
            }
        }
        // Keep text being edited intact when a background refresh arrives.
        if name.currentEditor() == nil { name.stringValue = editor["name"] as? String ?? "" }
        for (picker, key) in [(start, "start"), (end, "end"), (month, "month")] {
            let value = editor[key] as? String ?? ""
            if let date = dateFormat.date(from: key == "month" ? value + "-01" : value) {
                picker.dateValue = date
            }
        }
        moduleFields.isHidden = mode.selectedSegment != 0
        monthField.isHidden = mode.selectedSegment != 1
        showTitle.state = editor["showTitle"] as? Bool == true ? .on : .off
        rooms.state = editor["rooms"] as? Bool == true ? .on : .off
        includeWeekends.state = editor["includeWeekends"] as? Bool == true ? .on : .off
        iconSpace.state = editor["iconSpace"] as? Bool == true ? .on : .off
        updateResolutionMenu()
        let included = snapshot["includedCount"] as? Int ?? 0
        summary.stringValue = "\(included) events included · \(events.count - included) excluded"
        let size = "\(editor["width"] as? Int ?? 3024) × \(editor["height"] as? Int ?? 1964)"
        summary.toolTip = "Snapshot \(editor["snapshotDate"] as? String ?? "none") · \(size)"
        warning.stringValue = (snapshot["warnings"] as? [String] ?? []).joined(separator: "\n")
        warningScroll.isHidden = warning.stringValue.isEmpty
        table.reloadData()
        if let selected, let index = events.firstIndex(where: { $0["uid"] as? String == selected })
        {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        showDetails()
        suggestions = snapshot["suggestions"] as? [[String: Any]] ?? []
        let signature =
            (try? JSONSerialization.data(withJSONObject: suggestions, options: [.sortedKeys])
                .base64EncodedString()) ?? ""
        if signature != suggestionSignature {
            suggestionSignature = signature
            reloadSuggestions()
        }
    }
    func updateResolutionMenu() {
        let size = "\(editor["width"] as? Int ?? 3024) × \(editor["height"] as? Int ?? 1964)"
        resolution.removeAllItems()
        for value in [
            size, "3024 × 1964", "3456 × 2234", "2560 × 1440", "3840 × 2160", "1920 × 1080",
        ] where resolution.item(withTitle: value) == nil { resolution.addItem(withTitle: value) }
        resolution.menu?.addItem(.separator())
        resolution.addItem(withTitle: "Custom…")
        resolution.selectItem(withTitle: size)
    }
    private func showCustomSize() {
        updateResolutionMenu()
        guard customSizeAlert == nil, let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Custom image size"
        alert.informativeText = "Enter whole pixels. Width: 1280–7680. Height: 720–4320."
        alert.addButton(withTitle: "Use size")
        alert.addButton(withTitle: "Cancel")
        customWidth.stringValue = String(editor["width"] as? Int ?? 3024)
        customHeight.stringValue = String(editor["height"] as? Int ?? 1964)
        for control in [customWidth, customHeight] { control.delegate = self }
        let fields = Self.stack([
            field("Width in pixels", customWidth), field("Height in pixels", customHeight),
        ])
        fields.frame = NSRect(x: 0, y: 0, width: 280, height: 110)
        alert.accessoryView = fields
        customSizeAlert = alert
        alert.window.initialFirstResponder = customWidth
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.customSizeAlert = nil
            guard response == .alertFirstButtonReturn,
                let width = Int(self.customWidth.stringValue),
                let height = Int(self.customHeight.stringValue),
                (1280...7680).contains(width), (720...4320).contains(height)
            else { return }
            self.onChange?(["width": width, "height": height])
        }
    }
    func controlTextDidChange(_ notification: Notification) {
        guard let alert = customSizeAlert else { return }
        let width = Int(customWidth.stringValue) ?? 0
        let height = Int(customHeight.stringValue) ?? 0
        alert.buttons.first?.isEnabled =
            (1280...7680).contains(width) && (720...4320).contains(height)
    }
    @objc func changeColor(_ sender: NSColorWell) {
        guard let id = colorWells.first(where: { $0.value === sender })?.key,
            let color = sender.color.usingColorSpace(.sRGB)
        else { return }
        let parts = id.components(separatedBy: ".")
        customColors[parts[0]]?[parts[1]] = String(
            format: "#%02x%02x%02x",
            Int((color.redComponent * 255).rounded()), Int((color.greenComponent * 255).rounded()),
            Int((color.blueComponent * 255).rounded()))
        onChange?(["colorTheme": "custom", "customColors": customColors])
    }
    @objc func changeControl(_ sender: NSControl) {
        var patch: [String: Any] = [:]
        switch sender {
        case mode: patch["mode"] = mode.selectedSegment == 1 ? "month" : "module"
        case eventStyle:
            patch["eventStyle"] = eventStyle.selectedSegment == 1 ? "boxes" : "text"
        case theme:
            switch theme.selectedSegment {
            case 1: patch["theme"] = "light"
            case 2: patch["theme"] = "dark"
            default: patch["theme"] = "system"
            }
        case colorTheme:
            let selected = colorTheme.selectedItem?.representedObject as? String ?? "forest"
            patch["colorTheme"] = selected
            if selected == "custom" { patch["customColors"] = customColors }
        case calendarColors: patch["calendarColors"] = calendarColors.state == .on
        case resolution:
            if resolution.titleOfSelectedItem == "Custom…" {
                showCustomSize()
                return
            }
            let values =
                resolution.titleOfSelectedItem?.components(separatedBy: " × ").compactMap(Int.init)
                ?? []
            if values.count == 2 {
                patch["width"] = values[0]
                patch["height"] = values[1]
            }
        case start, end:
            // Submit the whole range so the second edit can repair an invalid first edit.
            patch["start"] = dateFormat.string(from: start.dateValue)
            patch["end"] = dateFormat.string(from: end.dateValue)
        case month: patch["month"] = String(dateFormat.string(from: month.dateValue).prefix(7))
        case showTitle: patch["showTitle"] = showTitle.state == .on
        case rooms: patch["rooms"] = rooms.state == .on
        case includeWeekends: patch["includeWeekends"] = includeWeekends.state == .on
        case iconSpace: patch["iconSpace"] = iconSpace.state == .on
        default: break
        }
        if !patch.isEmpty { onChange?(patch) }
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextField === name else { return }
        onChange?(["name": name.stringValue])
    }
    @objc func toggleAppearance() {
        appearanceFields.isHidden = appearanceToggle.state != .on
        appearanceToggle.image = NSImage(
            systemSymbolName: appearanceToggle.state == .on ? "chevron.down" : "chevron.right",
            accessibilityDescription: nil)
        appearanceToggle.setAccessibilityLabel(
            appearanceToggle.state == .on ? "Hide appearance options" : "Show appearance options")
    }
    @objc func exportPNG() {
        view.window?.makeFirstResponder(nil)
        onExport?(false, nil)
    }
    @objc func exportLightPNG() {
        view.window?.makeFirstResponder(nil)
        onExport?(false, "light")
    }
    @objc func exportDarkPNG() {
        view.window?.makeFirstResponder(nil)
        onExport?(false, "dark")
    }
    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        canExport?() ?? false
    }
    @objc func exportHEIC() {
        view.window?.makeFirstResponder(nil)
        onExport?(true, nil)
    }
    @objc func showSuggestions() { tabs.selectTabViewItem(withIdentifier: "suggestions") }
    func closeDetails() { tabs.selectTabViewItem(withIdentifier: "preview") }
    func numberOfRows(in tableView: NSTableView) -> Int { events.count }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard events.indices.contains(row) else { return nil }
        let event = events[row]
        let cell = NSTableCellView()
        if column?.identifier.rawValue == "included" {
            let checkbox = NSButton(
                checkboxWithTitle: "", target: self, action: #selector(includeEvent(_:)))
            checkbox.tag = row
            checkbox.state = event["included"] as? Bool == true ? .on : .off
            checkbox.setAccessibilityLabel(
                "Include \(event["title"] as? String ?? "event"), \(event["date"] as? String ?? "")"
            )
            cell.addSubview(checkbox)
            checkbox.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                checkbox.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                checkbox.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }
        let text: String
        switch column?.identifier.rawValue {
        case "date":
            text =
                "\(event["date"] as? String ?? "") · \(event["allDay"] as? Bool == true ? "All day" : event["startTime"] as? String ?? "")"
        case "source": text = event["sourceName"] as? String ?? ""
        default: text = event["title"] as? String ?? ""
        }
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = text
        cell.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
    @objc func includeEvent(_ sender: NSButton) {
        guard events.indices.contains(sender.tag), let uid = events[sender.tag]["uid"] as? String
        else { return }
        onInclude?(uid, sender.state == .on)
    }
    func tableViewSelectionDidChange(_ notification: Notification) { showDetails() }
    private func showDetails() {
        guard events.indices.contains(table.selectedRow) else {
            details.string =
                events.isEmpty
                ? "No events in this range."
                : "Click on an event to see its full details."
            return
        }
        let event = events[table.selectedRow]
        var lines = [
            event["title"] as? String ?? "",
            "\(event["date"] as? String ?? "") · \(event["allDay"] as? Bool == true ? "All day" : "\(event["startTime"] as? String ?? "") – \(event["endTime"] as? String ?? "")")",
        ]
        for key in ["location", "description"] {
            if let value = event[key] as? String, !value.isEmpty { lines.append(value) }
        }
        if event["roomConflict"] as? Bool == true {
            lines.append(
                "The description mentions another room. Check the source before attending.")
        }
        lines.append(
            [event["sourceName"] as? String, event["summary"] as? String].compactMap { $0 }.joined(
                separator: " · "))
        details.string = lines.joined(separator: "\n\n")
    }
    private func reloadSuggestions() {
        for child in suggestionList.arrangedSubviews {
            suggestionList.removeArrangedSubview(child)
            child.removeFromSuperview()
        }
        let note = NSTextField(
            wrappingLabelWithString:
                "Estimates from TimeEdit course events, excluding unchecked events. Edit a name and dates, then choose Use module. Automatic wallpaper updates also apply accepted changes."
        )
        suggestionList.addArrangedSubview(note)
        if suggestions.isEmpty {
            suggestionList.addArrangedSubview(
                NSTextField(
                    wrappingLabelWithString:
                        "Not enough matching sessions to suggest a module. You can still enter a name and dates manually."
                ))
        }
        for suggestion in suggestions {
            let card = ModuleSuggestionView(suggestion: suggestion)
            card.onUse = { [weak self] patch in self?.onChange?(patch) }
            suggestionList.addArrangedSubview(card)
        }
        for child in suggestionList.arrangedSubviews {
            child.widthAnchor.constraint(equalTo: suggestionList.widthAnchor).isActive = true
        }
    }
}

private final class ModuleSuggestionView: NSView {
    var onUse: (([String: Any]) -> Void)?
    private let name = NSTextField()
    private let start = NSDatePicker()
    private let end = NSDatePicker()
    private let formatter = DateFormatter()
    init(suggestion: [String: Any]) {
        super.init(frame: .zero)
        let title = NSTextField(
            labelWithString: suggestion["name"] as? String ?? "Suggested module")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        name.stringValue = suggestion["name"] as? String ?? ""
        name.setAccessibilityLabel("Suggested module name")
        for (picker, key, label) in [
            (start, "start", "Suggested first day"), (end, "end", "Suggested last day"),
        ] {
            picker.datePickerStyle = .textFieldAndStepper
            picker.datePickerElements = .yearMonthDay
            picker.calendar = Calendar(identifier: .gregorian)
            picker.timeZone = TimeZone(secondsFromGMT: 0)
            picker.dateValue = formatter.date(from: suggestion[key] as? String ?? "") ?? Date()
            picker.setAccessibilityLabel(label)
        }
        let reason = NSTextField(
            wrappingLabelWithString:
                "\(suggestion["confidence"] as? String ?? "") · \(suggestion["count"] as? Int ?? 0) sessions\n"
                + (suggestion["reasons"] as? [String] ?? []).joined(separator: "\n"))
        reason.font = .systemFont(ofSize: 12)
        let dates = EditorViewController.stack(
            [
                NSTextField(labelWithString: "First day"), start,
                NSTextField(labelWithString: "Last day"), end,
            ], vertical: false)
        let content = EditorViewController.stack([
            title, reason, name, dates,
            NSButton(title: "Use module", target: self, action: #selector(useModule)),
        ])
        addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])
        for child in [title, reason, name] {
            child.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func useModule() {
        window?.makeFirstResponder(nil)
        onUse?([
            "mode": "module",
            "name": name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            "start": formatter.string(from: start.dateValue),
            "end": formatter.string(from: end.dateValue), "proposed": false,
        ])
    }
}
