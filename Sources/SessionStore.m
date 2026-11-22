#import "SessionStore.h"
#include <math.h>

static NSString *const NPSessionErrorDomain = @"com.kudala.notepad.session";

BOOL NPPathUsesMarkdown(NSString *path) {
    NSString *extension = path.pathExtension.lowercaseString;
    return [extension isEqualToString:@"md"] || [extension isEqualToString:@"markdown"];
}

static NSError *NPInvalidSessionError(void) {
    return [NSError errorWithDomain:NPSessionErrorDomain
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey: @"The saved Notepad session could not be read."}];
}

static BOOL NPIsBoolean(id value) {
    return value == @YES || value == @NO;
}

static BOOL NPReadUnsigned(id value, NSUInteger *result) {
    if (![value isKindOfClass:NSNumber.class] || NPIsBoolean(value)) {
        return NO;
    }

    NSNumber *number = value;
    if ([number compare:@0] == NSOrderedAscending ||
        [number compare:@(NSUIntegerMax)] == NSOrderedDescending) {
        return NO;
    }

    NSUInteger integer = number.unsignedIntegerValue;
    if (![number isEqualToNumber:@(integer)]) {
        return NO;
    }

    *result = integer;
    return YES;
}

@implementation NPNote

- (instancetype)init {
    self = [super init];
    if (self) {
        _identifier = NSUUID.UUID.UUIDString;
        _text = @"";
        _fileEncoding = NSUTF8StringEncoding;
        _selection = NSMakeRange(0, 0);
    }
    return self;
}

@end

static NSDictionary *NPEncodeNote(NPNote *note) {
    NSUInteger location = MIN(note.selection.location, note.text.length);
    NSUInteger length = MIN(note.selection.length, note.text.length - location);
    id modificationDate = note.fileModificationDate
        ? (id)@(note.fileModificationDate.timeIntervalSinceReferenceDate)
        : NSNull.null;
    return @{
        @"id": note.identifier,
        @"text": note.text,
        @"filePath": (id)note.filePath ?: NSNull.null,
        @"fileModificationDate": modificationDate,
        @"fileEncoding": @(note.fileEncoding),
        @"dirty": @(note.dirty),
        @"markdownEnabled": @(note.needsMarkdownImport),
        @"formatting": (id)note.formatting ?: NSNull.null,
        @"selectionLocation": @(location),
        @"selectionLength": @(length),
    };
}

static NPNote *NPDecodeNote(id value) {
    if (![value isKindOfClass:NSDictionary.class]) {
        return nil;
    }

    id identifier = value[@"id"];
    id text = value[@"text"];
    id filePath = value[@"filePath"];
    id modificationDate = value[@"fileModificationDate"];
    id fileEncoding = value[@"fileEncoding"];
    id dirty = value[@"dirty"];
    id markdownEnabled = value[@"markdownEnabled"];
    id formatting = value[@"formatting"];
    NSUInteger location;
    NSUInteger length;
    NSUInteger encoding = NSUTF8StringEncoding;

    if (![identifier isKindOfClass:NSString.class] || [identifier length] == 0 ||
        ![text isKindOfClass:NSString.class] ||
        (filePath != NSNull.null &&
         !([filePath isKindOfClass:NSString.class] && [filePath isAbsolutePath])) ||
        (modificationDate && modificationDate != NSNull.null &&
         (![modificationDate isKindOfClass:NSNumber.class] || NPIsBoolean(modificationDate) ||
          !isfinite([modificationDate doubleValue]))) ||
        (fileEncoding && (!NPReadUnsigned(fileEncoding, &encoding) || encoding == 0)) ||
        !NPIsBoolean(dirty) ||
        (markdownEnabled && !NPIsBoolean(markdownEnabled)) ||
        !NPReadUnsigned(value[@"selectionLocation"], &location) ||
        !NPReadUnsigned(value[@"selectionLength"], &length)) {
        return nil;
    }

    NPNote *note = [NPNote new];
    note.identifier = identifier;
    note.text = text;
    note.filePath = filePath == NSNull.null ? nil : filePath;
    if (modificationDate && modificationDate != NSNull.null) {
        note.fileModificationDate = [NSDate dateWithTimeIntervalSinceReferenceDate:[modificationDate doubleValue]];
    }
    note.fileEncoding = encoding;
    note.dirty = [dirty boolValue];
    note.needsMarkdownImport = markdownEnabled ? [markdownEnabled boolValue] : NPPathUsesMarkdown(note.filePath);
    if ([formatting isKindOfClass:NSDictionary.class]) note.formatting = formatting;
    location = MIN(location, note.text.length);
    note.selection = NSMakeRange(location, MIN(length, note.text.length - location));
    return note;
}

static BOOL NPDecodeNotes(id value, NSMutableArray<NPNote *> *notes, NSMutableSet<NSString *> *identifiers) {
    if (![value isKindOfClass:NSArray.class]) {
        return NO;
    }

    for (id item in (NSArray *)value) {
        NPNote *note = NPDecodeNote(item);
        if (!note || [identifiers containsObject:note.identifier]) {
            return NO;
        }
        [identifiers addObject:note.identifier];
        [notes addObject:note];
    }
    return YES;
}

static NSArray<NSDictionary *> *NPEncodeNotes(NSArray<NPNote *> *notes) {
    NSMutableArray<NSDictionary *> *result = [NSMutableArray arrayWithCapacity:notes.count];
    for (NPNote *note in notes) {
        [result addObject:NPEncodeNote(note)];
    }
    return result;
}

@implementation NPSession

- (instancetype)init {
    self = [super init];
    if (self) {
        _notes = [NSMutableArray array];
        _closedNotes = [NSMutableArray array];
        _wrapsLines = YES;
    }
    return self;
}

+ (NSURL *)defaultURL {
    NSURL *support = [[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
                                                          inDomains:NSUserDomainMask] firstObject];
    if (!support) {
        NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support"];
        support = [NSURL fileURLWithPath:path isDirectory:YES];
    }
    NSURL *directory = [support URLByAppendingPathComponent:@"com.kudala.notepad" isDirectory:YES];
    return [directory URLByAppendingPathComponent:@"session.json" isDirectory:NO];
}

+ (instancetype)loadFromURL:(NSURL *)url error:(NSError **)error {
    NSError *readError = nil;
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:&readError];
    if (!data) {
        if ([readError.domain isEqualToString:NSCocoaErrorDomain] &&
            (readError.code == NSFileReadNoSuchFileError || readError.code == NSFileNoSuchFileError)) {
            return [self new];
        }
        if (error) {
            *error = readError;
        }
        return nil;
    }

    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:&readError];
    if (!root) {
        if (error) {
            *error = readError;
        }
        return nil;
    }

    if (![root isKindOfClass:NSDictionary.class]) {
        if (error) {
            *error = NPInvalidSessionError();
        }
        return nil;
    }

    NSUInteger version;
    id selectedID = root[@"selectedID"];
    id wrapsLines = root[@"wrapsLines"];
    NPSession *session = [self new];
    NSMutableSet<NSString *> *identifiers = [NSMutableSet set];
    if (!NPReadUnsigned(root[@"version"], &version) || version != 1 ||
        (selectedID != NSNull.null && ![selectedID isKindOfClass:NSString.class]) ||
        !NPIsBoolean(wrapsLines) ||
        !NPDecodeNotes(root[@"notes"], session.notes, identifiers) ||
        !NPDecodeNotes(root[@"closedNotes"], session.closedNotes, identifiers)) {
        if (error) {
            *error = NPInvalidSessionError();
        }
        return nil;
    }

    for (NPNote *note in session.notes) {
        if ([note.identifier isEqual:selectedID]) {
            session.selectedID = note.identifier;
            break;
        }
    }
    session.wrapsLines = [wrapsLines boolValue];
    return session;
}

- (BOOL)writeToURL:(NSURL *)url error:(NSError **)error {
    NSDictionary *archive = @{
        @"version": @1,
        @"notes": NPEncodeNotes(self.notes),
        @"closedNotes": NPEncodeNotes(self.closedNotes),
        @"selectedID": (id)self.selectedID ?: NSNull.null,
        @"wrapsLines": @(self.wrapsLines),
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:archive options:0 error:error];
    if (!data) {
        return NO;
    }

    NSURL *directory = [url URLByDeletingLastPathComponent];
    if (![NSFileManager.defaultManager createDirectoryAtURL:directory
                                withIntermediateDirectories:YES
                                                 attributes:@{NSFilePosixPermissions: @0700}
                                                      error:error]) {
        return NO;
    }

    return [data writeToURL:url options:NSDataWritingAtomic error:error];
}

@end
