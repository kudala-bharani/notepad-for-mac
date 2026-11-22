#import "LiveMarkdown.h"

@interface NPInlineMatch ()
@property (nonatomic, readwrite) NSRange sourceRange;
@property (nonatomic, readwrite) NSRange contentRange;
@property (nonatomic, readwrite) NPInlineStyle style;
@property (nonatomic, copy, readwrite, nullable) NSString *destination;
@end

@implementation NPInlineMatch
@end

static NPInlineMatch *NPMatch(NSRange source, NSRange content, NPInlineStyle style, NSString *destination) {
    NPInlineMatch *match = [[NPInlineMatch alloc] init];
    match.sourceRange = source;
    match.contentRange = content;
    match.style = style;
    match.destination = destination;
    return match;
}

static BOOL NPEscapedAt(NSString *source, NSUInteger location) {
    NSUInteger start = location;
    while (start > 0 && [source characterAtIndex:start - 1] == '\\') start--;
    return (location - start) % 2 != 0;
}

static NSUInteger NPRunEnd(NSString *source, NSUInteger start, NSUInteger end, unichar marker) {
    while (start < end && [source characterAtIndex:start] == marker) start++;
    return start;
}

static BOOL NPWhitespace(unichar character) {
    return [NSCharacterSet.whitespaceAndNewlineCharacterSet characterIsMember:character];
}

static BOOL NPInlinePunctuation(unichar character) {
    return character == '\\' || character == '*' || character == '_' || character == '`' ||
           character == '[' || character == ']' || character == '#' || character == '-' ||
           character == '+' || character == '.' || character == ')' || character == '~' ||
           character == '<' || character == '>';
}

static BOOL NPSafeLink(NSString *address) {
    if (!address.length || [address rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound ||
        [address rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return NO;
    NSURLComponents *url = [NSURLComponents componentsWithString:address];
    NSString *scheme = url.scheme.lowercaseString;
    if ([scheme isEqualToString:@"https"] || [scheme isEqualToString:@"http"]) return url.host.length > 0;
    return [scheme isEqualToString:@"mailto"] && url.path.length > 0;
}

static NPInlineMatch *NPLinkAt(NSString *line, NSUInteger index, NSUInteger end) {
    NSUInteger labelEnd = index + 1;
    while (labelEnd < end) {
        unichar character = [line characterAtIndex:labelEnd];
        if (character == '[' && !NPEscapedAt(line, labelEnd)) return nil;
        if (character == ']' && !NPEscapedAt(line, labelEnd)) break;
        labelEnd++;
    }
    if (labelEnd == index + 1 || labelEnd + 2 >= end || [line characterAtIndex:labelEnd + 1] != '(') return nil;

    NSUInteger urlStart = labelEnd + 2;
    NSUInteger urlEnd = urlStart;
    NSUInteger destinationEnd;
    if ([line characterAtIndex:urlStart] == '<') {
        urlStart++;
        urlEnd = urlStart;
        while (urlEnd < end && [line characterAtIndex:urlEnd] != '>') urlEnd++;
        if (urlEnd + 1 >= end || [line characterAtIndex:urlEnd + 1] != ')') return nil;
        destinationEnd = urlEnd + 2;
    } else {
        NSUInteger depth = 0;
        while (urlEnd < end) {
            unichar character = [line characterAtIndex:urlEnd];
            if (NPWhitespace(character) || character == '<' || character == '>') return nil;
            if (character == '(') depth++;
            if (character == ')') {
                if (depth == 0) break;
                depth--;
            }
            urlEnd++;
        }
        if (urlEnd == end) return nil;
        destinationEnd = urlEnd + 1;
    }
    NSString *address = [line substringWithRange:NSMakeRange(urlStart, urlEnd - urlStart)];
    if (!NPSafeLink(address)) return nil;
    return NPMatch(NSMakeRange(index, destinationEnd - index), NSMakeRange(index + 1, labelEnd - index - 1), 0, address);
}

static NPInlineMatch *NPDelimitedMatchAt(NSString *line, NSUInteger start, NSUInteger end, unichar marker) {
    NSUInteger markerEnd = NPRunEnd(line, start, end, marker);
    NSUInteger count = markerEnd - start;
    BOOL code = marker == '`';
    BOOL strike = marker == '~';
    if (markerEnd == end || (!code && count > 3) || (strike && count != 2)) return nil;
    if (!code && NPWhitespace([line characterAtIndex:markerEnd])) return nil;
    NSCharacterSet *alphanumeric = NSCharacterSet.alphanumericCharacterSet;
    if (marker == '_' && start > 0 && [alphanumeric characterIsMember:[line characterAtIndex:start - 1]]) return nil;

    NSUInteger position = markerEnd;
    while (position < end) {
        unichar candidate = [line characterAtIndex:position];
        if (!code && candidate == '`' && !NPEscapedAt(line, position)) {
            NPInlineMatch *inlineCode = NPDelimitedMatchAt(line, position, end, candidate);
            position = inlineCode ? NSMaxRange(inlineCode.sourceRange) : NPRunEnd(line, position, end, candidate);
            continue;
        }
        if (candidate != marker || (!code && NPEscapedAt(line, position))) {
            position++;
            continue;
        }
        NSUInteger closingEnd = NPRunEnd(line, position, end, marker);
        NSUInteger closingCount = closingEnd - position;
        BOOL closes = closingCount == count;
        if (!code) {
            BOOL adjacentMarker = strike ? closingCount == 4 : closingCount > count && closingCount - count <= 3;
            BOOL adjacentEmphasis = adjacentMarker && closingEnd < end &&
                                    !NPWhitespace([line characterAtIndex:closingEnd]);
            closes = closes || adjacentEmphasis;
            closes = closes && !NPWhitespace([line characterAtIndex:position - 1]);
            if (marker == '_' && !adjacentEmphasis && closingEnd < end && [alphanumeric characterIsMember:[line characterAtIndex:closingEnd]]) closes = NO;
        }
        if (closes) {
            NSRange content = NSMakeRange(markerEnd, position - markerEnd);
            if (code && content.length > 2 && [line characterAtIndex:markerEnd] == ' ' && [line characterAtIndex:position - 1] == ' ') {
                NSRange firstNonSpace = [line rangeOfCharacterFromSet:NSCharacterSet.whitespaceCharacterSet.invertedSet options:0 range:content];
                if (firstNonSpace.location != NSNotFound) content = NSMakeRange(content.location + 1, content.length - 2);
            }
            NPInlineStyle style = code ? NPInlineCode : strike ? NPInlineStrike :
                count == 1 ? NPInlineItalic : count == 2 ? NPInlineBold : NPInlineBold | NPInlineItalic;
            return NPMatch(NSMakeRange(start, position + count - start), content, style, nil);
        }
        position = closingEnd;
    }
    return nil;
}

static NPInlineMatch *NPInlineAt(NSString *line, NSUInteger position, NSUInteger end, BOOL followsToken) {
    unichar marker = [line characterAtIndex:position];
    if (marker != '*' && marker != '_' && marker != '`' && marker != '[' && marker != '~') return nil;
    if (NPEscapedAt(line, position)) return nil;
    if (marker == '[') {
        if (position > 0 && [line characterAtIndex:position - 1] == '!' && !NPEscapedAt(line, position - 1)) return nil;
        return NPLinkAt(line, position, end);
    }
    if (!followsToken && position > 0 && [line characterAtIndex:position - 1] == marker) return nil;
    return NPDelimitedMatchAt(line, position, end, marker);
}

static NSUInteger NPClosingDelimiter(NSString *line, NSUInteger start, NSUInteger end, unichar open, unichar close) {
    NSUInteger depth = 0;
    for (NSUInteger position = start + 1; position < end; position++) {
        unichar character = [line characterAtIndex:position];
        if (character == '\\' && position + 1 < end) {
            position++;
        } else if (character == open) {
            if (depth == 8) return NSNotFound;
            depth++;
        } else if (character == close) {
            if (!depth) return position;
            depth--;
        }
    }
    return NSNotFound;
}

// Keep unsupported link syntax together as literal text instead of editing its label or URL.
static NSUInteger NPRawLinkEnd(NSString *line, NSUInteger position, NSUInteger end) {
    unichar first = [line characterAtIndex:position];
    if ((first != '[' && first != '!') || NPEscapedAt(line, position)) return NSNotFound;
    NSUInteger label = first == '!' ? position + 1 : position;
    if (label >= end || [line characterAtIndex:label] != '[') return NSNotFound;
    NSUInteger close = NPClosingDelimiter(line, label, end, '[', ']');
    if (close == NSNotFound || close + 1 >= end) return NSNotFound;
    NSUInteger destination = close + 1;
    switch ([line characterAtIndex:destination]) {
        case '(':
            close = NPClosingDelimiter(line, destination, end, '(', ')');
            break;
        case '[':
            close = NPClosingDelimiter(line, destination, end, '[', ']');
            break;
        case ':':
            return destination + 1;
        default:
            return NSNotFound;
    }
    return close == NSNotFound ? NSNotFound : close + 1;
}

NPInlineMatch *NPMarkdownInlineEndingAt(NSString *line, NSUInteger end) {
    if (end < 3 || end > line.length) return nil;
    unichar last = [line characterAtIndex:end - 1];
    if (last != '*' && last != '_' && last != '`' && last != ')' && last != '~') return nil;
    NSUInteger position = end > 16384 ? end - 16384 : 0;
    BOOL followsToken = NO;
    while (position < end) {
        NPInlineMatch *match = NPInlineAt(line, position, end, followsToken);
        if (match && NSMaxRange(match.sourceRange) == end) return match;
        NSUInteger rawEnd = !match ? NPRawLinkEnd(line, position, end) : NSNotFound;
        followsToken = match != nil;
        position = match ? NSMaxRange(match.sourceRange) : rawEnd != NSNotFound ? rawEnd : position + 1;
    }
    return nil;
}

static void NPAppendDecodedInline(NSMutableAttributedString *result, NSString *line, NSRange range,
                                  NPInlineStyle style, NSString *destination, NSUInteger depth) {
    NSMutableDictionary<NSAttributedStringKey, id> *attributes = [NSMutableDictionary dictionary];
    if (style) attributes[NPInlineStyleAttribute] = @(style);
    if (destination) attributes[NPLinkDestinationAttribute] = destination;
    if ((style & NPInlineCode) || depth == 8) {
        [result appendAttributedString:[[NSAttributedString alloc] initWithString:[line substringWithRange:range] attributes:attributes]];
        return;
    }

    NSUInteger end = NSMaxRange(range);
    NSUInteger plainStart = range.location;
    NSUInteger position = plainStart;
    BOOL followsToken = NO;
    while (position < end) {
        BOOL escaped = [line characterAtIndex:position] == '\\' && position + 1 < end && NPInlinePunctuation([line characterAtIndex:position + 1]);
        NPInlineMatch *match = escaped ? nil : NPInlineAt(line, position, end, followsToken);
        followsToken = match != nil;
        if (!escaped && !match) {
            NSUInteger rawEnd = NPRawLinkEnd(line, position, end);
            position = rawEnd != NSNotFound ? rawEnd : position + 1;
            continue;
        }
        if (position > plainStart) {
            NSString *plain = [line substringWithRange:NSMakeRange(plainStart, position - plainStart)];
            [result appendAttributedString:[[NSAttributedString alloc] initWithString:plain attributes:attributes]];
        }
        if (escaped) {
            NSString *literal = [line substringWithRange:NSMakeRange(position + 1, 1)];
            [result appendAttributedString:[[NSAttributedString alloc] initWithString:literal attributes:attributes]];
            position += 2;
        } else {
            NPAppendDecodedInline(result, line, match.contentRange, style | match.style, match.destination ?: destination, depth + 1);
            position = NSMaxRange(match.sourceRange);
        }
        plainStart = position;
    }
    if (plainStart < end) {
        NSString *plain = [line substringWithRange:NSMakeRange(plainStart, end - plainStart)];
        [result appendAttributedString:[[NSAttributedString alloc] initWithString:plain attributes:attributes]];
    }
}

static NSUInteger NPSkipSpaces(NSString *line, NSUInteger position) {
    while (position < line.length) {
        unichar character = [line characterAtIndex:position];
        if (character != ' ' && character != '\t') break;
        position++;
    }
    return position;
}

static BOOL NPIsListBlock(NPBlockStyle style) {
    return style == NPBlockBullet || style == NPBlockNumbered ||
           style == NPBlockTaskUnchecked || style == NPBlockTaskChecked;
}

static NSUInteger NPIndentColumns(NSString *line, NSUInteger end) {
    NSUInteger columns = 0;
    for (NSUInteger index = 0; index < end; index++) {
        columns += [line characterAtIndex:index] == '\t' ? 4 - columns % 4 : 1;
    }
    return columns;
}

static BOOL NPFenceLine(NSString *line, unichar *activeMarker, NSUInteger *activeLength, NSString **info) {
    NSUInteger start = NPSkipSpaces(line, 0);
    if (start >= line.length || start > 3) return NO;
    unichar marker = [line characterAtIndex:start];
    if (marker != '`' && marker != '~') return NO;
    NSUInteger end = NPRunEnd(line, start, line.length, marker);
    NSUInteger length = end - start;
    if (length < 3) return NO;
    if (*activeMarker) {
        if (*activeMarker != marker || length < *activeLength || NPSkipSpaces(line, end) != line.length) return NO;
        *activeMarker = 0;
        *activeLength = 0;
        return YES;
    }
    if (marker == '`' && [line rangeOfString:@"`" options:0 range:NSMakeRange(end, line.length - end)].location != NSNotFound) return NO;
    *activeMarker = marker;
    *activeLength = length;
    if (info) *info = [[line substringFromIndex:end] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    return YES;
}

static NPBlockStyle NPTaskPrefix(NSString *line, NSUInteger *bodyStart) {
    NSUInteger start = *bodyStart;
    if (line.length - start < 3 || [line characterAtIndex:start] != '[' ||
        [line characterAtIndex:start + 2] != ']') return NPBlockBullet;

    unichar status = [line characterAtIndex:start + 1];
    if (status != ' ' && status != 'x' && status != 'X') return NPBlockBullet;

    NSUInteger end = start + 3;
    NSUInteger textStart = NPSkipSpaces(line, end);
    if (end < line.length && textStart == end) return NPBlockBullet;

    *bodyStart = textStart;
    return status == ' ' ? NPBlockTaskUnchecked : NPBlockTaskChecked;
}

static NPBlockStyle NPBlockPrefix(NSString *line, NSUInteger *bodyStart) {
    NSUInteger start = NPSkipSpaces(line, 0);
    if (start >= line.length || NPIndentColumns(line, start) > 32) return NPBlockBody;
    unichar marker = [line characterAtIndex:start];
    NSUInteger end = start;
    NPBlockStyle style = NPBlockBody;
    if (marker == '>') {
        if (start > 3) return NPBlockBody;
        end++;
        if (end < line.length) {
            unichar separator = [line characterAtIndex:end];
            if (separator == ' ' || separator == '\t') end++;
        }
        *bodyStart = end;
        return NPBlockQuote;
    } else if (marker == '#') {
        if (start > 3) return NPBlockBody;
        end = NPRunEnd(line, start, line.length, marker);
        NSUInteger count = end - start;
        if (count > 6) return NPBlockBody;
        style = (NPBlockStyle)count;
    } else if (marker == '-' || marker == '+' || marker == '*') {
        end++;
        style = NPBlockBullet;
    } else {
        while (end < line.length) {
            unichar character = [line characterAtIndex:end];
            if (character < '0' || character > '9') break;
            end++;
        }
        if (end == start || end >= line.length || end - start > 9) return NPBlockBody;
        marker = [line characterAtIndex:end];
        if (marker != '.' && marker != ')') return NPBlockBody;
        end++;
        style = NPBlockNumbered;
    }
    *bodyStart = NPSkipSpaces(line, end);
    if (*bodyStart == end) return NPBlockBody;
    return style == NPBlockBullet ? NPTaskPrefix(line, bodyStart) : style;
}

static void NPAppendDecodedCode(NSMutableAttributedString *result, NSString *code, NSString *info) {
    NSMutableDictionary<NSAttributedStringKey, id> *attributes = [NSMutableDictionary dictionary];
    attributes[NPBlockStyleAttribute] = @(NPBlockCode);
    if (info.length) attributes[NPCodeInfoAttribute] = info;
    [result appendAttributedString:[[NSAttributedString alloc] initWithString:code attributes:attributes]];
}

NSMutableAttributedString *NPDecodeMarkdownWithListLevel(NSString *source, NPBlockStyle *trailingBlock,
                                                         NSUInteger *trailingListLevel) {
    NSMutableAttributedString *result = [[NSMutableAttributedString alloc] initWithString:@""];
    if (trailingBlock) *trailingBlock = NPBlockBody;
    if (trailingListLevel) *trailingListLevel = 0;
    NSUInteger position = 0;
    unichar fenceMarker = 0;
    NSUInteger fenceLength = 0;
    NSString *fenceInfo = nil;
    BOOL fenceHasContent = NO;
    NSUInteger listIndentUnit = 0;
    while (position < source.length) {
        NSUInteger end;
        NSUInteger contentEnd;
        [source getLineStart:NULL end:&end contentsEnd:&contentEnd forRange:NSMakeRange(position, 0)];
        NSString *line = [source substringWithRange:NSMakeRange(position, contentEnd - position)];
        NSString *terminator = [source substringWithRange:NSMakeRange(contentEnd, end - contentEnd)];
        BOOL insideFence = fenceMarker != 0;
        if (NPFenceLine(line, &fenceMarker, &fenceLength, &fenceInfo)) {
            listIndentUnit = 0;
            if (insideFence && !fenceHasContent) {
                if (terminator.length) NPAppendDecodedCode(result, terminator, fenceInfo);
                else if (trailingBlock) *trailingBlock = NPBlockCode;
            }
            fenceHasContent = NO;
            position = end;
            continue;
        }
        if (insideFence) {
            NPAppendDecodedCode(result, [line stringByAppendingString:terminator], fenceInfo);
            fenceHasContent = YES;
            position = end;
            continue;
        }
        NSUInteger bodyStart = 0;
        NPBlockStyle style = NPBlockPrefix(line, &bodyStart);
        if (style == NPBlockBody) bodyStart = 0;
        NSUInteger listLevel = 0;
        if (NPIsListBlock(style)) {
            NSUInteger columns = NPIndentColumns(line, NPSkipSpaces(line, 0));
            if (columns && !listIndentUnit) listIndentUnit = columns % 4 == 0 ? 4 : 2;
            listLevel = columns ? MIN((NSUInteger)8, MAX((NSUInteger)1, columns / listIndentUnit)) : 0;
        } else if (line.length || terminator.length == 0) {
            listIndentUnit = 0;
        }
        NSUInteger outputStart = result.length;
        NPAppendDecodedInline(result, line, NSMakeRange(bodyStart, line.length - bodyStart), 0, nil, 0);
        [result appendAttributedString:[[NSAttributedString alloc] initWithString:terminator]];
        if (style != NPBlockBody) {
            NSRange paragraph = NSMakeRange(outputStart, result.length - outputStart);
            if (paragraph.length) {
                [result addAttribute:NPBlockStyleAttribute value:@(style) range:paragraph];
                if (listLevel) [result addAttribute:NPListLevelAttribute value:@(listLevel) range:paragraph];
            } else if (trailingBlock) {
                *trailingBlock = style;
                if (trailingListLevel) *trailingListLevel = listLevel;
            }
        }
        position = end;
    }
    if (fenceMarker && trailingBlock) *trailingBlock = NPBlockCode;
    return result;
}

NSMutableAttributedString *NPDecodeMarkdown(NSString *source, NPBlockStyle *trailingBlock) {
    return NPDecodeMarkdownWithListLevel(source, trailingBlock, NULL);
}

static NSString *NPEscapeInline(NSString *source, BOOL linkLabel, BOOL strike) {
    NSMutableString *result = [NSMutableString string];
    NSUInteger start = 0;
    for (NSUInteger i = 0; i < source.length; i++) {
        unichar character = [source characterAtIndex:i];
        if (!linkLabel && (character == '!' || character == '[')) {
            NSUInteger rawEnd = NPRawLinkEnd(source, i, source.length);
            if (rawEnd != NSNotFound && !NPInlineAt(source, i, source.length, NO)) {
                i = rawEnd - 1;
                continue;
            }
        }
        BOOL escapeTilde = character == '~' && (strike || (i > 0 && [source characterAtIndex:i - 1] == '~') ||
                                               (i + 1 < source.length && [source characterAtIndex:i + 1] == '~'));
        if (character != '\\' && character != '*' && character != '_' && character != '`' && character != '[' && character != ']' && !escapeTilde) continue;
        [result appendString:[source substringWithRange:NSMakeRange(start, i - start)]];
        [result appendString:@"\\"];
        start = i;
    }
    [result appendString:[source substringFromIndex:start]];
    return result;
}

static NSString *NPEncodeInline(NSAttributedString *text, NSRange range) {
    NSMutableString *result = [NSMutableString string];
    NSUInteger location = range.location;
    while (location < NSMaxRange(range)) {
        NSRange styleRange;
        NSRange linkRange;
        NSNumber *value = [text attribute:NPInlineStyleAttribute atIndex:location longestEffectiveRange:&styleRange inRange:range];
        NSString *link = [text attribute:NPLinkDestinationAttribute atIndex:location longestEffectiveRange:&linkRange inRange:range];
        NSRange run = NSIntersectionRange(styleRange, linkRange);
        NSString *source = [text.string substringWithRange:run];
        NPInlineStyle style = value.unsignedIntegerValue;
        NSString *emphasis = (style & NPInlineBold) ? ((style & NPInlineItalic) ? @"***" : @"**") : (style & NPInlineItalic) ? @"*" : @"";
        NSString *strike = (style & NPInlineStrike) ? @"~~" : @"";
        NSString *leadingWhitespace = @"";
        NSString *trailingWhitespace = @"";
        if ((emphasis.length || strike.length) && !(style & NPInlineCode)) {
            NSCharacterSet *nonWhitespace = NSCharacterSet.whitespaceCharacterSet.invertedSet;
            NSRange first = [source rangeOfCharacterFromSet:nonWhitespace];
            if (first.location == NSNotFound) {
                emphasis = @"";
                strike = @"";
            } else {
                NSRange last = [source rangeOfCharacterFromSet:nonWhitespace options:NSBackwardsSearch range:NSMakeRange(0, source.length)];
                leadingWhitespace = [source substringToIndex:first.location];
                trailingWhitespace = [source substringFromIndex:NSMaxRange(last)];
                source = [source substringWithRange:NSMakeRange(first.location, NSMaxRange(last) - first.location)];
            }
        }
        NSString *encoded;
        if (style & NPInlineCode) {
            NSUInteger longest = 0;
            NSUInteger position = 0;
            while (position < source.length) {
                NSUInteger end = NPRunEnd(source, position, source.length, '`');
                longest = MAX(longest, end - position);
                position = MAX(end, position + 1);
            }
            NSString *marker = [@"" stringByPaddingToLength:longest + 1 withString:@"`" startingAtIndex:0];
            // Padding keeps a literal backtick at the span boundary separate from the delimiter.
            BOOL surroundsWithSpaces = [source hasPrefix:@" "] && [source hasSuffix:@" "] &&
                [source rangeOfCharacterFromSet:NSCharacterSet.whitespaceCharacterSet.invertedSet].location != NSNotFound;
            NSString *padding = [source hasPrefix:@"`"] || [source hasSuffix:@"`"] || surroundsWithSpaces ? @" " : @"";
            encoded = [NSString stringWithFormat:@"%@%@%@%@%@", marker, padding, source, padding, marker];
        } else {
            encoded = NPEscapeInline(source, link != nil, strike.length != 0);
        }
        if (emphasis.length || strike.length) {
            encoded = [NSString stringWithFormat:@"%@%@%@%@%@%@%@", leadingWhitespace, strike, emphasis, encoded, emphasis, strike, trailingWhitespace];
        }
        if (link && NPSafeLink(link)) encoded = [NSString stringWithFormat:@"[%@](<%@>)", encoded, [link stringByReplacingOccurrencesOfString:@">" withString:@"%3E"]];
        [result appendString:encoded];
        location = NSMaxRange(run);
    }
    return result;
}

static void NPAppendEncodedBlock(NSMutableString *result, NPBlockStyle style, NSUInteger numbers[9], NSUInteger level) {
    level = NPIsListBlock(style) ? MIN((NSUInteger)8, level) : 0;
    for (NSUInteger deeper = level + 1; deeper < 9; deeper++) numbers[deeper] = 0;
    if (NPIsListBlock(style)) {
        for (NSUInteger index = 0; index < level; index++) [result appendString:@"    "];
    } else {
        for (NSUInteger index = 0; index < 9; index++) numbers[index] = 0;
    }
    if (style == NPBlockNumbered) {
        numbers[level]++;
        [result appendFormat:@"%lu. ", (unsigned long)numbers[level]];
        return;
    }
    numbers[level] = 0;
    if (style == NPBlockBullet) {
        [result appendString:@"- "];
    } else if (style == NPBlockTaskUnchecked || style == NPBlockTaskChecked) {
        [result appendString:style == NPBlockTaskChecked ? @"- [x] " : @"- [ ] "];
    } else if (style == NPBlockQuote) {
        [result appendString:@"> "];
    } else if (style >= NPBlockHeading1 && style <= NPBlockHeading6) {
        [result appendString:[@"" stringByPaddingToLength:(NSUInteger)style withString:@"#" startingAtIndex:0]];
        [result appendString:@" "];
    }
}

static NSUInteger NPAppendEncodedCode(NSMutableString *result, NSAttributedString *text, NSUInteger start,
                                      BOOL *endsAtNewLine) {
    NSString *source = text.string;
    NSString *info = [text attribute:NPCodeInfoAttribute atIndex:start effectiveRange:NULL] ?: @"";
    NSString *terminator = nil;
    NSUInteger end = start;
    NSUInteger contentEnd;
    do {
        [source getLineStart:NULL end:&end contentsEnd:&contentEnd forRange:NSMakeRange(end, 0)];
        if (!terminator && contentEnd < end) {
            terminator = [source substringWithRange:NSMakeRange(contentEnd, end - contentEnd)];
        }
    } while (end < source.length && [[text attribute:NPBlockStyleAttribute atIndex:end effectiveRange:NULL] integerValue] == NPBlockCode &&
             [[text attribute:NPCodeInfoAttribute atIndex:end effectiveRange:NULL] ?: @"" isEqualToString:info]);

    NSString *content = [source substringWithRange:NSMakeRange(start, end - start)];
    unichar marker = [info rangeOfString:@"`"].location == NSNotFound ? '`' : '~';
    NSString *character = marker == '`' ? @"`" : @"~";
    NSUInteger fenceLength = 3;
    NSUInteger position = 0;
    while (position < content.length) {
        NSUInteger runEnd = NPRunEnd(content, position, content.length, marker);
        fenceLength = MAX(fenceLength, runEnd - position + 1);
        position = MAX(runEnd, position + 1);
    }
    NSString *fence = [@"" stringByPaddingToLength:fenceLength withString:character startingAtIndex:0];
    if (!terminator) terminator = @"\n";

    [result appendString:fence];
    if ([info hasPrefix:character]) [result appendString:@" "];
    [result appendString:info];
    [result appendString:terminator];
    [result appendString:content];
    *endsAtNewLine = contentEnd < end;
    if (!*endsAtNewLine) [result appendString:terminator];
    [result appendString:fence];
    if (end < source.length || *endsAtNewLine) [result appendString:terminator];
    return end;
}

NSString *NPEncodeMarkdownWithListLevel(NSAttributedString *text, NPBlockStyle trailingBlock, NSUInteger trailingListLevel) {
    NSMutableString *result = [NSMutableString string];
    NSString *source = text.string;
    NSUInteger position = 0;
    NSUInteger numbers[9] = {0};
    unichar fenceMarker = 0;
    NSUInteger fenceLength = 0;
    BOOL endsAtNewLine = YES;
    NPBlockStyle lastStyle = NPBlockBody;
    while (position < source.length) {
        NSUInteger end;
        NSUInteger contentEnd;
        [source getLineStart:NULL end:&end contentsEnd:&contentEnd forRange:NSMakeRange(position, 0)];
        NSRange lineRange = NSMakeRange(position, contentEnd - position);
        NSString *line = [source substringWithRange:lineRange];
        NPBlockStyle style = [[text attribute:NPBlockStyleAttribute atIndex:position effectiveRange:NULL] integerValue];
        lastStyle = style;
        BOOL insideFence = fenceMarker != 0;
        if ((style == NPBlockBody || insideFence) && (NPFenceLine(line, &fenceMarker, &fenceLength, NULL) || insideFence)) {
            [result appendString:line];
            for (NSUInteger index = 0; index < 9; index++) numbers[index] = 0;
        } else if (style == NPBlockCode) {
            position = NPAppendEncodedCode(result, text, position, &endsAtNewLine);
            for (NSUInteger index = 0; index < 9; index++) numbers[index] = 0;
            continue;
        } else {
            NPAppendEncodedBlock(result, style, numbers, NPListLevelAt(text, position));
            NSString *encoded = NPEncodeInline(text, lineRange);
            NSUInteger prefixEnd = 0;
            if (style == NPBlockBody && NPBlockPrefix(encoded, &prefixEnd) != NPBlockBody) {
                NSUInteger marker = NPSkipSpaces(encoded, 0);
                // For numbered lists escape the punctuation, rather than the initial digit.
                while (marker < prefixEnd && [encoded characterAtIndex:marker] >= '0' && [encoded characterAtIndex:marker] <= '9') marker++;
                [result appendString:[encoded substringToIndex:marker]];
                [result appendString:@"\\"];
                encoded = [encoded substringFromIndex:marker];
            }
            [result appendString:encoded];
        }
        [result appendString:[source substringWithRange:NSMakeRange(contentEnd, end - contentEnd)]];
        endsAtNewLine = end > contentEnd;
        position = end;
    }
    if (endsAtNewLine && !fenceMarker) {
        if (trailingBlock == NPBlockCode && lastStyle != NPBlockCode) [result appendString:@"```\n```"];
        else NPAppendEncodedBlock(result, trailingBlock, numbers, trailingListLevel);
    }
    return result;
}

NSString *NPEncodeMarkdown(NSAttributedString *text, NPBlockStyle trailingBlock) {
    return NPEncodeMarkdownWithListLevel(text, trailingBlock, 0);
}
