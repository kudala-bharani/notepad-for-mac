#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, NPBlockStyle) {
    NPBlockBody = 0,
    NPBlockHeading1,
    NPBlockHeading2,
    NPBlockHeading3,
    NPBlockHeading4,
    NPBlockHeading5,
    NPBlockHeading6,
    NPBlockBullet,
    NPBlockNumbered,
    NPBlockTaskUnchecked = 9,
    NPBlockTaskChecked = 10,
    NPBlockQuote = 11,
    NPBlockCode = 12,
};

typedef NS_OPTIONS(NSUInteger, NPInlineStyle) {
    NPInlineBold = 1,
    NPInlineItalic = 2,
    NPInlineCode = 4,
    NPInlineStrike = 8,
};

extern NSAttributedStringKey const NPBlockStyleAttribute;
extern NSAttributedStringKey const NPInlineStyleAttribute;
extern NSAttributedStringKey const NPLinkDestinationAttribute;
extern NSAttributedStringKey const NPCodeInfoAttribute;
extern NSAttributedStringKey const NPListLevelAttribute;
extern const NSUInteger NPMaxListLevel;

NSUInteger NPListLevelAt(NSAttributedString *text, NSUInteger location);

NSDictionary<NSString *, id> *NPFormattingSnapshot(NSAttributedString *text, NPBlockStyle trailingBlock);
NSMutableAttributedString *NPTextWithFormatting(NSString *text, NSDictionary * _Nullable snapshot,
                                                NPBlockStyle * _Nullable trailingBlock);

NS_ASSUME_NONNULL_END
