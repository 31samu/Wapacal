import AppKit

final class DayDateField: NSView {
    let picker: NSDatePicker
    let previousDay = NSButton()
    let nextDay = NSButton()

    init(picker: NSDatePicker, title: String) {
        self.picker = picker
        super.init(frame: .zero)
        picker.datePickerStyle = .textField
        picker.isBezeled = false
        picker.isBordered = false
        picker.drawsBackground = false
        picker.setAccessibilityLabel(title)
        for (button, symbol, description) in [
            (previousDay, "chevron.down", "Previous day"),
            (nextDay, "chevron.up", "Next day"),
        ] {
            button.image = NSImage(
                systemSymbolName: symbol, accessibilityDescription: description
            )?.withSymbolConfiguration(.init(pointSize: 8, weight: .medium))
            button.imagePosition = .imageOnly
            button.isBordered = false
            button.controlSize = .small
            button.target = self
            button.action = #selector(stepDay(_:))
            button.setAccessibilityLabel("\(description) for \(title.lowercased())")
        }
        for control in [picker, previousDay, nextDay] {
            addSubview(control)
            control.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            picker.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            picker.centerYAnchor.constraint(equalTo: centerYAnchor),
            previousDay.leadingAnchor.constraint(equalTo: picker.trailingAnchor, constant: 3),
            previousDay.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            previousDay.topAnchor.constraint(equalTo: centerYAnchor),
            previousDay.heightAnchor.constraint(equalToConstant: 11),
            nextDay.leadingAnchor.constraint(equalTo: previousDay.leadingAnchor),
            nextDay.trailingAnchor.constraint(equalTo: previousDay.trailingAnchor),
            nextDay.bottomAnchor.constraint(equalTo: centerYAnchor),
            nextDay.heightAnchor.constraint(equalToConstant: 11),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
    }

    @objc func stepDay(_ sender: NSButton) {
        guard picker.isEnabled else { return }
        let days = sender === nextDay ? 1 : -1
        var calendar = picker.calendar ?? Calendar(identifier: .gregorian)
        calendar.timeZone = picker.timeZone ?? TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(byAdding: .day, value: days, to: picker.dateValue) else {
            return
        }
        picker.dateValue = date
        picker.sendAction(picker.action, to: picker.target)
    }
}

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

final class EditorSlider: NSSlider {
    private(set) var isTracking = false
    var onTrackingEnded: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureTracking()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureTracking()
    }
    private func configureTracking() {
        #if WAPACAL_CONTROL_EVENTS
            addTarget(self, action: #selector(beginTracking), for: .trackingBegan)
            addTarget(
                self, action: #selector(endTracking),
                for: [.trackingEndedInside, .trackingEndedOutside, .trackingCancelled])
        #endif
    }
    @objc private func beginTracking() {
        guard !isTracking else { return }
        isTracking = true
    }
    #if !WAPACAL_CONTROL_EVENTS
        override func mouseDown(with event: NSEvent) {
            guard isEnabled else { return }
            beginTracking()
            super.mouseDown(with: event)
            endTracking()
        }
    #endif
    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        if !isTracking, NSApp.currentEvent?.type == .leftMouseDown { beginTracking() }
        return super.sendAction(action, to: target)
    }
    @objc private func endTracking() {
        guard isTracking else { return }
        isTracking = false
        onTrackingEnded?()
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
    NSTableViewDelegate, NSTabViewDelegate,
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
    let contentSelector = NSSegmentedControl()
    let summary = NSTextField(labelWithString: "Loading calendar…")
    let warning = NSTextField(wrappingLabelWithString: "")
    private var warningScroll: NSScrollView!
    private var warningHeight: NSLayoutConstraint?
    var showsLayoutWarnings = true {
        didSet { updateLayoutWarnings() }
    }
    let error = NSTextField(wrappingLabelWithString: "")
    let table = NSTableView()
    let details = NSTextView()
    let mode = NSSegmentedControl()
    let theme = NSSegmentedControl()
    let colorTheme = NSPopUpButton()
    let calendarColors = NSButton(
        checkboxWithTitle: "Calendar colors", target: nil, action: nil)
    private var customColorFields: NSStackView!
    private(set) var colorWells: [String: NSColorWell] = [:]
    private var customColors: [String: [String: String]] = [:]
    let eventStyle = NSSegmentedControl()
    let eventTextSize = EditorSlider(
        value: 100, minValue: 75, maxValue: 150, target: nil, action: nil)
    let eventTextSizeValue = NSTextField(labelWithString: "100%")
    private var pendingEventTextPercent: Int?
    let resetEventTextSize = NSButton(title: "Revert", target: nil, action: nil)
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
    let showTimeZone = NSButton(checkboxWithTitle: "Show time zone", target: nil, action: nil)
    let showSnapshotDate = NSButton(
        checkboxWithTitle: "Show snapshot date", target: nil, action: nil)
    let showCalendarLegend = NSButton(
        checkboxWithTitle: "Show calendar legend", target: nil, action: nil)
    let showEventTimes = NSButton(checkboxWithTitle: "Show event times", target: nil, action: nil)
    let showWeekNumbers = NSButton(checkboxWithTitle: "Show week numbers", target: nil, action: nil)
    let highlightToday = NSButton(checkboxWithTitle: "Highlight today", target: nil, action: nil)
    let includeWeekends = NSButton(
        checkboxWithTitle: "Include Saturdays and Sundays", target: nil, action: nil)
    let exportMenu = NSPopUpButton(frame: .zero, pullsDown: true)
    let calendarsToggle = NSButton(title: "Calendars", target: nil, action: nil)
    let calendarFields = NSStackView()
    let appearanceToggle = NSButton(checkboxWithTitle: "Appearance", target: nil, action: nil)
    private(set) var appearanceFields: NSStackView!
    private let moreAppearanceToggle = NSButton(title: "More options", target: nil, action: nil)
    private var moreAppearanceFields: NSStackView!
    private var paddingResetButtons: [String: NSButton] = [:]
    private var paddingSliders: [String: EditorSlider] = [:]
    private var paddingValues: [String: NSTextField] = [:]
    private let paddingDefaults = ["Left": 76, "Right": 76, "Top": 24, "Bottom": 22]
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
    private func scroll(
        _ content: NSView, verticalInset: CGFloat = 12, horizontalInset: CGFloat = 12
    ) -> NSScrollView {
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
            content.topAnchor.constraint(equalTo: document.topAnchor, constant: verticalInset),
            content.leadingAnchor.constraint(
                equalTo: document.leadingAnchor, constant: horizontalInset),
            content.trailingAnchor.constraint(
                equalTo: document.trailingAnchor, constant: -horizontalInset),
            content.bottomAnchor.constraint(
                equalTo: document.bottomAnchor, constant: -verticalInset),
        ])
        return scroll
    }
    override func loadView() {
        view = NSView()
        for (control, labels) in [
            (mode, ["Module", "Month"]),
            (contentSelector, ["Preview", "Exclude events", "Suggested modules"]),
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
        for control: NSControl in [mode, theme, colorTheme, eventStyle, eventTextSize, resolution] {
            control.target = self
            control.action = #selector(changeControl(_:))
        }
        resetEventTextSize.target = self
        resetEventTextSize.action = #selector(changeControl(_:))
        resetEventTextSize.title = ""
        resetEventTextSize.image = NSImage(
            systemSymbolName: "arrow.counterclockwise.circle", accessibilityDescription: nil)
        resetEventTextSize.imagePosition = .imageOnly
        resetEventTextSize.isBordered = false
        resetEventTextSize.widthAnchor.constraint(equalToConstant: 24).isActive = true
        resetEventTextSize.heightAnchor.constraint(equalToConstant: 24).isActive = true
        resetEventTextSize.controlSize = .small
        resetEventTextSize.toolTip = "Reset event text size to 100%"
        resetEventTextSize.setAccessibilityLabel("Reset event text size to 100%")
        resetEventTextSize.setContentHuggingPriority(.required, for: .horizontal)
        eventTextSize.isContinuous = true
        eventTextSize.onTrackingEnded = { [weak self] in
            guard let self else { return }
            self.changeControl(self.eventTextSize)
        }
        eventTextSizeValue.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        eventTextSizeValue.alignment = .right
        eventTextSizeValue.widthAnchor.constraint(equalToConstant: 42).isActive = true
        eventTextSize.setAccessibilityLabel("Event text size")
        eventTextSize.setAccessibilityIdentifier("event-text-size")
        eventTextSizeValue.setContentHuggingPriority(.required, for: .horizontal)
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
        for control in [
            showTitle, rooms, showTimeZone, showWeekNumbers, showSnapshotDate, showCalendarLegend,
            showEventTimes, highlightToday, includeWeekends,
            calendarColors,
        ] {
            control.target = self
            control.action = #selector(changeControl(_:))
        }
        for picker in [start, end] {
            picker.controlSize = .regular
            picker.font = .systemFont(ofSize: NSFont.systemFontSize)
        }
        let dateRange = Self.stack(
            [
                field("First day", DayDateField(picker: start, title: "First day")),
                field("Last day", DayDateField(picker: end, title: "Last day")),
            ],
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
        var paddingFields: [NSView] = []
        for side in ["Left", "Right", "Top", "Bottom"] {
            let slider = EditorSlider(
                value: Double(paddingDefaults[side]!), minValue: 0, maxValue: 200,
                target: self, action: #selector(changePadding))
            slider.isContinuous = true
            slider.onTrackingEnded = { [weak self, weak slider] in
                guard let self, let slider else { return }
                self.changePadding(slider)
            }
            slider.setAccessibilityLabel("\(side) padding")
            slider.toolTip = "Spacing scales with the wallpaper resolution."
            let value = NSTextField(labelWithString: "\(paddingDefaults[side]!)")
            value.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            value.alignment = .right
            value.widthAnchor.constraint(equalToConstant: 32).isActive = true
            let reset = NSButton(title: "Revert", target: self, action: #selector(resetPadding))
            reset.image = NSImage(
                systemSymbolName: "arrow.counterclockwise.circle", accessibilityDescription: nil)
            reset.imagePosition = .imageOnly
            reset.isBordered = false
            reset.widthAnchor.constraint(equalToConstant: 24).isActive = true
            reset.heightAnchor.constraint(equalToConstant: 24).isActive = true
            reset.controlSize = .small
            reset.toolTip = "Reset \(side.lowercased()) padding to \(paddingDefaults[side]!)"
            reset.setAccessibilityLabel(reset.toolTip!)
            reset.setContentHuggingPriority(.required, for: .horizontal)
            paddingResetButtons[side] = reset
            paddingSliders[side] = slider
            paddingValues[side] = value
            paddingFields.append(
                field(
                    "\(side) padding",
                    Self.stack([slider, value, reset], vertical: false, spacing: 8)))
        }
        moreAppearanceFields = Self.stack(
            [
                showTitle, showTimeZone, showWeekNumbers, highlightToday, showEventTimes,
                rooms, showSnapshotDate, showCalendarLegend,
            ] + paddingFields,
            spacing: 14)
        moreAppearanceFields.isHidden = true
        moreAppearanceToggle.setButtonType(.onOff)
        moreAppearanceToggle.isBordered = false
        moreAppearanceToggle.image = NSImage(
            systemSymbolName: "chevron.right", accessibilityDescription: nil)
        moreAppearanceToggle.imagePosition = .imageLeft
        moreAppearanceToggle.alignment = .left
        moreAppearanceToggle.font = .systemFont(ofSize: 13, weight: .semibold)
        moreAppearanceToggle.target = self
        moreAppearanceToggle.action = #selector(toggleMoreAppearance)
        moreAppearanceToggle.setAccessibilityLabel("Show more appearance options")
        appearanceFields = Self.stack(
            [
                field("Image size", imageSizeFields),
                field("Preview appearance", theme),
                field("Color theme", colorThemeRow),
                customColorFields!,
                field("Event style", eventStyle),
                field(
                    "Event text size",
                    Self.stack(
                        [eventTextSize, eventTextSizeValue, resetEventTextSize], vertical: false,
                        spacing: 8)),
                moreAppearanceToggle, moreAppearanceFields!,
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
        appearanceToggle.font = .systemFont(ofSize: 15, weight: .bold)
        appearanceToggle.heightAnchor.constraint(equalToConstant: 32).isActive = true
        appearanceToggle.target = self
        appearanceToggle.action = #selector(toggleAppearance)
        appearanceToggle.setAccessibilityLabel("Show appearance options")
        calendarFields.orientation = .vertical
        calendarFields.alignment = .leading
        calendarFields.spacing = 14
        calendarFields.isHidden = true
        calendarsToggle.setButtonType(.onOff)
        calendarsToggle.isBordered = false
        calendarsToggle.image = NSImage(
            systemSymbolName: "chevron.right", accessibilityDescription: nil)
        calendarsToggle.imagePosition = .imageLeft
        calendarsToggle.alignment = .left
        calendarsToggle.font = .systemFont(ofSize: 15, weight: .bold)
        calendarsToggle.heightAnchor.constraint(equalToConstant: 32).isActive = true
        calendarsToggle.target = self
        calendarsToggle.action = #selector(toggleCalendars)
        calendarsToggle.setAccessibilityLabel("Show calendar options")
        let heading = NSTextField(labelWithString: "Schedule")
        heading.font = .systemFont(ofSize: 15, weight: .bold)
        heading.heightAnchor.constraint(equalToConstant: 32).isActive = true
        let settings = Self.stack(
            [
                heading, field("View", mode), moduleFields, monthField,
                includeWeekends, calendarsToggle, calendarFields,
                appearanceToggle,
                appearanceFields!,
            ], spacing: 18)
        for child in settings.arrangedSubviews {
            child.widthAnchor.constraint(equalTo: settings.widthAnchor).isActive = true
        }
        for group in [moduleFields!, appearanceFields!, moreAppearanceFields!] {
            for child in group.arrangedSubviews {
                child.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
            }
        }
        let sidebar = scroll(settings)
        sidebar.hasVerticalScroller = false
        sidebar.widthAnchor.constraint(equalToConstant: 270).isActive = true

        tabs.tabViewType = .noTabsNoBorder
        tabs.delegate = self
        contentSelector.target = self
        contentSelector.action = #selector(changeContent)
        contentSelector.setAccessibilityLabel("Content view")
        contentSelector.selectedSegment = 0
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
        warningScroll = scroll(warning, verticalInset: 4, horizontalInset: 0)
        warningHeight = warningScroll.heightAnchor.constraint(equalToConstant: 24)
        warningHeight?.isActive = true
        warningScroll.isHidden = true
        let main = Self.stack([error, contentSelector, tabs, summary, warningScroll!])
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

    override func viewDidLayout() {
        super.viewDidLayout()
        updateLayoutWarnings()
    }

    private func updateLayoutWarnings() {
        guard let warningScroll else { return }
        warningScroll.isHidden = !showsLayoutWarnings || warning.stringValue.isEmpty
        guard !warningScroll.isHidden else { return }
        let width = warningScroll.contentSize.width
        guard width > 0, let cell = warning.cell else { return }
        let textSize = cell.cellSize(
            forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude))
        let height = min(80, ceil(textSize.height) + 8)
        if warningHeight?.constant != height {
            warningHeight?.constant = height
        }
    }

    func setReady(_ ready: Bool) {
        for control: NSControl in [
            mode, theme, colorTheme, calendarColors, eventStyle, eventTextSize,
            resolution, name,
            start,
            end, month, showTitle, rooms, showTimeZone, showWeekNumbers, showSnapshotDate,
            showCalendarLegend, showEventTimes, highlightToday,
            includeWeekends, exportMenu,
        ] { control.isEnabled = ready }
        for picker in [start, end] {
            (picker.superview as? DayDateField)?.previousDay.isEnabled = ready
            (picker.superview as? DayDateField)?.nextDay.isEnabled = ready
        }
        for well in colorWells.values { well.isEnabled = ready }
        for slider in paddingSliders.values { slider.isEnabled = ready }
        updateRevertButtons()
    }
    private func updateRevertButtons() {
        resetEventTextSize.isEnabled =
            eventTextSize.isEnabled && eventTextSize.doubleValue.rounded() != 100
        for (side, slider) in paddingSliders {
            paddingResetButtons[side]?.isEnabled =
                slider.isEnabled && slider.doubleValue.rounded() != Double(paddingDefaults[side]!)
        }
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
        for (side, slider) in paddingSliders where !slider.isTracking {
            let value = editor["padding\(side)"] as? Double ?? Double(paddingDefaults[side]!)
            slider.doubleValue = value
            paddingValues[side]?.stringValue = "\(Int(value.rounded()))"
        }
        mode.selectedSegment = editor["mode"] as? String == "month" ? 1 : 0
        let savedPercent = Int(((editor["eventTextScale"] as? Double ?? 1) * 100).rounded())
        if !eventTextSize.isTracking,
            pendingEventTextPercent == nil || pendingEventTextPercent == savedPercent
        {
            pendingEventTextPercent = nil
            eventTextSize.doubleValue = Double(savedPercent)
            eventTextSizeValue.stringValue = "\(savedPercent)%"
        }
        updateRevertButtons()
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
        showTimeZone.state = editor["showTimeZone"] as? Bool == false ? .off : .on
        showSnapshotDate.state = editor["showSnapshotDate"] as? Bool == false ? .off : .on
        showCalendarLegend.state = editor["showCalendarLegend"] as? Bool == false ? .off : .on
        showEventTimes.state = editor["showEventTimes"] as? Bool == false ? .off : .on
        showWeekNumbers.state = editor["showWeekNumbers"] as? Bool == false ? .off : .on
        highlightToday.state = editor["highlightToday"] as? Bool == false ? .off : .on
        includeWeekends.state = editor["includeWeekends"] as? Bool == true ? .on : .off
        updateResolutionMenu()
        let included = snapshot["includedCount"] as? Int ?? 0
        summary.stringValue = "\(included) events included · \(events.count - included) excluded"
        let size = "\(editor["width"] as? Int ?? 3024) × \(editor["height"] as? Int ?? 1964)"
        summary.toolTip = "Snapshot \(editor["snapshotDate"] as? String ?? "none") · \(size)"
        warning.stringValue = (snapshot["warnings"] as? [String] ?? []).joined(separator: "\n")
        updateLayoutWarnings()
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
        case eventTextSize:
            let percent = eventTextSize.doubleValue.rounded()
            eventTextSizeValue.stringValue = "\(Int(percent))%"
            updateRevertButtons()
            // Update the label during tracking; render and save when the drag ends.
            if eventTextSize.isTracking { return }
            pendingEventTextPercent = Int(percent)
            eventTextSize.doubleValue = percent
            patch["eventTextScale"] = percent / 100
        case resetEventTextSize:
            pendingEventTextPercent = 100
            eventTextSize.doubleValue = 100
            eventTextSizeValue.stringValue = "100%"
            updateRevertButtons()
            patch["eventTextScale"] = 1.0
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
        case showTimeZone: patch["showTimeZone"] = showTimeZone.state == .on
        case showSnapshotDate: patch["showSnapshotDate"] = showSnapshotDate.state == .on
        case showCalendarLegend: patch["showCalendarLegend"] = showCalendarLegend.state == .on
        case showEventTimes: patch["showEventTimes"] = showEventTimes.state == .on
        case showWeekNumbers: patch["showWeekNumbers"] = showWeekNumbers.state == .on
        case highlightToday: patch["highlightToday"] = highlightToday.state == .on
        case includeWeekends: patch["includeWeekends"] = includeWeekends.state == .on
        default: break
        }
        if !patch.isEmpty { onChange?(patch) }
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextField === name else { return }
        onChange?(["name": name.stringValue])
    }
    @objc func toggleCalendars() {
        calendarFields.isHidden = calendarsToggle.state != .on
        calendarsToggle.image = NSImage(
            systemSymbolName: calendarsToggle.state == .on ? "chevron.down" : "chevron.right",
            accessibilityDescription: nil)
        calendarsToggle.setAccessibilityLabel(
            calendarsToggle.state == .on ? "Hide calendar options" : "Show calendar options")
    }

    @objc func toggleAppearance() {
        appearanceFields.isHidden = appearanceToggle.state != .on
        appearanceToggle.image = NSImage(
            systemSymbolName: appearanceToggle.state == .on ? "chevron.down" : "chevron.right",
            accessibilityDescription: nil)
        appearanceToggle.setAccessibilityLabel(
            appearanceToggle.state == .on ? "Hide appearance options" : "Show appearance options")
    }
    @objc private func resetPadding(_ sender: NSButton) {
        guard let side = paddingResetButtons.first(where: { $0.value === sender })?.key,
            let slider = paddingSliders[side], let value = paddingDefaults[side]
        else { return }
        slider.doubleValue = Double(value)
        changePadding(slider)
    }
    @objc private func changePadding(_ sender: EditorSlider) {
        guard let side = paddingSliders.first(where: { $0.value === sender })?.key else { return }
        let value = sender.doubleValue.rounded()
        sender.doubleValue = value
        paddingValues[side]?.stringValue = "\(Int(value))"
        updateRevertButtons()
        if sender.isTracking { return }
        onChange?(["padding\(side)": value])
    }
    @objc func toggleMoreAppearance() {
        moreAppearanceFields.isHidden = moreAppearanceToggle.state != .on
        moreAppearanceToggle.image = NSImage(
            systemSymbolName: moreAppearanceToggle.state == .on ? "chevron.down" : "chevron.right",
            accessibilityDescription: nil)
        moreAppearanceToggle.setAccessibilityLabel(
            moreAppearanceToggle.state == .on
                ? "Hide more appearance options" : "Show more appearance options")
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
    @objc func changeContent() {
        tabs.selectTabViewItem(at: contentSelector.selectedSegment)
    }
    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        guard let tabViewItem else { return }
        contentSelector.selectedSegment = tabView.indexOfTabViewItem(tabViewItem)
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
