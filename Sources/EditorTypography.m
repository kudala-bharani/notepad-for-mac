#import "EditorTypography.h"
#include <math.h>

CGFloat NPDefaultEditorTextSize(void) {
    return 14;
}

CGFloat NPConstrainEditorTextSize(CGFloat size) {
    if (!isfinite(size) || size <= 0) return NPDefaultEditorTextSize();
    return MIN(32, MAX(10, size));
}

NSString *NPComicSansFontName(void) {
    for (NSString *name in @[@"ComicSansMS", @"Comic Sans MS", @"ComicSans", @"Comic Sans"]) {
        NSFont *font = [NSFont fontWithName:name size:NPDefaultEditorTextSize()];
        if (font) return font.fontName;
    }
    return nil;
}

static NSFont *PreferredFont(NSString *name, CGFloat size, BOOL bold, BOOL italic) {
    NSFont *font = [NSFont fontWithName:name size:size];
    if (!font) return nil;

    NSFontManager *manager = NSFontManager.sharedFontManager;
    NSFontTraitMask traits = 0;
    if (bold) {
        font = [manager convertFont:font toHaveTrait:NSBoldFontMask] ?: font;
        traits |= NSBoldFontMask;
    }
    if (italic) {
        font = [manager convertFont:font toHaveTrait:NSItalicFontMask] ?: font;
        traits |= NSItalicFontMask;
    }
    return ([manager traitsOfFont:font] & traits) == traits ? font : nil;
}

NSFont *NPEditorFont(NPBlockStyle block, NPInlineStyle inlineStyle, CGFloat bodySize, NSString *preferredFontName) {
    static const CGFloat headingSizes[] = {14, 30, 25, 21, 18, 16, 14};
    BOOL heading = block >= NPBlockHeading1 && block <= NPBlockHeading6;
    BOOL bold = (inlineStyle & NPInlineBold) != 0;
    BOOL italic = (inlineStyle & NPInlineItalic) != 0;
    BOOL code = block == NPBlockCode || (inlineStyle & NPInlineCode) != 0;
    CGFloat size = NPConstrainEditorTextSize(bodySize);
    if (heading) size *= headingSizes[block] / NPDefaultEditorTextSize();

    if (preferredFontName.length && !code) {
        NSFont *customFont = PreferredFont(preferredFontName, size, heading || bold, italic);
        if (customFont) return customFont;
    }

    NSFontWeight weight = bold ? NSFontWeightBold : heading ? NSFontWeightSemibold : NSFontWeightRegular;
    BOOL proportional = !code && (heading || preferredFontName != nil);
    NSFont *font = proportional
        ? [NSFont systemFontOfSize:size weight:weight]
        : [NSFont monospacedSystemFontOfSize:size weight:weight];
    if (!italic) return font;

    NSFontManager *manager = NSFontManager.sharedFontManager;
    NSFont *italicFont = [manager convertFont:font toHaveTrait:NSItalicFontMask];
    if (italicFont && ([manager traitsOfFont:italicFont] & NSItalicFontMask)) return italicFont;
    NSString *fallback = bold ? @"Menlo-BoldItalic" : @"Menlo-Italic";
    if (proportional) fallback = heading || bold ? @"HelveticaNeue-BoldItalic" : @"HelveticaNeue-Italic";
    return [NSFont fontWithName:fallback size:size] ?: font;
}
