#import "TaskListEditing.h"

static BOOL IsTask(NPBlockStyle style) {
    return style == NPBlockTaskUnchecked || style == NPBlockTaskChecked;
}

static BOOL IsList(NPBlockStyle style) {
    return IsTask(style) || style == NPBlockBullet || style == NPBlockNumbered;
}

@interface NPTaskParagraph : NSObject
@property (nonatomic) NSRange range;
@property (nonatomic) NSUInteger contentEnd;
@property (nonatomic) NPBlockStyle style;
@property (nonatomic) NSUInteger level;
@end
@implementation NPTaskParagraph
@end

@interface NPTaskUnit : NSObject
@property (nonatomic) NSRange originalRange;
@property (nonatomic) NSUInteger originalBodyLength;
@property (nonatomic, strong) NSMutableAttributedString *body;
@property (nonatomic, copy) NSDictionary<NSAttributedStringKey, id> *endingAttributes;
@property (nonatomic) NPBlockStyle style;
@property (nonatomic) NSUInteger level;
@property (nonatomic) NSUInteger outputLocation;
@property (nonatomic) NSUInteger outputSeparatorLength;
@end
@implementation NPTaskUnit
@end

static NSArray<NPTaskParagraph *> *Paragraphs(NSAttributedString *document, NPBlockStyle trailingBlock,
                                             NSUInteger trailingListLevel) {
    NSMutableArray<NPTaskParagraph *> *paragraphs = [NSMutableArray array];
    NSString *text = document.string;
    NSUInteger position = 0;
    BOOL endsWithNewline = text.length == 0;
    while (position < text.length) {
        NSUInteger end;
        NSUInteger contentEnd;
        [text getParagraphStart:NULL end:&end contentsEnd:&contentEnd forRange:NSMakeRange(position, 0)];
        NPTaskParagraph *paragraph = [[NPTaskParagraph alloc] init];
        paragraph.range = NSMakeRange(position, end - position);
        paragraph.contentEnd = contentEnd;
        paragraph.style = [[document attribute:NPBlockStyleAttribute atIndex:position effectiveRange:NULL] unsignedIntegerValue];
        paragraph.level = MIN(NPMaxListLevel, [[document attribute:NPListLevelAttribute atIndex:position effectiveRange:NULL] unsignedIntegerValue]);
        [paragraphs addObject:paragraph];
        endsWithNewline = contentEnd < end;
        position = end;
    }
    if (endsWithNewline) {
        NPTaskParagraph *paragraph = [[NPTaskParagraph alloc] init];
        paragraph.range = NSMakeRange(text.length, 0);
        paragraph.contentEnd = text.length;
        paragraph.style = trailingBlock;
        paragraph.level = MIN(NPMaxListLevel, trailingListLevel);
        [paragraphs addObject:paragraph];
    }
    return paragraphs;
}

static BOOL InSiblingList(NPTaskParagraph *paragraph, NSUInteger level) {
    return IsList(paragraph.style) && paragraph.level >= level &&
        (paragraph.level > level || IsTask(paragraph.style));
}

static NSUInteger MappedPosition(NSUInteger position, BOOL preferPrevious,
                                 NSArray<NPTaskUnit *> *units, NSUInteger documentLength) {
    // A position at a task start follows that task, including a final empty task.
    if (!preferPrevious) {
        for (NPTaskUnit *unit in units) {
            if (position == unit.originalRange.location) return unit.outputLocation;
        }
    }
    for (NPTaskUnit *unit in units) {
        NSUInteger start = unit.originalRange.location;
        NSUInteger end = NSMaxRange(unit.originalRange);
        BOOL contains = position >= start && position < end;
        BOOL endsHere = position == end && (preferPrevious || end == documentLength);
        if (!contains && !endsHere) continue;
        NSUInteger offset = position - start;
        if (offset <= unit.originalBodyLength) return unit.outputLocation + offset;
        NSUInteger separatorOffset = offset - unit.originalBodyLength;
        return unit.outputLocation + unit.body.length + MIN(separatorOffset, unit.outputSeparatorLength);
    }
    return position;
}

NSAttributedString *NPTaskListByToggling(NSAttributedString *document, NPBlockStyle trailingBlock,
                                        NSUInteger trailingListLevel, NSRange selection,
                                        NSUInteger targetParagraphLocation, NSRange *replacementRange,
                                        NSRange *newSelection, NPBlockStyle *newTrailingBlock,
                                        NSUInteger *newTrailingListLevel) {
    *newTrailingBlock = trailingBlock;
    *newTrailingListLevel = trailingListLevel;
    selection.location = MIN(selection.location, document.length);
    selection.length = MIN(selection.length, document.length - selection.location);
    *newSelection = selection;
    *replacementRange = NSMakeRange(0, 0);
    if (targetParagraphLocation > document.length) return nil;

    NSArray<NPTaskParagraph *> *paragraphs = Paragraphs(document, trailingBlock, trailingListLevel);
    NSUInteger target = NSNotFound;
    for (NSUInteger index = 0; index < paragraphs.count; index++) {
        if (paragraphs[index].range.location == targetParagraphLocation) {
            target = index;
            break;
        }
    }
    if (target == NSNotFound || !IsTask(paragraphs[target].style)) return nil;
    NSUInteger level = paragraphs[target].level;
    NSUInteger first = target;
    NSUInteger scan = target;
    while (scan > 0 && InSiblingList(paragraphs[scan - 1], level)) {
        scan--;
        if (paragraphs[scan].level == level) first = scan;
    }
    NSUInteger end = target + 1;
    while (end < paragraphs.count && InSiblingList(paragraphs[end], level)) end++;

    NSMutableArray<NPTaskUnit *> *units = [NSMutableArray array];
    NSMutableArray<NSString *> *separators = [NSMutableArray array];
    NSUInteger index = first;
    while (index < end) {
        NSUInteger next = index + 1;
        while (next < end && paragraphs[next].level > level) next++;
        NPTaskParagraph *head = paragraphs[index];
        NPTaskParagraph *last = paragraphs[next - 1];
        NPTaskUnit *unit = [[NPTaskUnit alloc] init];
        unit.originalRange = NSMakeRange(head.range.location, NSMaxRange(last.range) - head.range.location);
        unit.originalBodyLength = last.contentEnd - head.range.location;
        unit.body = [[document attributedSubstringFromRange:NSMakeRange(head.range.location, unit.originalBodyLength)] mutableCopy];
        unit.style = head.style;
        unit.level = head.level;
        if (last.range.length) {
            unit.endingAttributes = [document attributesAtIndex:last.range.location effectiveRange:NULL];
        } else {
            NSMutableDictionary *attributes = [NSMutableDictionary dictionary];
            attributes[NPBlockStyleAttribute] = @(last.style);
            if (last.level) attributes[NPListLevelAttribute] = @(last.level);
            unit.endingAttributes = attributes;
        }
        if (index == target) {
            unit.style = head.style == NPBlockTaskChecked ? NPBlockTaskUnchecked : NPBlockTaskChecked;
            NSUInteger headLength = MIN(head.range.length, unit.body.length);
            if (headLength) [unit.body addAttribute:NPBlockStyleAttribute value:@(unit.style) range:NSMakeRange(0, headLength)];
            if (index == next - 1) {
                NSMutableDictionary *attributes = [unit.endingAttributes mutableCopy];
                attributes[NPBlockStyleAttribute] = @(unit.style);
                unit.endingAttributes = attributes;
            }
        }
        [units addObject:unit];
        [separators addObject:[document.string substringWithRange:NSMakeRange(last.contentEnd, NSMaxRange(last.range) - last.contentEnd)]];
        index = next;
    }

    NSMutableArray<NPTaskUnit *> *ordered = [NSMutableArray arrayWithCapacity:units.count];
    for (NPTaskUnit *unit in units) if (unit.style == NPBlockTaskUnchecked) [ordered addObject:unit];
    for (NPTaskUnit *unit in units) if (unit.style == NPBlockTaskChecked) [ordered addObject:unit];

    NSMutableAttributedString *result = [[NSMutableAttributedString alloc] initWithString:@""];
    NSUInteger originalStart = paragraphs[first].range.location;
    for (NSUInteger position = 0; position < ordered.count; position++) {
        NPTaskUnit *unit = ordered[position];
        unit.outputLocation = originalStart + result.length;
        [result appendAttributedString:unit.body];
        NSString *separator = separators[position];
        unit.outputSeparatorLength = separator.length;
        [result appendAttributedString:[[NSAttributedString alloc] initWithString:separator attributes:unit.endingAttributes]];
    }
    NPTaskParagraph *lastParagraph = paragraphs[end - 1];
    *replacementRange = NSMakeRange(originalStart, NSMaxRange(lastParagraph.range) - originalStart);
    NSUInteger mappedStart = MappedPosition(selection.location, NO, units, document.length);
    NSUInteger mappedEnd = selection.length ? MappedPosition(NSMaxRange(selection), YES, units, document.length) : mappedStart;
    NSUInteger newLength = document.length - replacementRange->length + result.length;
    NSUInteger start = MIN(mappedStart, mappedEnd);
    *newSelection = NSMakeRange(MIN(start, newLength), MIN(MAX(mappedStart, mappedEnd) - start, newLength - MIN(start, newLength)));

    if (end == paragraphs.count) {
        NPTaskUnit *lastUnit = ordered.lastObject;
        if (!lastUnit.outputSeparatorLength) {
            *newTrailingBlock = [[lastUnit.endingAttributes objectForKey:NPBlockStyleAttribute] unsignedIntegerValue];
            *newTrailingListLevel = [[lastUnit.endingAttributes objectForKey:NPListLevelAttribute] unsignedIntegerValue];
        }
    }
    return result;
}
