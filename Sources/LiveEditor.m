#import "LiveEditor.h"
#import "EditorTypography.h"
#import "LiveMarkdown.h"
#import "TaskListEditing.h"

static NSRange ParagraphAt(NSString *text, NSUInteger position) {
    position = MIN(position, text.length);
    if (position == text.length && (!position || [NSCharacterSet.newlineCharacterSet characterIsMember:[text characterAtIndex:position - 1]])) {
        return NSMakeRange(position, 0);
    }
    return [text paragraphRangeForRange:NSMakeRange(position, 0)];
}

static BOOL IsHeading(NPBlockStyle style) {
    return style >= NPBlockHeading1 && style <= NPBlockHeading6;
}

static BOOL IsTask(NPBlockStyle style) {
    return style == NPBlockTaskUnchecked || style == NPBlockTaskChecked;
}

static BOOL IsList(NPBlockStyle style) {
    return style == NPBlockBullet || style == NPBlockNumbered || IsTask(style);
}

static NSRect TaskBoxRect(NSRect line, NSPoint origin, CGFloat size) {
    return NSMakeRect(origin.x + 4, origin.y + NSMidY(line) - size / 2, size, size);
}

static void SetBlock(NSMutableAttributedString *text, NPBlockStyle style) {
    NSRange range = NSMakeRange(0, text.length);
    if (style != NPBlockCode) [text removeAttribute:NPCodeInfoAttribute range:range];
    if (!IsList(style)) [text removeAttribute:NPListLevelAttribute range:range];
    if (style == NPBlockBody) [text removeAttribute:NPBlockStyleAttribute range:range];
    else [text addAttribute:NPBlockStyleAttribute value:@(style) range:range];
}

static void SetListLevel(NSMutableAttributedString *text, NSUInteger level) {
    NSRange range = NSMakeRange(0, text.length);
    if (level) [text addAttribute:NPListLevelAttribute value:@(MIN(level, NPMaxListLevel)) range:range];
    else [text removeAttribute:NPListLevelAttribute range:range];
}

@interface NPLiveEditor ()
@property (nonatomic) NPBlockStyle trailingBlock;
@property (nonatomic) NSUInteger trailingListLevel;
@property (nonatomic) CGFloat listMarkerWidth;
@property (nonatomic) CGFloat editorTextSize;
@property (nonatomic, copy) NSString *preferredFontName;
@property (nonatomic) NPInlineStyle pairedTypingStyle;
@property (nonatomic) NSUInteger pairedTypingCaret;
@property (nonatomic) BOOL insertingPairedText;
@end

@implementation NPLiveEditor

@synthesize tabUndoManager = _tabUndoManager;

- (void)setTabUndoManager:(NSUndoManager *)manager {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    if (_tabUndoManager) {
        [center removeObserver:self name:NSUndoManagerDidUndoChangeNotification object:_tabUndoManager];
        [center removeObserver:self name:NSUndoManagerDidRedoChangeNotification object:_tabUndoManager];
    }
    _tabUndoManager = manager;
    if (manager) {
        [center addObserver:self selector:@selector(restyleAfterUndo:) name:NSUndoManagerDidUndoChangeNotification object:manager];
        [center addObserver:self selector:@selector(restyleAfterUndo:) name:NSUndoManagerDidRedoChangeNotification object:manager];
    }
}

- (CGFloat)effectiveTextSize {
    return NPConstrainEditorTextSize(self.editorTextSize);
}

- (void)configureTextSize:(CGFloat)size fontName:(NSString *)fontName {
    CGFloat newSize = NPConstrainEditorTextSize(size);
    if (self.editorTextSize == newSize && (self.preferredFontName == fontName || [self.preferredFontName isEqualToString:fontName])) return;
    self.editorTextSize = newSize;
    self.preferredFontName = fontName;
    [self restyleDocument];
}

- (void)restyleAfterUndo:(NSNotification *)notification {
    [self restyleDocument];
}

- (void)restyleDocument {
    NSTextStorage *storage = self.textStorage;
    NSAttributedString *styled = [self styledText:storage];
    [storage beginEditing];
    [styled enumerateAttributesInRange:NSMakeRange(0, styled.length) options:0 usingBlock:^(NSDictionary *attributes, NSRange range, BOOL *stop) {
        [storage setAttributes:attributes range:range];
    }];
    [storage endEditing];
    [self refreshTypingAttributes];
    [self setNeedsDisplay:YES];
}

- (CGFloat)listMarkerGap {
    return [self effectiveTextSize] * 0.5;
}

- (CGFloat)listTextIndentAtLevel:(NSUInteger)level {
    CGFloat depth = MIN(level, NPMaxListLevel) * [self effectiveTextSize] * 2;
    return 4 + depth + self.listMarkerWidth + [self listMarkerGap];
}

- (CGFloat)markerWidthForDocument:(NSAttributedString *)document {
    NSUInteger numberedCount = 0;
    NSUInteger position = 0;
    NSString *text = document.string;
    while (position < text.length) {
        NSRange paragraph = ParagraphAt(text, position);
        if ([[document attribute:NPBlockStyleAttribute atIndex:position effectiveRange:NULL] unsignedIntegerValue] == NPBlockNumbered) numberedCount++;
        position = NSMaxRange(paragraph);
    }
    NSFont *font = NPEditorFont(NPBlockBody, 0, [self effectiveTextSize], self.preferredFontName);
    if (self.trailingBlock == NPBlockNumbered) numberedCount++;
    NSDictionary *attributes = @{NSFontAttributeName:font};
    CGFloat digitWidth = 0;
    for (NSUInteger digit = 0; digit <= 9; digit++) {
        NSString *symbol = [NSString stringWithFormat:@"%lu", (unsigned long)digit];
        digitWidth = MAX(digitWidth, [symbol sizeWithAttributes:attributes].width);
    }
    NSUInteger digits = 1;
    while (numberedCount >= 10) {
        numberedCount /= 10;
        digits++;
    }
    CGFloat numberWidth = digitWidth * digits + [@"." sizeWithAttributes:attributes].width;
    return MAX([self checkboxSize], numberWidth);
}

- (NSDictionary<NSAttributedStringKey, id> *)textAttributesForBlock:(NPBlockStyle)block
                                                     inlineStyle:(NPInlineStyle)inlineStyle link:(NSString *)link
                                                        codeInfo:(NSString *)codeInfo {
    NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
    if (IsHeading(block)) {
        paragraph.paragraphSpacing = block <= NPBlockHeading2 ? 6 : 4;
    }
    if (IsList(block)) {
        paragraph.headIndent = [self listTextIndentAtLevel:0];
        paragraph.firstLineHeadIndent = paragraph.headIndent;
    }
    if (block == NPBlockQuote || block == NPBlockCode) {
        paragraph.headIndent = MAX(14, [self effectiveTextSize] * 1.1);
        paragraph.firstLineHeadIndent = paragraph.headIndent;
    }
    NSMutableDictionary<NSAttributedStringKey, id> *attributes = [@{
        NSFontAttributeName: NPEditorFont(block, inlineStyle, [self effectiveTextSize], self.preferredFontName),
        NSForegroundColorAttributeName: NSColor.textColor,
        NSParagraphStyleAttributeName: paragraph,
    } mutableCopy];
    if (block != NPBlockBody) attributes[NPBlockStyleAttribute] = @(block);
    if (inlineStyle) attributes[NPInlineStyleAttribute] = @(inlineStyle);
    if ((inlineStyle & NPInlineStrike) || block == NPBlockTaskChecked) attributes[NSStrikethroughStyleAttributeName] = @(NSUnderlineStyleSingle);
    if (block == NPBlockCode && codeInfo.length) attributes[NPCodeInfoAttribute] = codeInfo;
    if (block == NPBlockCode || (inlineStyle & NPInlineCode)) {
        attributes[NSBackgroundColorAttributeName] = [NSColor.textColor colorWithAlphaComponent:0.07];
    }
    if (link.length) {
        attributes[NPLinkDestinationAttribute] = link;
        NSURL *url = [NSURL URLWithString:link];
        NSString *scheme = url.scheme.lowercaseString;
        BOOL web = [scheme isEqualToString:@"https"] || [scheme isEqualToString:@"http"];
        if ((web && url.host.length) || [scheme isEqualToString:@"mailto"]) attributes[NSLinkAttributeName] = url;
        attributes[NSForegroundColorAttributeName] = NSColor.linkColor;
        attributes[NSUnderlineStyleAttributeName] = @(NSUnderlineStyleSingle);
    }
    return attributes;
}

- (NSAttributedString *)styledText:(NSAttributedString *)semantic {
    self.listMarkerWidth = [self markerWidthForDocument:semantic];
    NSMutableAttributedString *result = [[NSMutableAttributedString alloc] initWithString:semantic.string];
    [semantic enumerateAttributesInRange:NSMakeRange(0, semantic.length) options:0
                           usingBlock:^(NSDictionary<NSAttributedStringKey, id> *attrs, NSRange range, BOOL *stop) {
        NPBlockStyle block = [attrs[NPBlockStyleAttribute] unsignedIntegerValue];
        NSMutableDictionary *presentation = [[self textAttributesForBlock:block
                                                       inlineStyle:[attrs[NPInlineStyleAttribute] unsignedIntegerValue]
                                                              link:attrs[NPLinkDestinationAttribute]
                                                          codeInfo:attrs[NPCodeInfoAttribute]] mutableCopy];
        if (IsList(block)) {
            NSUInteger level = NPListLevelAt(semantic, range.location);
            if (level) presentation[NPListLevelAttribute] = @(level);
            NSMutableParagraphStyle *paragraph = [presentation[NSParagraphStyleAttributeName] mutableCopy];
            paragraph.firstLineHeadIndent = [self listTextIndentAtLevel:level];
            paragraph.headIndent = paragraph.firstLineHeadIndent;
            presentation[NSParagraphStyleAttributeName] = paragraph;
        }
        [result setAttributes:presentation range:range];
    }];
    return result;
}


- (void)loadDocument:(NSAttributedString *)document trailingBlock:(NPBlockStyle)trailingBlock listLevel:(NSUInteger)listLevel {
    self.trailingBlock = trailingBlock;
    self.trailingListLevel = IsList(trailingBlock) ? MIN(NPMaxListLevel, listLevel) : 0;
    self.pairedTypingStyle = 0;
    [self.textStorage setAttributedString:[self styledText:document]];
    [self refreshTypingAttributes];
}

- (NSDictionary *)formattingSnapshot {
    NSMutableDictionary *snapshot = [NPFormattingSnapshot(self.textStorage, self.trailingBlock) mutableCopy];
    if (self.trailingListLevel && IsList(self.trailingBlock)) snapshot[@"trailingListLevel"] = @(self.trailingListLevel);
    return snapshot;
}

- (NPBlockStyle)blockForParagraph:(NSRange)paragraph {
    if (!paragraph.length) return self.trailingBlock;
    return [[self.textStorage attribute:NPBlockStyleAttribute atIndex:paragraph.location effectiveRange:NULL] unsignedIntegerValue];
}

- (NSUInteger)listLevelForParagraph:(NSRange)paragraph {
    if (!IsList([self blockForParagraph:paragraph])) return 0;
    return paragraph.length ? NPListLevelAt(self.textStorage, paragraph.location) : self.trailingListLevel;
}

- (NSString *)codeInfoForParagraph:(NSRange)paragraph {
    if ([self blockForParagraph:paragraph] != NPBlockCode) return nil;
    if (paragraph.length) return [self.textStorage attribute:NPCodeInfoAttribute atIndex:paragraph.location effectiveRange:NULL];
    if (!paragraph.location) return nil;
    return [self.textStorage attribute:NPCodeInfoAttribute atIndex:paragraph.location - 1 effectiveRange:NULL];
}

- (void)refreshTypingAttributes {
    if (self.hasMarkedText) return;
    NSRange selection = self.selectedRange;
    if (!self.insertingPairedText && (selection.length || selection.location != self.pairedTypingCaret)) {
        self.pairedTypingStyle = 0;
    }
    NSString *text = self.string;
    NSUInteger location = MIN(selection.location, text.length);
    NSRange paragraph = ParagraphAt(text, location);
    NPInlineStyle inlineStyle = 0;
    NSString *link = nil;
    if (location > paragraph.location && location < NSMaxRange(paragraph)) {
        NSDictionary *before = [self.textStorage attributesAtIndex:location - 1 effectiveRange:NULL];
        NSDictionary *after = [self.textStorage attributesAtIndex:location effectiveRange:NULL];
        inlineStyle = [before[NPInlineStyleAttribute] unsignedIntegerValue] & [after[NPInlineStyleAttribute] unsignedIntegerValue];
        if ([before[NPLinkDestinationAttribute] isEqual:after[NPLinkDestinationAttribute]]) link = after[NPLinkDestinationAttribute];
    }
    NPBlockStyle block = [self blockForParagraph:paragraph];
    NSMutableDictionary *attributes = [[self textAttributesForBlock:block inlineStyle:inlineStyle | self.pairedTypingStyle link:link codeInfo:[self codeInfoForParagraph:paragraph]] mutableCopy];
    if (IsList(block)) {
        NSUInteger level = [self listLevelForParagraph:paragraph];
        if (level) attributes[NPListLevelAttribute] = @(level);
        NSMutableParagraphStyle *style = [attributes[NSParagraphStyleAttributeName] mutableCopy];
        style.firstLineHeadIndent = [self listTextIndentAtLevel:level];
        style.headIndent = style.firstLineHeadIndent;
        attributes[NSParagraphStyleAttributeName] = style;
    }
    self.typingAttributes = attributes;
}

- (BOOL)replaceRange:(NSRange)range withAttributedText:(NSAttributedString *)replacement
       trailingBlock:(NPBlockStyle)trailing selection:(NSRange)selection actionName:(NSString *)name {
    NSUInteger level = IsList(trailing) ? self.trailingListLevel : 0;
    return [self replaceRange:range withAttributedText:replacement trailingBlock:trailing listLevel:level selection:selection actionName:name];
}

- (BOOL)replaceRange:(NSRange)range withAttributedText:(NSAttributedString *)replacement
       trailingBlock:(NPBlockStyle)trailing listLevel:(NSUInteger)level selection:(NSRange)selection actionName:(NSString *)name {
    NSUndoManager *undo = self.tabUndoManager;
    [self breakUndoCoalescing];
    [undo disableUndoRegistration];
    BOOL allowed = [self shouldChangeTextInRange:range replacementString:replacement.string];
    [undo enableUndoRegistration];
    if (!allowed) return NO;

    NSAttributedString *previous = [self.textStorage attributedSubstringFromRange:range];
    NSRange previousSelection = self.selectedRange;
    NPBlockStyle previousTrailing = self.trailingBlock;
    NSUInteger previousLevel = self.trailingListLevel;
    NSRange insertedRange = NSMakeRange(range.location, replacement.length);
    [undo registerUndoWithTarget:self handler:^(NPLiveEditor *editor) {
        [editor replaceRange:insertedRange withAttributedText:previous
               trailingBlock:previousTrailing listLevel:previousLevel selection:previousSelection actionName:name];
    }];
    [undo setActionName:name];

    self.pairedTypingStyle = 0;
    [self.textStorage replaceCharactersInRange:range withAttributedString:replacement];
    self.trailingBlock = trailing;
    self.trailingListLevel = IsList(trailing) ? MIN(NPMaxListLevel, level) : 0;
    [self setSelectedRange:selection];
    [self didChangeText];
    [self refreshTypingAttributes];
    [self scrollRangeToVisible:selection];
    [self setNeedsDisplay:YES];
    return YES;
}

- (void)didChangeText {
    [self restyleDocument];
    [super didChangeText];
}

- (void)applyBlockStyle:(NPBlockStyle)style {
    NSRange selection = self.selectedRange;
    if (selection.location == NSNotFound) return;
    NSRange first = ParagraphAt(self.string, selection.location);
    NSRange last = ParagraphAt(self.string, selection.length ? NSMaxRange(selection) - 1 : selection.location);
    [self setBlockStyle:style inRange:NSUnionRange(first, last) selection:selection actionName:@"Paragraph Style"];
}

- (void)setBlockStyle:(NPBlockStyle)style inRange:(NSRange)affected selection:(NSRange)selection actionName:(NSString *)name {
    NSMutableAttributedString *replacement = [[self.textStorage attributedSubstringFromRange:affected] mutableCopy];
    SetBlock(replacement, style);
    NSRange finalParagraph = ParagraphAt(self.string, self.string.length);
    BOOL includesFinal = NSMaxRange(affected) == self.string.length && (finalParagraph.length || !affected.length);
    NPBlockStyle trailing = includesFinal ? style : self.trailingBlock;
    [self replaceRange:affected withAttributedText:replacement trailingBlock:trailing selection:selection actionName:name];
}

- (BOOL)hasTaskAtSelection {
    NSUInteger caret = self.selectedRange.location;
    return caret != NSNotFound && IsTask([self blockForParagraph:ParagraphAt(self.string, caret)]);
}

- (void)toggleTaskInParagraph:(NSRange)paragraph {
    NSRange replacementRange;
    NSRange selection;
    NPBlockStyle trailing;
    NSUInteger level;
    NSAttributedString *replacement = NPTaskListByToggling(self.textStorage, self.trailingBlock, self.trailingListLevel,
        self.selectedRange, paragraph.location, &replacementRange, &selection, &trailing, &level);
    if (!replacement) return;
    [self replaceRange:replacementRange withAttributedText:replacement trailingBlock:trailing listLevel:level
              selection:selection actionName:@"Toggle Checkbox"];
}

- (void)toggleTaskAtSelection {
    if ([self hasTaskAtSelection]) [self toggleTaskInParagraph:ParagraphAt(self.string, self.selectedRange.location)];
}

- (void)toggleInlineStyle:(NPInlineStyle)style {
    NSRange selection = self.selectedRange;
    if (!selection.length || selection.location == NSNotFound) return;
    NSAttributedString *selected = [self.textStorage attributedSubstringFromRange:selection];
    NSMutableAttributedString *replacement = [selected mutableCopy];
    NSRange all = NSMakeRange(0, replacement.length);
    BOOL remove = ([[selected attribute:NPInlineStyleAttribute atIndex:0 effectiveRange:NULL] unsignedIntegerValue] & style) == style;
    [selected enumerateAttribute:NPInlineStyleAttribute inRange:all options:0 usingBlock:^(NSNumber *value, NSRange range, BOOL *stop) {
        NPInlineStyle existing = value.unsignedIntegerValue;
        NPInlineStyle next = remove ? (existing & ~style) : (existing | style);
        if (next) [replacement addAttribute:NPInlineStyleAttribute value:@(next) range:range];
        else [replacement removeAttribute:NPInlineStyleAttribute range:range];
    }];
    [self replaceRange:selection withAttributedText:replacement trailingBlock:self.trailingBlock
              selection:selection actionName:style == NPInlineBold ? @"Bold" : @"Italic"];
}

- (BOOL)changeListLevelBy:(NSInteger)delta {
    NSRange selection = self.selectedRange;
    if (selection.location == NSNotFound || selection.length || self.hasMarkedText) return NO;
    NSRange paragraph = ParagraphAt(self.string, selection.location);
    if (!IsList([self blockForParagraph:paragraph])) return NO;
    NSString *content = [self.string substringWithRange:paragraph];
    BOOL empty = ![content stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length;
    if (selection.location != paragraph.location && !empty) return NO;
    NSUInteger level = [self listLevelForParagraph:paragraph];
    if (delta < 0 && !level) return YES;
    if (delta > 0) {
        if (level >= NPMaxListLevel || !paragraph.location) return YES;
        NSRange previous = ParagraphAt(self.string, paragraph.location - 1);
        if (!IsList([self blockForParagraph:previous]) || [self listLevelForParagraph:previous] < level) return YES;
    }

    NSUInteger end = NSMaxRange(paragraph);
    while (end < self.string.length) {
        NSRange child = ParagraphAt(self.string, end);
        if (!IsList([self blockForParagraph:child]) || [self listLevelForParagraph:child] <= level) break;
        if (delta > 0 && [self listLevelForParagraph:child] >= NPMaxListLevel) return YES;
        end = NSMaxRange(child);
    }
    NSRange affected = NSMakeRange(paragraph.location, end - paragraph.location);
    NSMutableAttributedString *replacement = [[self.textStorage attributedSubstringFromRange:affected] mutableCopy];
    NSUInteger position = 0;
    while (position < replacement.length) {
        NSRange child = ParagraphAt(replacement.string, position);
        NSUInteger childLevel = NPListLevelAt(replacement, position);
        NSUInteger next = delta > 0 ? MIN(NPMaxListLevel, childLevel + 1) : childLevel - 1;
        if (next) [replacement addAttribute:NPListLevelAttribute value:@(next) range:child];
        else [replacement removeAttribute:NPListLevelAttribute range:child];
        position = NSMaxRange(child);
    }
    NSUInteger trailing = self.trailingListLevel;
    NSRange finalParagraph = ParagraphAt(self.string, self.string.length);
    if (end == self.string.length && (finalParagraph.length || !paragraph.length ||
        (IsList(self.trailingBlock) && self.trailingListLevel > level))) {
        trailing = delta > 0 ? MIN(NPMaxListLevel, trailing + 1) : (trailing ? trailing - 1 : 0);
    }
    [self replaceRange:affected withAttributedText:replacement trailingBlock:self.trailingBlock listLevel:trailing
              selection:selection actionName:delta > 0 ? @"Indent List" : @"Outdent List"];
    return YES;
}

- (void)insertTab:(id)sender {
    if (![self changeListLevelBy:1]) [super insertTab:sender];
}

- (void)insertBacktab:(id)sender {
    if (![self changeListLevelBy:-1]) [super insertBacktab:sender];
}

- (BOOL)applyBlockShortcutAt:(NSUInteger)caret {
    NSRange paragraph = ParagraphAt(self.string, caret);
    if (caret <= paragraph.location || caret - paragraph.location > 6) return NO;
    NPBlockStyle currentStyle = [self blockForParagraph:paragraph];
    if (currentStyle != NPBlockBody && !IsHeading(currentStyle)) return NO;
    NSUInteger prefixLength = caret - paragraph.location;
    NSString *marker = [self.string substringWithRange:NSMakeRange(paragraph.location, prefixLength)];
    NPBlockStyle style = NPBlockBody;
    if ([marker rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"#"].invertedSet].location == NSNotFound) {
        style = (NPBlockStyle)marker.length;
    } else if (currentStyle != NPBlockBody) {
        return NO;
    } else if ([marker isEqualToString:@"-"] || [marker isEqualToString:@"+"] || [marker isEqualToString:@"*"]) {
        style = NPBlockBullet;
    } else if ([marker isEqualToString:@"1."]) {
        style = NPBlockNumbered;
    } else if ([marker isEqualToString:@">"]) {
        style = NPBlockQuote;
    }
    if (style == NPBlockBody) return NO;

    return [self replaceBlockPrefixInParagraph:paragraph through:caret withStyle:style];
}

- (BOOL)applyTaskShortcut:(NSString *)character at:(NSUInteger)caret {
    NSRange paragraph = ParagraphAt(self.string, caret);
    NPBlockStyle block = [self blockForParagraph:paragraph];
    if ((block != NPBlockBody && block != NPBlockBullet) || caret <= paragraph.location || caret - paragraph.location > 3) return NO;
    NSString *prefix = [self.string substringWithRange:NSMakeRange(paragraph.location, caret - paragraph.location)];
    if ([character isEqualToString:@"]"] && ([prefix isEqualToString:@"["] || [prefix isEqualToString:@"[ "])) {
        return [self replaceBlockPrefixInParagraph:paragraph through:caret withStyle:NPBlockTaskUnchecked];
    }
    if ([character isEqualToString:@" "] && [prefix.lowercaseString isEqualToString:@"[x]"]) {
        return [self replaceBlockPrefixInParagraph:paragraph through:caret withStyle:NPBlockTaskChecked];
    }
    return NO;
}

- (BOOL)replaceBlockPrefixInParagraph:(NSRange)paragraph through:(NSUInteger)caret withStyle:(NPBlockStyle)style {
    NSRange remainder = NSMakeRange(caret, NSMaxRange(paragraph) - caret);
    NSMutableAttributedString *replacement = [[self.textStorage attributedSubstringFromRange:remainder] mutableCopy];
    SetBlock(replacement, style);
    NPBlockStyle trailing = NSMaxRange(paragraph) == self.string.length && ParagraphAt(self.string, self.string.length).length
        ? style : self.trailingBlock;
    return [self replaceRange:paragraph withAttributedText:replacement trailingBlock:trailing
                       selection:NSMakeRange(paragraph.location, 0) actionName:@"Markdown Formatting"];
}

- (BOOL)applyInlineShortcut:(NSString *)character at:(NSUInteger)caret {
    if (![@"*_`)~" containsString:character]) return NO;
    NSNumber *inlineStyle = self.typingAttributes[NPInlineStyleAttribute];
    if (inlineStyle.unsignedIntegerValue & NPInlineCode) return NO;
    NSRange paragraph = ParagraphAt(self.string, caret);
    if (caret < paragraph.location) return NO;
    NSString *beforeCaret = [self.string substringWithRange:NSMakeRange(paragraph.location, caret - paragraph.location)];
    NSString *candidate = [beforeCaret stringByAppendingString:character];
    NPInlineMatch *match = NPMarkdownInlineEndingAt(candidate, candidate.length);
    if (!match || !match.contentRange.length) return NO;
    NSRange replaced = NSMakeRange(paragraph.location + match.sourceRange.location, match.sourceRange.length - 1);
    NSRange contentRange = NSMakeRange(paragraph.location + match.contentRange.location, match.contentRange.length);
    NPInlineStyle style = match.style;
    NSUInteger delimiterLength = match.contentRange.location - match.sourceRange.location;
    if (style == NPInlineBold && delimiterLength == 2 && [candidate characterAtIndex:match.sourceRange.location] == '_') style = NPInlineItalic;
    NSAttributedString *content = [self.textStorage attributedSubstringFromRange:contentRange];
    NSMutableAttributedString *replacement = [content mutableCopy];
    NSRange all = NSMakeRange(0, content.length);
    SetBlock(replacement, [self blockForParagraph:paragraph]);
    if (style) {
        [content enumerateAttribute:NPInlineStyleAttribute inRange:all options:0 usingBlock:^(NSNumber *value, NSRange range, BOOL *stop) {
            NPInlineStyle existing = style == NPInlineCode ? 0 : value.unsignedIntegerValue;
            [replacement addAttribute:NPInlineStyleAttribute value:@(style | existing) range:range];
        }];
    }
    if (style == NPInlineCode) [replacement removeAttribute:NPLinkDestinationAttribute range:all];
    if (match.destination) [replacement addAttribute:NPLinkDestinationAttribute value:match.destination range:all];
    return [self replaceRange:replaced withAttributedText:replacement trailingBlock:self.trailingBlock
                       selection:NSMakeRange(replaced.location + replacement.length, 0) actionName:@"Markdown Formatting"];
}

- (BOOL)startPairedTypingWith:(NSString *)input at:(NSUInteger)caret {
    NSString *text = self.string;
    if (!caret || caret >= text.length || [@"*_" containsString:input] ||
        ![input stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length ||
        ([self.typingAttributes[NPInlineStyleAttribute] unsignedIntegerValue] & NPInlineCode)) return NO;
    unichar marker = [text characterAtIndex:caret - 1];
    if ((marker != '*' && marker != '_') || [text characterAtIndex:caret] != marker) return NO;

    NSUInteger start = caret;
    NSUInteger end = caret;
    while (start > 0 && [text characterAtIndex:start - 1] == marker) start--;
    while (end < text.length && [text characterAtIndex:end] == marker) end++;
    if (caret - start != end - caret || caret - start > 2) return NO;
    NSUInteger escapeStart = start;
    while (escapeStart > 0 && [text characterAtIndex:escapeStart - 1] == '\\') escapeStart--;
    if ((start - escapeStart) % 2) return NO;

    NPInlineStyle style = (marker == '*' ? NPInlineBold : NPInlineItalic) | [self.typingAttributes[NPInlineStyleAttribute] unsignedIntegerValue];
    NPBlockStyle block = [self blockForParagraph:ParagraphAt(text, caret)];
    NSMutableAttributedString *replacement = [[NSMutableAttributedString alloc] initWithString:input attributes:[self textAttributesForBlock:block inlineStyle:style link:nil codeInfo:nil]];
    if (IsList(block)) SetListLevel(replacement, [self listLevelForParagraph:ParagraphAt(text, caret)]);
    NSRange selection = NSMakeRange(start + input.length, 0);
    if (![self replaceRange:NSMakeRange(start, end - start) withAttributedText:replacement trailingBlock:self.trailingBlock
                  selection:selection actionName:@"Markdown Formatting"]) return NO;
    self.pairedTypingStyle = style;
    self.pairedTypingCaret = selection.location;
    [self refreshTypingAttributes];
    return YES;
}

- (BOOL)endPairedTyping {
    if (!self.pairedTypingStyle) return NO;
    self.pairedTypingStyle = 0;
    [self refreshTypingAttributes];
    return YES;
}

- (void)insertText:(id)value replacementRange:(NSRange)replacementRange {
    NSRange target = replacementRange.location == NSNotFound ? self.selectedRange : replacementRange;
    NSString *input = [value isKindOfClass:NSAttributedString.class] ? [value string] : value;
    if (!self.hasMarkedText && [input isKindOfClass:NSString.class] && input.length &&
        [input rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location == NSNotFound &&
        target.location != NSNotFound && target.location <= self.string.length && target.length == 0 &&
        [self blockForParagraph:ParagraphAt(self.string, target.location)] != NPBlockCode) {
        if (self.pairedTypingStyle && target.location == self.pairedTypingCaret) {
            [self refreshTypingAttributes];
            self.insertingPairedText = YES;
            [super insertText:input replacementRange:replacementRange];
            self.insertingPairedText = NO;
            self.pairedTypingCaret = target.location + input.length;
            [self refreshTypingAttributes];
            return;
        }
        if ([self startPairedTypingWith:input at:target.location]) return;
        if (input.length == 1) {
            if ([@"] " containsString:input] && [self applyTaskShortcut:input at:target.location]) return;
            if ([input isEqualToString:@" "] && [self applyBlockShortcutAt:target.location]) return;
            if ([self applyInlineShortcut:input at:target.location]) return;
        }
    }
    [self refreshTypingAttributes];
    [super insertText:value replacementRange:replacementRange];
}

- (void)moveRight:(id)sender {
    if (![self endPairedTyping]) [super moveRight:sender];
}

- (void)moveForward:(id)sender {
    if (![self endPairedTyping]) [super moveForward:sender];
}

- (void)cancelOperation:(id)sender {
    if (![self endPairedTyping]) [super cancelOperation:sender];
}

- (BOOL)applyCodeFenceToParagraph:(NSRange)paragraph style:(NPBlockStyle)style caret:(NSUInteger)caret {
    if (style != NPBlockBody && style != NPBlockCode) return NO;
    NSUInteger contentEnd = [self contentEndOfParagraph:paragraph];
    if (caret != contentEnd || contentEnd - paragraph.location < 3) return NO;
    NSString *line = [self.string substringWithRange:NSMakeRange(paragraph.location, contentEnd - paragraph.location)];
    if (![line hasPrefix:@"```"] || [line hasPrefix:@"````"]) return NO;
    NSString *info = [[line substringFromIndex:3] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if ((style == NPBlockCode && info.length) || [info containsString:@"`"]) return NO;

    NPBlockStyle newStyle = style == NPBlockBody ? NPBlockCode : NPBlockBody;
    NSString *ending = [self.string substringWithRange:NSMakeRange(contentEnd, NSMaxRange(paragraph) - contentEnd)];
    BOOL needsInfoLine = newStyle == NPBlockCode && info.length && !ending.length;
    if (needsInfoLine) ending = @"\n";
    NSDictionary *attributes = [self textAttributesForBlock:newStyle inlineStyle:0 link:nil codeInfo:info];
    NSAttributedString *replacement = [[NSAttributedString alloc] initWithString:ending attributes:attributes];
    BOOL atEnd = NSEqualRanges(paragraph, ParagraphAt(self.string, self.string.length));
    NPBlockStyle trailing = atEnd ? (needsInfoLine ? NPBlockBody : newStyle) : self.trailingBlock;
    return [self replaceRange:paragraph withAttributedText:replacement trailingBlock:trailing
                    selection:NSMakeRange(paragraph.location, 0) actionName:@"Code Block"];
}

- (void)insertNewline:(id)sender {
    [self endPairedTyping];
    NSRange selection = self.selectedRange;
    if (selection.location == NSNotFound || selection.length || self.hasMarkedText) {
        [super insertNewline:sender];
        return;
    }
    NSUInteger caret = selection.location;
    NSRange paragraph = ParagraphAt(self.string, caret);
    NPBlockStyle style = [self blockForParagraph:paragraph];
    if ([self applyCodeFenceToParagraph:paragraph style:style caret:caret]) return;
    if (style == NPBlockBody) {
        [super insertNewline:sender];
        return;
    }
    if (IsHeading(style) && caret == paragraph.location && caret < [self contentEndOfParagraph:paragraph]) {
        NSAttributedString *blankLine = [[NSAttributedString alloc] initWithString:@"\n"];
        [self replaceRange:NSMakeRange(caret, 0) withAttributedText:blankLine trailingBlock:self.trailingBlock
                  selection:NSMakeRange(caret + 1, 0) actionName:@"Insert New Line"];
        return;
    }
    NSAttributedString *current = [self.textStorage attributedSubstringFromRange:paragraph];
    if ((IsList(style) || style == NPBlockQuote) && ![current.string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length) {
        if (IsList(style) && [self listLevelForParagraph:paragraph] > 0) {
            [self changeListLevelBy:-1];
            return;
        }
        [self applyBlockStyle:NPBlockBody];
        return;
    }
    NPBlockStyle nextStyle = IsTask(style) ? NPBlockTaskUnchecked : (IsList(style) || style == NPBlockCode || style == NPBlockQuote) ? style : NPBlockBody;
    NSUInteger offset = caret - paragraph.location;
    NSMutableAttributedString *replacement = [[current attributedSubstringFromRange:NSMakeRange(0, offset)] mutableCopy];
    NSMutableAttributedString *newline = [[NSMutableAttributedString alloc] initWithString:@"\n" attributes:[self textAttributesForBlock:style inlineStyle:0 link:nil codeInfo:[self codeInfoForParagraph:paragraph]]];
    NSUInteger currentLevel = [self listLevelForParagraph:paragraph];
    if (IsList(style)) SetListLevel(newline, currentLevel);
    [replacement appendAttributedString:newline];
    NSMutableAttributedString *rest = [[current attributedSubstringFromRange:NSMakeRange(offset, current.length - offset)] mutableCopy];
    SetBlock(rest, nextStyle);
    [replacement appendAttributedString:rest];
    NSRange end = ParagraphAt(self.string, self.string.length);
    NPBlockStyle trailing = (!paragraph.length || NSEqualRanges(paragraph, end)) ? nextStyle : self.trailingBlock;
    NSUInteger trailingLevel = (!paragraph.length || NSEqualRanges(paragraph, end)) ? currentLevel : self.trailingListLevel;
    [self replaceRange:paragraph withAttributedText:replacement trailingBlock:trailing listLevel:trailingLevel
              selection:NSMakeRange(caret + 1, 0) actionName:@"Insert New Line"];
}

- (NSUInteger)contentEndOfParagraph:(NSRange)paragraph {
    if (!paragraph.length) return paragraph.location;
    NSUInteger end;
    [self.string getParagraphStart:NULL end:NULL contentsEnd:&end forRange:NSMakeRange(paragraph.location, 0)];
    return end;
}

- (BOOL)joinParagraph:(NSRange)left withFollowing:(NSRange)right {
    NPBlockStyle style = [self blockForParagraph:left];
    NSUInteger leftLevel = [self listLevelForParagraph:left];
    if (style == [self blockForParagraph:right] && leftLevel == [self listLevelForParagraph:right]) return NO;
    NSUInteger caret = [self contentEndOfParagraph:left];
    NSRange removed = NSMakeRange(caret, NSMaxRange(right) - caret);
    NSMutableAttributedString *replacement = [[self.textStorage attributedSubstringFromRange:right] mutableCopy];
    SetBlock(replacement, style);
    if (IsList(style)) SetListLevel(replacement, leftLevel);
    NSRange last = ParagraphAt(self.string, self.string.length);
    NPBlockStyle trailing = NSEqualRanges(right, last) ? style : self.trailingBlock;
    NSUInteger trailingLevel = NSEqualRanges(right, last) ? leftLevel : self.trailingListLevel;
    return [self replaceRange:removed withAttributedText:replacement trailingBlock:trailing listLevel:trailingLevel
                       selection:NSMakeRange(caret, 0) actionName:@"Delete New Line"];
}

- (void)deleteBackward:(id)sender {
    NSRange selection = self.selectedRange;
    if (selection.location != NSNotFound && !selection.length && !self.hasMarkedText) {
        NSRange paragraph = ParagraphAt(self.string, selection.location);
        if (paragraph.location == selection.location) {
            if ([self blockForParagraph:paragraph] != NPBlockBody) {
                if (IsList([self blockForParagraph:paragraph]) && [self listLevelForParagraph:paragraph]) {
                    [self changeListLevelBy:-1];
                    return;
                }
                [self applyBlockStyle:NPBlockBody];
                return;
            }
            if (paragraph.location && [self joinParagraph:ParagraphAt(self.string, paragraph.location - 1) withFollowing:paragraph]) return;
        }
    }
    [super deleteBackward:sender];
}

- (void)deleteForward:(id)sender {
    NSRange selection = self.selectedRange;
    if (selection.location != NSNotFound && !selection.length && !self.hasMarkedText) {
        NSRange paragraph = ParagraphAt(self.string, selection.location);
        NSUInteger end = NSMaxRange(paragraph);
        if (selection.location < end && selection.location == [self contentEndOfParagraph:paragraph] &&
            [self joinParagraph:paragraph withFollowing:ParagraphAt(self.string, end)]) return;
    }
    [super deleteForward:sender];
}

- (void)paste:(id)sender {
    NSString *plain = [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
    if (!plain.length) return;
    [self pasteLiteralText:plain];
}

- (void)pasteLiteralText:(NSString *)plain {
    if ([plain rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location == NSNotFound) {
        [self refreshTypingAttributes];
        [super insertText:plain replacementRange:self.selectedRange];
        return;
    }
    NSRange selection = self.selectedRange;
    if (selection.location == NSNotFound) return;
    NSRange first = ParagraphAt(plain, 0);
    NSRange initialParagraph = ParagraphAt(self.string, selection.location);
    NPBlockStyle initial = [self blockForParagraph:initialParagraph];
    NSMutableAttributedString *replacement = [[NSMutableAttributedString alloc] initWithString:plain];
    if (initial == NPBlockCode) {
        SetBlock(replacement, NPBlockCode);
        NSString *info = [self codeInfoForParagraph:initialParagraph];
        if (info.length) [replacement addAttribute:NPCodeInfoAttribute value:info range:NSMakeRange(0, replacement.length)];
        NPBlockStyle trailing = NSMaxRange(selection) == self.string.length ? NPBlockCode : self.trailingBlock;
        [self replaceRange:selection withAttributedText:replacement trailingBlock:trailing
                  selection:NSMakeRange(selection.location + plain.length, 0) actionName:@"Paste"];
        return;
    }
    if (initial != NPBlockBody) [replacement addAttribute:NPBlockStyleAttribute value:@(initial) range:first];
    NSUInteger initialLevel = [self listLevelForParagraph:initialParagraph];
    if (initialLevel) [replacement addAttribute:NPListLevelAttribute value:@(initialLevel) range:first];

    // The suffix of a paragraph split by pasted lines belongs to the new body line.
    NSRange last = ParagraphAt(self.string, NSMaxRange(selection));
    if (last.length && [self blockForParagraph:last] != NPBlockBody && NSMaxRange(selection) < NSMaxRange(last)) {
        NSRange suffix = NSMakeRange(NSMaxRange(selection), NSMaxRange(last) - NSMaxRange(selection));
        NSMutableAttributedString *rest = [[self.textStorage attributedSubstringFromRange:suffix] mutableCopy];
        SetBlock(rest, NPBlockBody);
        [replacement appendAttributedString:rest];
        selection.length += suffix.length;
    }
    NPBlockStyle trailing = NSMaxRange(selection) == self.string.length ? NPBlockBody : self.trailingBlock;
    [self replaceRange:selection withAttributedText:replacement trailingBlock:trailing
              selection:NSMakeRange(selection.location + plain.length, 0) actionName:@"Paste"];
}

- (void)pasteAsMarkdown:(id)sender {
    NSString *source = [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
    NSRange selection = self.selectedRange;
    if (!source.length || selection.location == NSNotFound) return;
    NSRange left = ParagraphAt(self.string, selection.location);
    NPBlockStyle leftStyle = [self blockForParagraph:left];
    if (leftStyle == NPBlockCode) {
        [self pasteLiteralText:source];
        return;
    }

    NPBlockStyle decodedTrailing = NPBlockBody;
    NSUInteger decodedTrailingLevel = 0;
    NSMutableAttributedString *decoded = NPDecodeMarkdownWithListLevel(source, &decodedTrailing, &decodedTrailingLevel);
    if (!decoded.length && decodedTrailing == NPBlockBody) return;
    NPBlockStyle firstStyle = decoded.length ? [[decoded attribute:NPBlockStyleAttribute atIndex:0 effectiveRange:NULL] unsignedIntegerValue] : decodedTrailing;
    NPBlockStyle lastStyle = decoded.length ? [[decoded attribute:NPBlockStyleAttribute atIndex:decoded.length - 1 effectiveRange:NULL] unsignedIntegerValue] : decodedTrailing;
    NSUInteger lastLevel = decoded.length ? NPListLevelAt(decoded, decoded.length - 1) : decodedTrailingLevel;
    BOOL endsWithNewline = decoded.length && [NSCharacterSet.newlineCharacterSet characterIsMember:[decoded.string characterAtIndex:decoded.length - 1]];
    NSMutableAttributedString *replacement = [[NSMutableAttributedString alloc] initWithString:@""];
    if (firstStyle != NPBlockBody && selection.location > left.location) {
        NSDictionary *attributes = [self textAttributesForBlock:leftStyle inlineStyle:0 link:nil codeInfo:nil];
        NSMutableAttributedString *newline = [[NSMutableAttributedString alloc] initWithString:@"\n" attributes:attributes];
        if (IsList(leftStyle)) SetListLevel(newline, [self listLevelForParagraph:left]);
        [replacement appendAttributedString:newline];
    } else if (decoded.length && firstStyle == NPBlockBody && leftStyle != NPBlockBody) {
        NSRange insertedFirst = ParagraphAt(decoded.string, 0);
        [decoded addAttribute:NPBlockStyleAttribute value:@(leftStyle) range:insertedFirst];
        NSUInteger level = [self listLevelForParagraph:left];
        if (level) [decoded addAttribute:NPListLevelAttribute value:@(level) range:insertedFirst];
        if (NSMaxRange(insertedFirst) == decoded.length) lastStyle = leftStyle;
        if (NSMaxRange(insertedFirst) == decoded.length) lastLevel = level;
    }
    [replacement appendAttributedString:decoded];

    BOOL atEnd = NSMaxRange(selection) == self.string.length;
    NSRange right = ParagraphAt(self.string, NSMaxRange(selection));
    BOOL hasSuffix = NSMaxRange(selection) < [self contentEndOfParagraph:right];
    if (!atEnd && (decodedTrailing != NPBlockBody || (!endsWithNewline && hasSuffix && lastStyle != [self blockForParagraph:right]))) {
        NPBlockStyle lineStyle = decodedTrailing != NPBlockBody ? decodedTrailing : lastStyle;
        NSString *info = decoded.length ? [decoded attribute:NPCodeInfoAttribute atIndex:decoded.length - 1 effectiveRange:NULL] : nil;
        NSDictionary *attributes = [self textAttributesForBlock:lineStyle inlineStyle:0 link:nil codeInfo:info];
        NSMutableAttributedString *newline = [[NSMutableAttributedString alloc] initWithString:@"\n" attributes:attributes];
        NSUInteger level = decodedTrailing != NPBlockBody ? decodedTrailingLevel : lastLevel;
        if (IsList(lineStyle)) SetListLevel(newline, level);
        [replacement appendAttributedString:newline];
    }
    NPBlockStyle trailing = atEnd ? (endsWithNewline || !decoded.length ? decodedTrailing : lastStyle) : self.trailingBlock;
    NSUInteger trailingLevel = atEnd ? (endsWithNewline || !decoded.length ? decodedTrailingLevel : lastLevel) : self.trailingListLevel;
    [self replaceRange:selection withAttributedText:replacement trailingBlock:trailing listLevel:trailingLevel
              selection:NSMakeRange(selection.location + replacement.length, 0) actionName:@"Paste as Markdown"];
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    NSLayoutManager *layout = self.layoutManager;
    NSPoint origin = self.textContainerOrigin;
    NSString *text = self.string;
    NSRect containerRect = NSOffsetRect(dirtyRect, -origin.x, -origin.y);
    NSRange glyphs = [layout glyphRangeForBoundingRect:containerRect inTextContainer:self.textContainer];
    NSRange characters = [layout characterRangeForGlyphRange:glyphs actualGlyphRange:NULL];
    NSUInteger position = ParagraphAt(text, characters.location).location;
    while (position < text.length && position < NSMaxRange(characters)) {
        NSRange paragraph = ParagraphAt(text, position);
        NPBlockStyle block = [self blockForParagraph:paragraph];
        if (IsList(block) || block == NPBlockQuote) {
            NSUInteger glyph = [layout glyphIndexForCharacterAtIndex:position];
            NSRect line = [layout lineFragmentUsedRectForGlyphAtIndex:glyph effectiveRange:NULL];
            if (block == NPBlockQuote) {
                NSUInteger lastGlyph = [layout glyphIndexForCharacterAtIndex:NSMaxRange(paragraph) - 1];
                NSRect endLine = [layout lineFragmentUsedRectForGlyphAtIndex:lastGlyph effectiveRange:NULL];
                [self drawQuoteRuleFrom:NSMinY(line) to:NSMaxY(endLine) origin:origin];
            } else {
                [self drawListMarker:block inLine:line atPosition:position origin:origin];
            }
        }
        position = NSMaxRange(paragraph);
    }
    if (!ParagraphAt(text, text.length).length && (IsList(self.trailingBlock) || self.trailingBlock == NPBlockQuote)) {
        NSRect line = [self trailingListLine];
        if (NSIntersectsRect(dirtyRect, NSOffsetRect(line, origin.x, origin.y))) {
            if (self.trailingBlock == NPBlockQuote) [self drawQuoteRuleFrom:NSMinY(line) to:NSMaxY(line) origin:origin];
            else [self drawListMarker:self.trailingBlock inLine:line atPosition:text.length origin:origin];
        }
    }
}

- (void)drawQuoteRuleFrom:(CGFloat)top to:(CGFloat)bottom origin:(NSPoint)origin {
    [NSColor.tertiaryLabelColor setFill];
    NSRectFill(NSMakeRect(origin.x + 4, origin.y + top + 1, 2, MAX(1, bottom - top - 2)));
}

- (CGFloat)checkboxSize {
    return MAX(10, [self effectiveTextSize] * 0.93);
}

- (NSRect)trailingListLine {
    NSLayoutManager *layout = self.layoutManager;
    NSRect extra = layout.extraLineFragmentRect;
    if (layout.extraLineFragmentTextContainer == self.textContainer && NSHeight(extra) > 0 && NSWidth(extra) > 0) return extra;
    NSUInteger count = layout.numberOfGlyphs;
    CGFloat top = count ? NSMaxY([layout lineFragmentRectForGlyphAtIndex:count - 1 effectiveRange:NULL]) : 0;
    return NSMakeRect(0, top, 26, [layout defaultLineHeightForFont:NPEditorFont(NPBlockBody, 0, [self effectiveTextSize], self.preferredFontName)]);
}

- (void)drawListMarker:(NPBlockStyle)style inLine:(NSRect)line atPosition:(NSUInteger)position origin:(NSPoint)origin {
    if (IsTask(style)) {
        [self drawTaskBox:[self taskBoxInLine:line atPosition:position origin:origin] checked:style == NPBlockTaskChecked];
        return;
    }
    NSString *marker = @"•";
    if (style == NPBlockNumbered) {
        NSUInteger number = 1;
        NSUInteger level = [self listLevelForParagraph:ParagraphAt(self.string, position)];
        NSString *text = self.string;
        NSUInteger scan = position;
        while (scan > 0) {
            NSRange previous = ParagraphAt(text, scan - 1);
            NPBlockStyle previousStyle = [self blockForParagraph:previous];
            NSUInteger previousLevel = [self listLevelForParagraph:previous];
            if (previous.location >= scan || !IsList(previousStyle) || previousLevel < level) break;
            if (previousLevel == level) {
                if (previousStyle != NPBlockNumbered) break;
                number++;
            }
            scan = previous.location;
        }
        marker = [NSString stringWithFormat:@"%lu.", (unsigned long)number];
    }
    NSDictionary *attributes = @{
        NSFontAttributeName: NPEditorFont(NPBlockBody, 0, [self effectiveTextSize], self.preferredFontName),
        NSForegroundColorAttributeName: NSColor.textColor,
    };
    NSSize size = [marker sizeWithAttributes:attributes];
    CGFloat right = [self listMarkerRightAtPosition:position origin:origin];
    [marker drawAtPoint:NSMakePoint(right - size.width, origin.y + NSMidY(line) - size.height / 2) withAttributes:attributes];
}

- (CGFloat)listMarkerRightAtPosition:(NSUInteger)position origin:(NSPoint)origin {
    if (position < self.string.length) {
        NSLayoutManager *layout = self.layoutManager;
        NSUInteger glyph = [layout glyphIndexForCharacterAtIndex:position];
        NSRect fragment = [layout lineFragmentRectForGlyphAtIndex:glyph effectiveRange:NULL];
        NSPoint location = [layout locationForGlyphAtIndex:glyph];
        return origin.x + NSMinX(fragment) + location.x - [self listMarkerGap];
    }
    return origin.x + self.textContainer.lineFragmentPadding + [self listTextIndentAtLevel:self.trailingListLevel] - [self listMarkerGap];
}

- (NSRect)taskBoxInLine:(NSRect)line atPosition:(NSUInteger)position origin:(NSPoint)origin {
    CGFloat right = [self listMarkerRightAtPosition:position origin:origin];
    NSPoint markerOrigin = NSMakePoint(right - [self checkboxSize] - 4, origin.y);
    return TaskBoxRect(line, markerOrigin, [self checkboxSize]);
}

- (void)drawTaskBox:(NSRect)box checked:(BOOL)checked {
    NSBezierPath *outline = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(box, 0.6, 0.6) xRadius:2.5 yRadius:2.5];
    NSColor *color = checked ? NSColor.controlAccentColor : NSColor.secondaryLabelColor;
    [color setStroke];
    outline.lineWidth = 1.2;
    [outline stroke];
    if (!checked) return;

    NSBezierPath *tick = [NSBezierPath bezierPath];
    CGFloat size = NSWidth(box);
    [tick moveToPoint:NSMakePoint(NSMinX(box) + size * 0.23, NSMinY(box) + size * 0.54)];
    [tick lineToPoint:NSMakePoint(NSMinX(box) + size * 0.42, NSMinY(box) + size * 0.73)];
    [tick lineToPoint:NSMakePoint(NSMinX(box) + size * 0.77, NSMinY(box) + size * 0.31)];
    tick.lineWidth = 1.5;
    [tick stroke];
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSPoint origin = self.textContainerOrigin;
    if (event.clickCount == 1 && [self toggleTaskAtPoint:point origin:origin]) return;
    [super mouseDown:event];
}

- (BOOL)toggleTaskAtPoint:(NSPoint)point origin:(NSPoint)origin {
    NSLayoutManager *layout = self.layoutManager;
    [layout ensureLayoutForTextContainer:self.textContainer];
    NSRange last = ParagraphAt(self.string, self.string.length);
    if (!last.length && IsTask(self.trailingBlock) &&
        NSPointInRect(point, NSInsetRect([self taskBoxInLine:[self trailingListLine] atPosition:self.string.length origin:origin], -2, -2))) {
        [self toggleTaskInParagraph:last];
        return YES;
    }

    NSPoint containerPoint = NSMakePoint(point.x - origin.x, point.y - origin.y);
    NSUInteger glyph = [layout glyphIndexForPoint:containerPoint inTextContainer:self.textContainer fractionOfDistanceThroughGlyph:NULL];
    if (glyph >= layout.numberOfGlyphs) return NO;
    NSRange paragraph = ParagraphAt(self.string, [layout characterIndexForGlyphAtIndex:glyph]);
    if (!paragraph.length || !IsTask([self blockForParagraph:paragraph])) return NO;
    NSUInteger firstGlyph = [layout glyphIndexForCharacterAtIndex:paragraph.location];
    NSRect line = [layout lineFragmentUsedRectForGlyphAtIndex:firstGlyph effectiveRange:NULL];
    if (!NSPointInRect(point, NSInsetRect([self taskBoxInLine:line atPosition:paragraph.location origin:origin], -2, -2))) return NO;
    [self toggleTaskInParagraph:paragraph];
    return YES;
}

@end
