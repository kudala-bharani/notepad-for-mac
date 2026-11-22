#import "LiveFormatting.h"

NSAttributedStringKey const NPBlockStyleAttribute = @"com.kudala.notepad.blockStyle";
NSAttributedStringKey const NPInlineStyleAttribute = @"com.kudala.notepad.inlineStyle";
NSAttributedStringKey const NPLinkDestinationAttribute = @"com.kudala.notepad.linkDestination";
NSAttributedStringKey const NPCodeInfoAttribute = @"com.kudala.notepad.codeInfo";
NSAttributedStringKey const NPListLevelAttribute = @"com.kudala.notepad.listLevel";
const NSUInteger NPMaxListLevel = 8;

static BOOL ReadUnsignedNumber(id value, NSUInteger *number) {
    if (![value isKindOfClass:NSNumber.class] || [value isKindOfClass:[@YES class]]) {
        return NO;
    }
    NSNumber *numericValue = value;
    if ([numericValue compare:@0] == NSOrderedAscending ||
        [numericValue compare:@(NSUIntegerMax)] == NSOrderedDescending) {
        return NO;
    }
    NSUInteger unsignedValue = numericValue.unsignedIntegerValue;
    if (![numericValue isEqualToNumber:@(unsignedValue)]) return NO;
    *number = unsignedValue;
    return YES;
}

static BOOL IsFormattingValueValid(NSAttributedStringKey attribute, id value) {
    if ([attribute isEqualToString:NPLinkDestinationAttribute]) {
        return [value isKindOfClass:NSString.class] && [value length] != 0;
    }
    if ([attribute isEqualToString:NPCodeInfoAttribute]) {
        return [value isKindOfClass:NSString.class] && [value length] != 0 &&
            [value rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location == NSNotFound;
    }
    NSUInteger number;
    if (!ReadUnsignedNumber(value, &number)) return NO;
    if ([attribute isEqualToString:NPListLevelAttribute]) return number > 0 && number <= NPMaxListLevel;
    if ([attribute isEqualToString:NPBlockStyleAttribute]) return number <= NPBlockCode;
    return (number & ~(NPInlineBold | NPInlineItalic | NPInlineCode | NPInlineStrike)) == 0;
}

static NSArray<NSArray *> *FormattingRuns(NSAttributedString *text, NSAttributedStringKey attribute) {
    NSMutableArray<NSArray *> *runs = [NSMutableArray array];
    if (text.length == 0) return runs;
    [text enumerateAttribute:attribute inRange:NSMakeRange(0, text.length) options:0
                   usingBlock:^(id value, NSRange range, BOOL *stop) {
        if (IsFormattingValueValid(attribute, value)) {
            [runs addObject:@[@(range.location), @(range.length), value]];
        }
    }];
    return runs;
}

static void RestoreFormattingRuns(NSMutableAttributedString *text, NSAttributedStringKey attribute, id runs) {
    if (![runs isKindOfClass:NSArray.class]) return;
    for (id item in runs) {
        if (![item isKindOfClass:NSArray.class] || [item count] != 3) continue;
        NSArray *run = item;
        NSUInteger start;
        NSUInteger length;
        if (!ReadUnsignedNumber(run[0], &start) || !ReadUnsignedNumber(run[1], &length) ||
            start >= text.length || length == 0 || length > text.length - start ||
            !IsFormattingValueValid(attribute, run[2])) {
            continue;
        }
        [text addAttribute:attribute value:run[2] range:NSMakeRange(start, length)];
    }
}

NSDictionary<NSString *, id> *NPFormattingSnapshot(NSAttributedString *text, NPBlockStyle trailingBlock) {
    NSMutableDictionary<NSString *, id> *snapshot = [NSMutableDictionary dictionary];
    NSArray<NSArray *> *blocks = FormattingRuns(text, NPBlockStyleAttribute);
    NSArray<NSArray *> *inlines = FormattingRuns(text, NPInlineStyleAttribute);
    NSArray<NSArray *> *links = FormattingRuns(text, NPLinkDestinationAttribute);
    NSArray<NSArray *> *codeInfo = FormattingRuns(text, NPCodeInfoAttribute);
    NSArray<NSArray *> *listLevels = FormattingRuns(text, NPListLevelAttribute);
    if (blocks.count) snapshot[@"blocks"] = blocks;
    if (inlines.count) snapshot[@"inlines"] = inlines;
    if (links.count) snapshot[@"links"] = links;
    if (codeInfo.count) snapshot[@"codeInfo"] = codeInfo;
    if (listLevels.count) snapshot[@"listLevels"] = listLevels;
    if (trailingBlock != NPBlockBody && trailingBlock <= NPBlockCode) {
        snapshot[@"trailingBlock"] = @(trailingBlock);
    }
    return snapshot;
}

NSMutableAttributedString *NPTextWithFormatting(NSString *text, NSDictionary *snapshot, NPBlockStyle *trailingBlock) {
    NSMutableAttributedString *styledText = [[NSMutableAttributedString alloc] initWithString:text];
    if (trailingBlock) *trailingBlock = NPBlockBody;
    if (![snapshot isKindOfClass:NSDictionary.class]) return styledText;

    RestoreFormattingRuns(styledText, NPBlockStyleAttribute, snapshot[@"blocks"]);
    RestoreFormattingRuns(styledText, NPInlineStyleAttribute, snapshot[@"inlines"]);
    RestoreFormattingRuns(styledText, NPLinkDestinationAttribute, snapshot[@"links"]);
    RestoreFormattingRuns(styledText, NPCodeInfoAttribute, snapshot[@"codeInfo"]);
    RestoreFormattingRuns(styledText, NPListLevelAttribute, snapshot[@"listLevels"]);
    NSUInteger block;
    if (trailingBlock && ReadUnsignedNumber(snapshot[@"trailingBlock"], &block) && block <= NPBlockCode) {
        *trailingBlock = block;
    }
    return styledText;
}

NSUInteger NPListLevelAt(NSAttributedString *text, NSUInteger location) {
    if (location >= text.length) return 0;
    NSUInteger level;
    id value = [text attribute:NPListLevelAttribute atIndex:location effectiveRange:NULL];
    return ReadUnsignedNumber(value, &level) && level <= NPMaxListLevel ? level : 0;
}
