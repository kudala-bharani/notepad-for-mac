#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NPNote : NSObject

@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *text;
@property (nonatomic, copy, nullable) NSString *filePath;
@property (nonatomic, copy, nullable) NSDate *fileModificationDate;
@property (nonatomic) NSStringEncoding fileEncoding;
@property (nonatomic) BOOL dirty;
@property (nonatomic) BOOL needsMarkdownImport;
@property (nonatomic, copy, nullable) NSDictionary *formatting;
@property (nonatomic) NSRange selection;

@end

@interface NPSession : NSObject

@property (nonatomic, strong) NSMutableArray<NPNote *> *notes;
@property (nonatomic, strong) NSMutableArray<NPNote *> *closedNotes;
@property (nonatomic, copy, nullable) NSString *selectedID;
@property (nonatomic) BOOL wrapsLines;

+ (nullable instancetype)loadFromURL:(NSURL *)url error:(NSError * _Nullable * _Nullable)error;
- (BOOL)writeToURL:(NSURL *)url error:(NSError * _Nullable * _Nullable)error;
+ (NSURL *)defaultURL;

@end

BOOL NPPathUsesMarkdown(NSString * _Nullable path);

NS_ASSUME_NONNULL_END
