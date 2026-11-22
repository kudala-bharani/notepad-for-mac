#import <AppKit/AppKit.h>
#import "LiveFormatting.h"

NS_ASSUME_NONNULL_BEGIN

CGFloat NPDefaultEditorTextSize(void);
CGFloat NPConstrainEditorTextSize(CGFloat size);
NSString * _Nullable NPComicSansFontName(void);
// nil keeps the original editor font, while an empty name selects the system font.
NSFont *NPEditorFont(NPBlockStyle block, NPInlineStyle inlineStyle, CGFloat bodySize,
                    NSString * _Nullable preferredFontName);

NS_ASSUME_NONNULL_END
