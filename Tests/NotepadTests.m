#import <AppKit/AppKit.h>
#import "LiveEditor.h"
#import "LiveMarkdown.h"
#import "SessionStore.h"
#import "TaskListEditing.h"

#include <stdio.h>
#include <stdlib.h>

static NSUInteger assertionCount;

static void Expect(BOOL condition, NSString *message) {
    assertionCount++;
    if (condition) return;
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    exit(EXIT_FAILURE);
}

@interface EditorDelegate : NSObject <NSTextViewDelegate>
@property (nonatomic, strong) NSUndoManager *manager;
@end

@implementation EditorDelegate
- (NSUndoManager *)undoManagerForTextView:(NSTextView *)view {
    return self.manager;
}

- (void)textViewDidChangeSelection:(NSNotification *)notification {
    [(NPLiveEditor *)notification.object refreshTypingAttributes];
}
@end

static void Perform(NPLiveEditor *editor, void (^operation)(void)) {
    [editor.tabUndoManager beginUndoGrouping];
    operation();
    [editor.tabUndoManager endUndoGrouping];
}

static void Select(NPLiveEditor *editor, NSUInteger location) {
    [editor setSelectedRange:NSMakeRange(location, 0)];
    [editor refreshTypingAttributes];
}

static NPBlockStyle BlockAt(NSAttributedString *document, NSUInteger position) {
    return [[document attribute:NPBlockStyleAttribute atIndex:position effectiveRange:NULL] unsignedIntegerValue];
}

static NPInlineStyle InlineAt(NSAttributedString *document, NSUInteger position) {
    return [[document attribute:NPInlineStyleAttribute atIndex:position effectiveRange:NULL] unsignedIntegerValue];
}

static NPBlockStyle TrailingBlock(NPLiveEditor *editor) {
    return [[[editor formattingSnapshot] objectForKey:@"trailingBlock"] unsignedIntegerValue];
}

static NSUInteger TrailingLevel(NPLiveEditor *editor) {
    return [[[editor formattingSnapshot] objectForKey:@"trailingListLevel"] unsignedIntegerValue];
}

static void Load(NPLiveEditor *editor, NSString *text, NPBlockStyle block, NSUInteger level) {
    NSMutableAttributedString *document = [[NSMutableAttributedString alloc] initWithString:text];
    if (document.length && block != NPBlockBody) {
        [document addAttribute:NPBlockStyleAttribute value:@(block) range:NSMakeRange(0, document.length)];
    }
    if (document.length && level) {
        [document addAttribute:NPListLevelAttribute value:@(level) range:NSMakeRange(0, document.length)];
    }
    [editor loadDocument:document trailingBlock:block listLevel:level];
    Select(editor, text.length);
    [editor.tabUndoManager removeAllActions];
}

static void Type(NPLiveEditor *editor, NSString *text) {
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length)
                            options:NSStringEnumerationByComposedCharacterSequences
                         usingBlock:^(NSString *character, NSRange range, NSRange enclosingRange, BOOL *stop) {
        Perform(editor, ^{
            [editor insertText:character replacementRange:NSMakeRange(NSNotFound, 0)];
        });
    }];
}

static void TestHeadingEditing(NPLiveEditor *editor) {
    Load(editor, @"", NPBlockBody, 0);
    Type(editor, @"# ");
    Expect(editor.string.length == 0, @"The heading prefix is consumed immediately.");
    Expect(TrailingBlock(editor) == NPBlockHeading1, @"An empty heading retains its level.");
    Type(editor, @"Title");
    Expect(BlockAt(editor.textStorage, 0) == NPBlockHeading1, @"Typing after the prefix creates a Heading 1.");

    Select(editor, 0);
    Type(editor, @"## ");
    Expect([editor.string isEqualToString:@"Title"], @"Changing an existing heading removes its new prefix.");
    Expect(BlockAt(editor.textStorage, 0) == NPBlockHeading2, @"A new prefix changes an existing heading level.");

    Select(editor, 0);
    Perform(editor, ^{ [editor insertNewline:nil]; });
    Expect([editor.string isEqualToString:@"\nTitle"], @"Return at heading start inserts a blank line above it.");
    Expect(BlockAt(editor.textStorage, 0) == NPBlockBody, @"The blank line above a heading has body style.");
    Expect(BlockAt(editor.textStorage, 1) == NPBlockHeading2, @"The moved heading keeps its style.");
    [editor.tabUndoManager undo];
    Expect([editor.string isEqualToString:@"Title"], @"Undo restores the heading before the inserted blank line.");
    Expect(BlockAt(editor.textStorage, 0) == NPBlockHeading2, @"Undo preserves the original heading style.");

    Select(editor, editor.string.length);
    Perform(editor, ^{ [editor insertNewline:nil]; });
    Type(editor, @"Body");
    Expect([editor.string isEqualToString:@"Title\nBody"], @"Return at heading end begins a new paragraph.");
    Expect(BlockAt(editor.textStorage, 6) == NPBlockBody, @"Text after the heading uses body style.");
    puts("PASS heading editing");
}

static void TestInlineFormatting(NPLiveEditor *editor) {
    Load(editor, @"**", NPBlockBody, 0);
    Select(editor, 1);
    Type(editor, @"Bold");
    Expect([editor.string isEqualToString:@"Bold"], @"Typing inside paired stars consumes both markers.");
    Expect((InlineAt(editor.textStorage, 0) & NPInlineBold) != 0, @"Paired stars apply bold styling.");
    Expect((InlineAt(editor.textStorage, 3) & NPInlineBold) != 0, @"Bold styling continues while typing.");
    [editor cancelOperation:nil];
    Type(editor, @" normal");
    Expect(InlineAt(editor.textStorage, 5) == 0, @"Escape exits the paired typing style.");

    Load(editor, @"__", NPBlockBody, 0);
    Select(editor, 1);
    Type(editor, @"Italic");
    Expect([editor.string isEqualToString:@"Italic"], @"Typing inside paired underscores consumes both markers.");
    Expect((InlineAt(editor.textStorage, 5) & NPInlineItalic) != 0, @"Paired underscores keep italic style across typed characters.");

    Load(editor, @"", NPBlockBody, 0);
    Type(editor, @"**bold** and ~~done~~");
    Expect([editor.string isEqualToString:@"bold and done"], @"Completed Markdown emphasis is rendered in place.");
    Expect((InlineAt(editor.textStorage, 0) & NPInlineBold) != 0, @"Completed double stars apply bold styling.");
    Expect((InlineAt(editor.textStorage, 9) & NPInlineStrike) != 0, @"Completed double tildes apply strikethrough.");
    puts("PASS inline formatting");
}

static void TestListNesting(NPLiveEditor *editor) {
    Load(editor, @"Parent", NPBlockNumbered, 0);
    Perform(editor, ^{ [editor insertNewline:nil]; });
    Expect([editor.string isEqualToString:@"Parent\n"], @"Return continues a numbered list.");
    Perform(editor, ^{ [editor insertTab:nil]; });
    Expect(TrailingLevel(editor) == 1, @"Tab nests a newly created list item.");
    Type(editor, @"Child");
    Expect(NPListLevelAt(editor.textStorage, 7) == 1, @"Typing keeps the child's list level.");
    Perform(editor, ^{ [editor insertNewline:nil]; });
    Expect(TrailingBlock(editor) == NPBlockNumbered && TrailingLevel(editor) == 1,
           @"Return continues the current nested level.");
    Perform(editor, ^{ [editor insertBacktab:nil]; });
    Expect(TrailingLevel(editor) == 0, @"Shift-Tab returns to the parent list level.");
    Perform(editor, ^{ [editor insertTab:nil]; });
    Perform(editor, ^{ [editor insertNewline:nil]; });
    Expect(TrailingLevel(editor) == 0 && TrailingBlock(editor) == NPBlockNumbered,
           @"Return on an empty nested item outdents before exiting.");
    Perform(editor, ^{ [editor insertNewline:nil]; });
    Expect(TrailingBlock(editor) == NPBlockBody, @"Return on an empty top-level item ends the list.");

    NSRange child = [editor.string rangeOfString:@"Child"];
    Select(editor, child.location);
    Perform(editor, ^{ [editor insertBacktab:nil]; });
    Expect(NPListLevelAt(editor.textStorage, child.location) == 0, @"A populated child can be outdented at its start.");
    [editor.tabUndoManager undo];
    Expect(NPListLevelAt(editor.textStorage, child.location) == 1, @"Undo restores list depth.");

    Load(editor, @"Parent\n   ", NPBlockNumbered, 1);
    Perform(editor, ^{ [editor insertNewline:nil]; });
    Expect(NPListLevelAt(editor.textStorage, 7) == 0, @"Whitespace-only nested items outdent on Return.");
    puts("PASS nested lists");
}

static void TestCheckboxes(NPLiveEditor *editor) {
    Load(editor, @"", NPBlockBody, 0);
    Type(editor, @"[]");
    Expect(TrailingBlock(editor) == NPBlockTaskUnchecked && editor.string.length == 0,
           @"The empty bracket shortcut creates a checkbox.");

    Load(editor, @"First\nSecond\nThird", NPBlockTaskUnchecked, 0);
    Select(editor, 0);
    Perform(editor, ^{ [editor toggleTaskAtSelection]; });
    Expect([editor.string isEqualToString:@"Second\nThird\nFirst"], @"Completing a task moves it below open tasks.");
    NSUInteger first = [editor.string rangeOfString:@"First"].location;
    Expect(BlockAt(editor.textStorage, first) == NPBlockTaskChecked, @"The moved task remains checked.");
    Expect([[editor.textStorage attribute:NSStrikethroughStyleAttributeName atIndex:first effectiveRange:NULL] integerValue] != 0,
           @"Completed task text is struck through.");
    [editor.tabUndoManager undo];
    Expect([editor.string isEqualToString:@"First\nSecond\nThird"], @"Undo restores task order.");
    Expect(BlockAt(editor.textStorage, 0) == NPBlockTaskUnchecked, @"Undo restores checkbox state.");
    [editor.tabUndoManager redo];
    Expect([editor.string isEqualToString:@"Second\nThird\nFirst"], @"Redo restores completion sorting.");
    first = [editor.string rangeOfString:@"First"].location;
    Select(editor, first);
    Perform(editor, ^{ [editor toggleTaskAtSelection]; });
    Expect(BlockAt(editor.textStorage, first) == NPBlockTaskUnchecked, @"A completed task can be unchecked.");
    Expect([[editor.textStorage attribute:NSStrikethroughStyleAttributeName atIndex:first effectiveRange:NULL] integerValue] == 0,
           @"Unchecking removes automatic strikethrough.");
    puts("PASS checkboxes and undo");
}

static void TestMarkdownAndSnapshots(void) {
    NPBlockStyle trailing = NPBlockBody;
    NSUInteger trailingLevel = 0;
    NSString *source = @"1. Parent\r\n    1. Child\r\n    2. Other child\r\n2. Next\r\n    - [ ] Task\r\n    - [x] Done\r\n";
    NSMutableAttributedString *decoded = NPDecodeMarkdownWithListLevel(source, &trailing, &trailingLevel);
    NSUInteger child = [decoded.string rangeOfString:@"Child"].location;
    Expect(NPListLevelAt(decoded, child) == 1, @"Markdown imports nested list levels.");
    NSString *encoded = NPEncodeMarkdownWithListLevel(decoded, trailing, trailingLevel);
    Expect([encoded isEqualToString:source], @"Numbering, checkbox state, and CRLF round-trip through Markdown.");

    NSDictionary *snapshot = NPFormattingSnapshot(decoded, trailing);
    NPBlockStyle restoredTrailing = NPBlockBody;
    NSAttributedString *restored = NPTextWithFormatting(decoded.string, snapshot, &restoredTrailing);
    Expect([snapshot isEqual:NPFormattingSnapshot(restored, restoredTrailing)], @"Formatting snapshots preserve list metadata.");
    Expect([NPEncodeMarkdownWithListLevel(restored, restoredTrailing, trailingLevel) isEqualToString:source],
           @"Restoring draft metadata preserves Markdown output.");

    source = @"1. Parent\n    1. ";
    decoded = NPDecodeMarkdownWithListLevel(source, &trailing, &trailingLevel);
    Expect(trailing == NPBlockNumbered && trailingLevel == 1, @"An empty final nested item keeps its level.");
    Expect([NPEncodeMarkdownWithListLevel(decoded, trailing, trailingLevel) isEqualToString:source],
           @"Empty final nested items round-trip.");

    source = @"```python\n    value = '**literal**'\n```\n";
    decoded = NPDecodeMarkdownWithListLevel(source, &trailing, &trailingLevel);
    Expect([decoded.string isEqualToString:@"    value = '**literal**'\n"], @"Code preserves indentation and literal Markdown characters.");
    Expect(BlockAt(decoded, 0) == NPBlockCode, @"Fenced code imports as a code block.");
    Expect(InlineAt(decoded, 0) == 0, @"Code contents remain literal.");
    Expect([NPEncodeMarkdownWithListLevel(decoded, trailing, trailingLevel) isEqualToString:source],
           @"Code language and literal content round-trip.");
    puts("PASS Markdown and formatting snapshots");
}

static void TestSessionRoundTrip(void) {
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSURL *url = [[NSURL fileURLWithPath:directory isDirectory:YES] URLByAppendingPathComponent:@"session.json"];
    NPSession *session = [[NPSession alloc] init];
    NPNote *note = [[NPNote alloc] init];
    note.text = @"A draft with తెలుగు and emoji 🙂";
    note.dirty = YES;
    note.selection = NSMakeRange(4, 5);
    note.formatting = @{@"blocks": @[@[@0, @(note.text.length), @(NPBlockHeading1)]]};
    [session.notes addObject:note];
    session.selectedID = note.identifier;
    NSError *error = nil;
    Expect([session writeToURL:url error:&error], [NSString stringWithFormat:@"A draft session can be written atomically (%@).", error]);
    NPSession *loaded = [NPSession loadFromURL:url error:&error];
    Expect(loaded != nil && loaded.notes.count == 1, @"A written session can be restored.");
    NPNote *restored = loaded.notes.firstObject;
    Expect([restored.text isEqualToString:note.text], @"Session restore preserves Unicode draft text.");
    Expect([restored.formatting isEqual:note.formatting], @"Session restore preserves formatting metadata.");
    Expect(NSEqualRanges(restored.selection, note.selection), @"Session restore preserves the cursor selection.");
    Expect([loaded.selectedID isEqualToString:note.identifier], @"Session restore selects the original tab.");
    [NSFileManager.defaultManager removeItemAtPath:directory error:NULL];
    puts("PASS session restore");
}

int main(void) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyProhibited];
        [app finishLaunching];

        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 800, 500)
                                                     styleMask:NSWindowStyleMaskTitled
                                                       backing:NSBackingStoreBuffered defer:NO];
        window.releasedWhenClosed = NO;
        NPLiveEditor *editor = [[NPLiveEditor alloc] initWithFrame:window.contentView.bounds];
        (void)editor.layoutManager;
        editor.richText = YES;
        editor.editable = YES;
        editor.allowsUndo = YES;
        editor.tabUndoManager = [[NSUndoManager alloc] init];
        editor.tabUndoManager.groupsByEvent = NO;
        __attribute__((objc_precise_lifetime)) EditorDelegate *delegate = [[EditorDelegate alloc] init];
        delegate.manager = editor.tabUndoManager;
        editor.delegate = delegate;
        [editor configureTextSize:14 fontName:@""];
        [window.contentView addSubview:editor];
        [window makeFirstResponder:editor];

        TestHeadingEditing(editor);
        TestInlineFormatting(editor);
        TestListNesting(editor);
        TestCheckboxes(editor);
        TestMarkdownAndSnapshots();
        TestSessionRoundTrip();
        printf("PASS %lu assertions\n", (unsigned long)assertionCount);
        [window close];
    }
    return EXIT_SUCCESS;
}
