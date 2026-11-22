#import <Foundation/Foundation.h>
#import "LiveFormatting.h"

NS_ASSUME_NONNULL_BEGIN

@interface NPInlineMatch : NSObject
@property (nonatomic, readonly) NSRange sourceRange;
@property (nonatomic, readonly) NSRange contentRange;
@property (nonatomic, readonly) NPInlineStyle style;
@property (nonatomic, copy, readonly, nullable) NSString *destination;
@end

NSMutableAttributedString *NPDecodeMarkdown(NSString *source, NPBlockStyle * _Nullable trailingBlock);
NSString *NPEncodeMarkdown(NSAttributedString *text, NPBlockStyle trailingBlock);
NSMutableAttributedString *NPDecodeMarkdownWithListLevel(NSString *source, NPBlockStyle * _Nullable trailingBlock,
                                                         NSUInteger * _Nullable trailingListLevel);
NSString *NPEncodeMarkdownWithListLevel(NSAttributedString *text, NPBlockStyle trailingBlock, NSUInteger trailingListLevel);
NPInlineMatch * _Nullable NPMarkdownInlineEndingAt(NSString *line, NSUInteger end);

NS_ASSUME_NONNULL_END
