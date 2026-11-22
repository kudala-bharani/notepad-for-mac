#import <Foundation/Foundation.h>
#import "LiveFormatting.h"

NS_ASSUME_NONNULL_BEGIN

// Returns a replacement for the adjacent task siblings, including their children.
NSAttributedString * _Nullable NPTaskListByToggling(NSAttributedString *document,
                                                   NPBlockStyle trailingBlock,
                                                   NSUInteger trailingListLevel,
                                                   NSRange selection,
                                                   NSUInteger targetParagraphLocation,
                                                   NSRange *replacementRange,
                                                   NSRange *newSelection,
                                                   NPBlockStyle *newTrailingBlock,
                                                   NSUInteger *newTrailingListLevel);

NS_ASSUME_NONNULL_END
