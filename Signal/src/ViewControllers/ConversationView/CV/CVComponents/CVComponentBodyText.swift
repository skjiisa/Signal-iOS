//
// Copyright 2020 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalUI

public class CVComponentBodyText: CVComponentBase, CVComponent {

    public var componentKey: CVComponentKey { .bodyText }

    struct State: Equatable {
        let bodyText: CVComponentState.BodyText
        let isTextExpanded: Bool
        let searchText: String?
        let revealedSpoilerIds: Set<Int>
        let hasTapForMore: Bool
        let shouldUseAttributedText: Bool
        let hasPendingMessageRequest: Bool
        fileprivate let items: [CVTextLabel.Item]

        public var canUseDedicatedCell: Bool {
            if hasTapForMore || searchText != nil {
                return false
            }
            switch bodyText {
            case .bodyText:
                return true
            case .oversizeTextDownloading:
                return false
            case .remotelyDeleted:
                return false
            }
        }

        var textValue: CVTextValue? {
            bodyText.textValue(isTextExpanded: isTextExpanded)
        }
    }
    private let bodyTextState: State

    private var bodyText: CVComponentState.BodyText {
        bodyTextState.bodyText
    }
    private var textValue: CVTextValue? {
        bodyTextState.textValue
    }
    private var isTextExpanded: Bool {
        bodyTextState.isTextExpanded
    }
    private var searchText: String? {
        bodyTextState.searchText
    }
    private var revealedSpoilerIds: Set<Int> {
        bodyTextState.revealedSpoilerIds
    }
    private var hasTapForMore: Bool {
        bodyTextState.hasTapForMore
    }
    private var hasPendingMessageRequest: Bool {
        bodyTextState.hasPendingMessageRequest
    }
    public var shouldUseAttributedText: Bool {
        bodyTextState.shouldUseAttributedText
    }

    init(itemModel: CVItemModel, bodyTextState: State) {
        self.bodyTextState = bodyTextState

        super.init(itemModel: itemModel)
    }

    public func buildComponentView(componentDelegate: CVComponentDelegate) -> CVComponentView {
        CVComponentViewBodyText(componentDelegate: componentDelegate)
    }

    private static func shouldIgnoreEvents(interaction: TSInteraction) -> Bool {
        guard let outgoingMessage = interaction as? TSOutgoingMessage else {
            return false
        }
        // Ignore taps on links in outgoing messages that haven't been sent yet, as
        // this interferes with "tap to retry".
        return outgoingMessage.messageState != .sent
    }
    private var shouldIgnoreEvents: Bool { Self.shouldIgnoreEvents(interaction: interaction) }

    // TODO:
    private static let shouldDetectDates = false

    private static func buildDataDetector(shouldAllowLinkification: Bool) -> NSDataDetector? {
        var checkingTypes = NSTextCheckingResult.CheckingType()
        if shouldAllowLinkification {
            checkingTypes.insert(.link)
        }
        checkingTypes.insert(.address)
        checkingTypes.insert(.phoneNumber)
        if shouldDetectDates {
            checkingTypes.insert(.date)
        }

        do {
            return try NSDataDetector(types: checkingTypes.rawValue)
        } catch {
            owsFailDebug("Error: \(error)")
            return nil
        }
    }

    private static var dataDetectorWithLinks: NSDataDetector? = {
        buildDataDetector(shouldAllowLinkification: true)
    }()

    private static var dataDetectorWithoutLinks: NSDataDetector? = {
        buildDataDetector(shouldAllowLinkification: false)
    }()

    // DataDetectors are expensive to build, so we reuse them.
    private static func dataDetector(shouldAllowLinkification: Bool) -> NSDataDetector? {
        shouldAllowLinkification ? dataDetectorWithLinks : dataDetectorWithoutLinks
    }

    private static let unfairLock = UnfairLock()

    private static func detectItems(
        text: String,
        attributedString: NSAttributedString?,
        hasPendingMessageRequest: Bool,
        shouldAllowLinkification: Bool,
        textWasTruncated: Bool,
        revealedSpoilerIds: Set<StyleIdType>,
        interactionUniqueId: String
    ) -> [CVTextLabel.Item] {

        // Use a lock to ensure that measurement on and off the main thread
        // don't conflict.
        unfairLock.withLock {
            guard !hasPendingMessageRequest else {
                // Do not linkify if there is a pending message request.
                return []
            }

            if textWasTruncated {
                owsAssertDebug(text.hasSuffix(DisplayableText.truncatedTextSuffix))
            }

            func shouldDiscardDataItem(_ dataItem: TextCheckingDataItem) -> Bool {
                if textWasTruncated {
                    if NSMaxRange(dataItem.range) == NSMaxRange(text.entireRange) {
                        // This implies that the data detector *included* our "…" suffix.
                        // We don't expect this to happen, but if it does it's certainly not intended!
                        return true
                    }
                    if (text as NSString).substring(after: dataItem.range) == DisplayableText.truncatedTextSuffix {
                        // More likely the item right before the "…" was detected.
                        // Conservatively assume that the item was truncated.
                        return true
                    }
                }
                return false
            }

            let dataDetector = buildDataDetector(shouldAllowLinkification: shouldAllowLinkification)

            let items: [CVTextLabel.Item]

            if let attributedString = attributedString {
                let recoveredBody = RecoveredHydratedMessageBody.recover(from: attributedString)
                items = recoveredBody
                    .tappableItems(
                        revealedSpoilerIds: revealedSpoilerIds,
                        dataDetector: dataDetector
                    )
                    .compactMap {
                        switch $0 {
                        case .unrevealedSpoiler(let unrevealedSpoilerItem):
                            guard FeatureFlags.textFormattingReceiveSupport else {
                                return nil
                            }
                            return .unrevealedSpoiler(CVTextLabel.UnrevealedSpoilerItem(
                                spoilerId: unrevealedSpoilerItem.id,
                                interactionUniqueId: interactionUniqueId,
                                range: unrevealedSpoilerItem.range
                            ))
                        case .mention(let mentionItem):
                            return .mention(mentionItem: CVTextLabel.MentionItem(
                                mentionUUID: mentionItem.mentionUuid,
                                range: mentionItem.range
                            ))
                        case .data(let dataItem):
                            guard !shouldDiscardDataItem(dataItem) else {
                                return nil
                            }
                            return .dataItem(dataItem: dataItem)
                        }
                    }
            } else {
                items = TextCheckingDataItem.detectedItems(in: text, using: dataDetector).compactMap {
                    guard !shouldDiscardDataItem($0) else {
                        return nil
                    }
                    return .dataItem(dataItem: $0)
                }
            }

            return items
        }
    }

    static func buildState(interaction: TSInteraction,
                           bodyText: CVComponentState.BodyText,
                           viewStateSnapshot: CVViewStateSnapshot,
                           hasTapForMore: Bool,
                           hasPendingMessageRequest: Bool) -> State {
        let textExpansion = viewStateSnapshot.textExpansion
        let searchText = viewStateSnapshot.searchText
        let isTextExpanded = textExpansion.isTextExpanded(interactionId: interaction.uniqueId)
        let revealedSpoilerIds = viewStateSnapshot.spoilerReveal.revealedSpoilerIds(
            interactionUniqueId: interaction.uniqueId
        )

        let items: [CVTextLabel.Item]
        var shouldUseAttributedText = false
        if let displayableText = bodyText.displayableText,
           let textValue = bodyText.textValue(isTextExpanded: isTextExpanded) {

            let shouldAllowLinkification = displayableText.shouldAllowLinkification
            let textWasTruncated = !isTextExpanded && displayableText.isTextTruncated

            switch textValue {
            case .text(let text):
                items = detectItems(
                    text: text,
                    attributedString: nil,
                    hasPendingMessageRequest: hasPendingMessageRequest,
                    shouldAllowLinkification: shouldAllowLinkification,
                    textWasTruncated: textWasTruncated,
                    revealedSpoilerIds: revealedSpoilerIds,
                    interactionUniqueId: interaction.uniqueId
                )

                // UILabels are much cheaper than UITextViews, and we can
                // usually use them for rendering body text.
                //
                // We need to use attributed text in a UITextViews if:
                //
                // * We're displaying search results (and need to highlight matches).
                // * The text value is an attributed string (has mentions).
                // * The text value should be linkified.
                if searchText != nil {
                    shouldUseAttributedText = true
                } else {
                    shouldUseAttributedText = !items.isEmpty
                }
            case .attributedText(let attributedText):
                items = detectItems(
                    text: attributedText.string,
                    attributedString: attributedText,
                    hasPendingMessageRequest: hasPendingMessageRequest,
                    shouldAllowLinkification: shouldAllowLinkification,
                    textWasTruncated: textWasTruncated,
                    revealedSpoilerIds: revealedSpoilerIds,
                    interactionUniqueId: interaction.uniqueId
                )

                shouldUseAttributedText = true
            }
        } else {
            items = []
        }

        return State(bodyText: bodyText,
                     isTextExpanded: isTextExpanded,
                     searchText: searchText,
                     revealedSpoilerIds: revealedSpoilerIds,
                     hasTapForMore: hasTapForMore,
                     shouldUseAttributedText: shouldUseAttributedText,
                     hasPendingMessageRequest: hasPendingMessageRequest,
                     items: items)
    }

    static func buildComponentState(message: TSMessage,
                                    transaction: SDSAnyReadTransaction) throws -> CVComponentState.BodyText? {

        func build(displayableText: DisplayableText) -> CVComponentState.BodyText? {
            guard !displayableText.fullTextValue.stringValue.isEmpty else {
                return nil
            }
            return .bodyText(displayableText: displayableText)
        }

        // TODO: We might want to treat text that is completely stripped
        // as not present.
        if let oversizeTextAttachment = message.oversizeTextAttachment(with: transaction.unwrapGrdbRead) {
            if let oversizeTextAttachmentStream = oversizeTextAttachment as? TSAttachmentStream {
                let displayableText = CVComponentState.displayableBodyText(oversizeTextAttachment: oversizeTextAttachmentStream,
                                                                           ranges: message.bodyRanges,
                                                                           interaction: message,
                                                                           transaction: transaction)
                return build(displayableText: displayableText)
            } else if nil != oversizeTextAttachment as? TSAttachmentPointer {
                // TODO: Handle backup restore.
                // TODO: If there's media, should we display that while the oversize text is downloading?
                return .oversizeTextDownloading
            } else {
                throw OWSAssertionError("Invalid oversizeTextAttachment.")
            }
        } else if let body = message.body, !body.isEmpty {
            let displayableText = CVComponentState.displayableBodyText(text: body,
                                                                       ranges: message.bodyRanges,
                                                                       interaction: message,
                                                                       transaction: transaction)
            return build(displayableText: displayableText)
        } else {
            // No body text.
            return nil
        }
    }

    public var textMessageFont: UIFont {
        owsAssertDebug(DisplayableText.kMaxJumbomojiCount == 5)

        if let jumbomojiCount = bodyText.jumbomojiCount {
            let basePointSize = UIFont.dynamicTypeBodyClamped.pointSize
            switch jumbomojiCount {
            case 0:
                break
            case 1:
                return UIFont.regularFont(ofSize: basePointSize * 3.5)
            case 2:
                return UIFont.regularFont(ofSize: basePointSize * 3.0)
            case 3:
                return UIFont.regularFont(ofSize: basePointSize * 2.75)
            case 4:
                return UIFont.regularFont(ofSize: basePointSize * 2.5)
            case 5:
                return UIFont.regularFont(ofSize: basePointSize * 2.25)
            default:
                owsFailDebug("Unexpected jumbomoji count: \(jumbomojiCount)")
            }
        }

        return UIFont.dynamicTypeBody
    }

    private var bodyTextColor: UIColor {
        guard let message = interaction as? TSMessage else {
            return .black
        }
        return conversationStyle.bubbleTextColor(message: message)
    }

    private var textSelectionStyling: [NSAttributedString.Key: Any] {
        var foregroundColor: UIColor = .black
        if let message = interaction as? TSMessage {
            foregroundColor = conversationStyle.bubbleSecondaryTextColor(isIncoming: message.isIncoming)
        }

        return [
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: foregroundColor,
            .foregroundColor: foregroundColor
        ]
    }

    public func bodyTextLabelConfig(textViewConfig: CVTextViewConfig) -> CVTextLabel.Config {
        CVTextLabel.Config(attributedString: textViewConfig.text.attributedString,
                           font: textViewConfig.font,
                           textColor: textViewConfig.textColor,
                           selectionStyling: textSelectionStyling,
                           textAlignment: textViewConfig.textAlignment ?? .natural,
                           lineBreakMode: .byWordWrapping,
                           numberOfLines: 0,
                           cacheKey: textViewConfig.cacheKey,
                           items: bodyTextState.items)
    }

    public func bodyTextLabelConfig(labelConfig: CVLabelConfig) -> CVTextLabel.Config {
        // CVTextLabel requires that attributedString has
        // default attributes applied to the entire string's range.
        let textAlignment: NSTextAlignment = labelConfig.textAlignment ?? .natural
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = textAlignment
        let attributedText = labelConfig.attributedString.mutableCopy() as! NSMutableAttributedString
        attributedText.addAttributes(
            [
                .font: labelConfig.font,
                .foregroundColor: labelConfig.textColor,
                .paragraphStyle: paragraphStyle
            ],
            range: attributedText.entireRange
        )

        return CVTextLabel.Config(attributedString: attributedText,
                                  font: labelConfig.font,
                                  textColor: labelConfig.textColor,
                                  selectionStyling: textSelectionStyling,
                                  textAlignment: textAlignment,
                                  lineBreakMode: .byWordWrapping,
                                  numberOfLines: 0,
                                  cacheKey: labelConfig.cacheKey,
                                  items: bodyTextState.items)
    }

    public func configureForRendering(componentView: CVComponentView,
                                      cellMeasurement: CVCellMeasurement,
                                      componentDelegate: CVComponentDelegate) {
        AssertIsOnMainThread()
        guard let componentView = componentView as? CVComponentViewBodyText else {
            owsFailDebug("Unexpected componentView.")
            return
        }

        let bodyTextLabelConfig = buildBodyTextLabelConfig()
        configureForBodyTextLabel(componentView: componentView,
                                  bodyTextLabelConfig: bodyTextLabelConfig,
                                  cellMeasurement: cellMeasurement)
    }

    private func configureForBodyTextLabel(componentView: CVComponentViewBodyText,
                                           bodyTextLabelConfig: CVTextLabel.Config,
                                           cellMeasurement: CVCellMeasurement) {
        AssertIsOnMainThread()

        let bodyTextLabel = componentView.bodyTextLabel
        bodyTextLabel.configureForRendering(config: bodyTextLabelConfig)

        if bodyTextLabel.view.superview == nil {
            let stackView = componentView.stackView
            stackView.reset()
            stackView.configure(config: stackViewConfig,
                                cellMeasurement: cellMeasurement,
                                measurementKey: Self.measurementKey_stackView,
                                subviews: [ bodyTextLabel.view ])
        }
    }

    public func buildBodyTextLabelConfig() -> CVTextLabel.Config {
        switch bodyText {
        case .bodyText(let displayableText):
            return bodyTextLabelConfig(textViewConfig: textConfig(displayableText: displayableText))
        case .oversizeTextDownloading:
            return bodyTextLabelConfig(labelConfig: labelConfigForOversizeTextDownloading)
        case .remotelyDeleted:
            return bodyTextLabelConfig(labelConfig: labelConfigForRemotelyDeleted)
        }
    }

    private var stackViewConfig: CVStackViewConfig {
        CVStackViewConfig(axis: .vertical,
                          alignment: .fill,
                          spacing: 0,
                          layoutMargins: .zero)
    }

    private var labelConfigForRemotelyDeleted: CVLabelConfig {
        let text = (isIncoming
                        ? OWSLocalizedString("THIS_MESSAGE_WAS_DELETED", comment: "text indicating the message was remotely deleted")
                        : OWSLocalizedString("YOU_DELETED_THIS_MESSAGE", comment: "text indicating the message was remotely deleted by you"))
        return CVLabelConfig(text: text,
                             font: textMessageFont.italic(),
                             textColor: bodyTextColor,
                             numberOfLines: 0,
                             lineBreakMode: .byWordWrapping,
                             textAlignment: .center)
    }

    private var labelConfigForOversizeTextDownloading: CVLabelConfig {
        let text = OWSLocalizedString("MESSAGE_STATUS_DOWNLOADING",
                                     comment: "message status while message is downloading.")
        return CVLabelConfig(text: text,
                             font: textMessageFont.italic(),
                             textColor: bodyTextColor,
                             numberOfLines: 0,
                             lineBreakMode: .byWordWrapping,
                             textAlignment: .center)
    }

    private typealias TextConfig = CVTextViewConfig

    private func textConfig(displayableText: DisplayableText) -> TextConfig {
        let textValue = displayableText.textValue(isTextExpanded: isTextExpanded)
        return self.textViewConfig(displayableText: displayableText,
                                   attributedText: textValue.attributedString)
    }

    public static func configureTextView(_ textView: UITextView,
                                         interaction: TSInteraction,
                                         displayableText: DisplayableText) {
        let dataDetectorTypes: UIDataDetectorTypes = {
            // If we're link-ifying with NSDataDetector, UITextView doesn't need to do data detection.
            guard !shouldIgnoreEvents(interaction: interaction),
                  displayableText.shouldAllowLinkification else {
                return []
            }
            return [.link, .address, .calendarEvent, .phoneNumber]
        }()
        if textView.dataDetectorTypes != dataDetectorTypes {
            // Setting dataDetectorTypes is expensive, so we only
            // update the property if the value has changed.
            textView.dataDetectorTypes = dataDetectorTypes
        }
    }

    public enum LinkifyStyle {
        case linkAttribute
        case underlined(bodyTextColor: UIColor)
    }

    private func linkifyData(attributedText: NSMutableAttributedString) {
        Self.linkifyData(attributedText: attributedText,
                         linkifyStyle: .underlined(bodyTextColor: bodyTextColor),
                         items: bodyTextState.items)
    }

    public static func linkifyData(
        attributedText: NSMutableAttributedString,
        linkifyStyle: LinkifyStyle,
        hasPendingMessageRequest: Bool,
        shouldAllowLinkification: Bool,
        textWasTruncated: Bool,
        revealedSpoilerIds: Set<StyleIdType>,
        interactionUniqueId: String
    ) {

        let items = detectItems(
            text: attributedText.string,
            attributedString: attributedText,
            hasPendingMessageRequest: hasPendingMessageRequest,
            shouldAllowLinkification: shouldAllowLinkification,
            textWasTruncated: textWasTruncated,
            revealedSpoilerIds: revealedSpoilerIds,
            interactionUniqueId: interactionUniqueId
        )
        Self.linkifyData(attributedText: attributedText,
                         linkifyStyle: linkifyStyle,
                         items: items)
    }

    private static func linkifyData(attributedText: NSMutableAttributedString,
                                    linkifyStyle: LinkifyStyle,
                                    items: [CVTextLabel.Item]) {

        // Sort so that we can detect overlap.
        let items = items.sorted {
            $0.range.location < $1.range.location
        }

        var lastIndex: Int = 0
        for item in items {
            let range = item.range

            switch item {
            case .mention, .referencedUser, .unrevealedSpoiler:
                // Do nothing; these are already styled.
                continue
            case .dataItem(let dataItem):
                guard let link = dataItem.url.absoluteString.nilIfEmpty else {
                    owsFailDebug("Could not build data link.")
                    continue
                }

                switch linkifyStyle {
                case .linkAttribute:
                    attributedText.addAttribute(.link, value: link, range: range)
                case .underlined(let bodyTextColor):
                    attributedText.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                    attributedText.addAttribute(.underlineColor, value: bodyTextColor, range: range)
                }

                lastIndex = max(lastIndex, range.location + range.length)
            }
        }
    }

    private func textViewConfig(displayableText: DisplayableText,
                                attributedText attributedTextParam: NSAttributedString) -> CVTextViewConfig {

        // Honor dynamic type in the message bodies.
        let linkTextAttributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key.foregroundColor: bodyTextColor,
            NSAttributedString.Key.underlineStyle: NSUnderlineStyle.single.rawValue
        ]

        let textAlignment = (isTextExpanded
                                ? displayableText.fullTextNaturalAlignment
                                : displayableText.displayTextNaturalAlignment)

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = textAlignment

        var attributedText = attributedTextParam.mutableCopy() as! NSMutableAttributedString
        attributedText.addAttributes(
            [
                .font: textMessageFont,
                .foregroundColor: bodyTextColor,
                .paragraphStyle: paragraphStyle
            ],
            range: attributedText.entireRange
        )
        linkifyData(attributedText: attributedText)

        var matchedSearchRanges = [NSRange]()
        if let searchText = searchText,
           searchText.count >= ConversationSearchController.kMinimumSearchTextLength {
            let searchableText = FullTextSearchFinder.normalize(text: searchText)
            let pattern = NSRegularExpression.escapedPattern(for: searchableText)
            do {
                let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
                for match in regex.matches(in: attributedText.string,
                                           options: [.withoutAnchoringBounds],
                                           range: attributedText.string.entireRange) {
                    owsAssertDebug(match.range.length >= ConversationSearchController.kMinimumSearchTextLength)
                    matchedSearchRanges.append(match.range)
                }
            } catch {
                owsFailDebug("Error: \(error)")
            }
        }

        let messageBody = RecoveredHydratedMessageBody.recover(from: attributedText)
        attributedText = messageBody.reapplyAttributes(
            config: HydratedMessageBody.DisplayConfiguration(
                mention: isIncoming ? .incomingMessageBubble : .outgoingMessageBubble,
                style: StyleDisplayConfiguration.forMessageBubble(
                    isIncoming: isIncoming,
                    revealedSpoilerIds: revealedSpoilerIds
                ),
                searchRanges: .matchedRanges(matchedSearchRanges)
            ),
            isDarkThemeEnabled: isDarkThemeEnabled
        )

        var extraCacheKeyFactors = [String]()
        if hasPendingMessageRequest {
            extraCacheKeyFactors.append("hasPendingMessageRequest")
        }
        extraCacheKeyFactors.append("items: \(!bodyTextState.items.isEmpty)")

        return CVTextViewConfig(attributedText: attributedText,
                                font: textMessageFont,
                                textColor: bodyTextColor,
                                textAlignment: textAlignment,
                                linkTextAttributes: linkTextAttributes,
                                extraCacheKeyFactors: extraCacheKeyFactors)
    }

    private static let measurementKey_stackView = "CVComponentBodyText.measurementKey_stackView"
    private static let measurementKey_textMeasurement = "CVComponentBodyText.measurementKey_textMeasurement"
    private static let measurementKey_maxWidth = "CVComponentBodyText.measurementKey_maxWidth"

    // Extract the max width used for measuring for this component.
    public static func bodyTextMaxWidth(measurementBuilder: CVCellMeasurement.Builder) -> CGFloat? {
        measurementBuilder.getValue(key: measurementKey_maxWidth)
    }

    // Extract the overall measurement for this component.
    public static func bodyTextMeasurement(measurementBuilder: CVCellMeasurement.Builder) -> CVTextLabel.Measurement? {
        measurementBuilder.getObject(key: measurementKey_textMeasurement) as? CVTextLabel.Measurement
    }

    public func measure(maxWidth: CGFloat, measurementBuilder: CVCellMeasurement.Builder) -> CGSize {
        owsAssertDebug(maxWidth > 0)
        let maxWidth = max(maxWidth, 0)

        let bodyTextLabelConfig = buildBodyTextLabelConfig()

        let textMeasurement = CVText.measureBodyTextLabel(config: bodyTextLabelConfig, maxWidth: maxWidth)
        measurementBuilder.setObject(key: Self.measurementKey_textMeasurement, value: textMeasurement)
        measurementBuilder.setValue(key: Self.measurementKey_maxWidth, value: maxWidth)
        let textSize = textMeasurement.size.ceil
        let textInfo = textSize.asManualSubviewInfo
        let stackMeasurement = ManualStackView.measure(config: stackViewConfig,
                                                       measurementBuilder: measurementBuilder,
                                                       measurementKey: Self.measurementKey_stackView,
                                                       subviewInfos: [ textInfo ],
                                                       maxWidth: maxWidth)
        return stackMeasurement.measuredSize
    }

    // MARK: - Events

    public override func handleTap(sender: UITapGestureRecognizer,
                                   componentDelegate: CVComponentDelegate,
                                   componentView: CVComponentView,
                                   renderItem: CVRenderItem) -> Bool {
        guard let componentView = componentView as? CVComponentViewBodyText else {
            owsFailDebug("Unexpected componentView.")
            return false
        }

        guard !shouldIgnoreEvents else {
            return false
        }

        let bodyTextLabel = componentView.bodyTextLabel
        if let item = bodyTextLabel.itemForGesture(sender: sender) {
            bodyTextLabel.animate(selectedItem: item)
            componentDelegate.didTapBodyTextItem(item)
            return true
        }
        if hasTapForMore {
            let itemViewModel = CVItemViewModelImpl(renderItem: renderItem)
            componentDelegate.didTapTruncatedTextMessage(itemViewModel)
            return true
        }

        return false
    }

    public override func findLongPressHandler(sender: UIGestureRecognizer,
                                              componentDelegate: CVComponentDelegate,
                                              componentView: CVComponentView,
                                              renderItem: CVRenderItem) -> CVLongPressHandler? {

        guard let componentView = componentView as? CVComponentViewBodyText else {
            owsFailDebug("Unexpected componentView.")
            return nil
        }

        guard !shouldIgnoreEvents else {
            return nil
        }

        let bodyTextLabel = componentView.bodyTextLabel
        guard let item = bodyTextLabel.itemForGesture(sender: sender) else {
            return nil
        }
        bodyTextLabel.animate(selectedItem: item)
        return CVLongPressHandler(delegate: componentDelegate,
                                  renderItem: renderItem,
                                  gestureLocation: .bodyText(item: item))
    }

    // MARK: -

    fileprivate class BodyTextRootView: ManualStackView {}

    public static func findBodyTextRootView(_ view: UIView) -> UIView? {
        if view is BodyTextRootView {
            return view
        }
        for subview in view.subviews {
            if let rootView = findBodyTextRootView(subview) {
                return rootView
            }
        }
        return nil
    }

    // MARK: -

    // Used for rendering some portion of an Conversation View item.
    // It could be the entire item or some part thereof.
    public class CVComponentViewBodyText: NSObject, CVComponentView {

        public weak var componentDelegate: CVComponentDelegate?

        fileprivate let stackView = BodyTextRootView(name: "bodyText")

        public let bodyTextLabel = CVTextLabel()

        public var isDedicatedCellView = false

        public var rootView: UIView {
            stackView
        }

        required init(componentDelegate: CVComponentDelegate) {
            self.componentDelegate = componentDelegate

            super.init()
        }

        public func setIsCellVisible(_ isCellVisible: Bool) {}

        public func reset() {
            if !isDedicatedCellView {
                stackView.reset()
            }

            bodyTextLabel.reset()
        }
    }
}

// MARK: -

extension CVComponentBodyText: CVAccessibilityComponent {
    public var accessibilityDescription: String {
        switch bodyText {
        case .bodyText(let displayableText):
            // NOTE: we use the full text.
            return displayableText.fullTextValue.stringValue
        case .oversizeTextDownloading:
            return labelConfigForOversizeTextDownloading.stringValue
        case .remotelyDeleted:
            return labelConfigForRemotelyDeleted.stringValue
        }
    }
}
