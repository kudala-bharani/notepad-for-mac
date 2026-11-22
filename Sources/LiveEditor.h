#import <AppKit/AppKit.h>
#import "LiveFormatting.h"

NS_ASSUME_NONNULL_BEGIN

@interface NPLiveEditor : NSTextView
@property (nonatomic, strong) NSUndoManager *tabUndoManager;
- (void)loadDocument:(NSAttributedString *)document trailingBlock:(NPBlockStyle)trailingBlock
          listLevel:(NSUInteger)listLevel;
- (NSDictionary *)formattingSnapshot;
- (void)refreshTypingAttributes;
- (void)applyBlockStyle:(NPBlockStyle)style;
- (void)toggleInlineStyle:(NPInlineStyle)style;
- (BOOL)hasTaskAtSelection;
- (void)toggleTaskAtSelection;
- (void)configureTextSize:(CGFloat)size fontName:(nullable NSString *)fontName;
- (void)pasteAsMarkdown:(id)sender;
@end

NS_ASSUME_NONNULL_END
