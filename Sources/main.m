#import <AppKit/AppKit.h>
#import "EditorTypography.h"
#import "LiveEditor.h"
#import "LiveMarkdown.h"
#import "SessionStore.h"

typedef NS_ENUM(NSInteger, NPTheme) {
    NPThemeSystem,
    NPThemeLight,
    NPThemeDark,
    NPThemePaper,
};

static NSString *const NPThemeDefaultsKey = @"NotepadTheme";
static NSString *const NPTextSizeDefaultsKey = @"NotepadTextSize";
static NSString *const NPFontDefaultsKey = @"NotepadFont";

static NSUInteger SavedListLevel(NSDictionary *formatting) {
    id value = formatting[@"trailingListLevel"];
    if (![value isKindOfClass:NSNumber.class] || [value integerValue] < 0) return 0;
    return MIN(NPMaxListLevel, [value unsignedIntegerValue]);
}

typedef NS_ENUM(NSInteger, NPFontChoice) {
    NPFontComicSans,
    NPFontSystem,
    NPFontMonospaced,
};

static NSString *NoteTitle(NPNote *note) {
    if (note.filePath) return note.filePath.lastPathComponent;

    __block NSString *title = @"Untitled";
    [note.text enumerateSubstringsInRange:NSMakeRange(0, note.text.length)
                                 options:NSStringEnumerationByLines
                              usingBlock:^(NSString *line, NSRange range, NSRange enclosingRange, BOOL *stop) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (trimmed.length == 0) return;
        if (trimmed.length > 64) {
            NSRange prefix = [trimmed rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, 64)];
            trimmed = [[trimmed substringWithRange:prefix] stringByAppendingString:@"…"];
        }
        title = trimmed;
        *stop = YES;
    }];
    return title;
}

static NSDate *FileModificationDate(NSURL *url) {
    id value = nil;
    [url removeCachedResourceValueForKey:NSURLContentModificationDateKey];
    [url getResourceValue:&value forKey:NSURLContentModificationDateKey error:NULL];
    return [value isKindOfClass:NSDate.class] ? value : nil;
}

@interface NPTab : NSView
@property (nonatomic, strong) NSButton *selectButton;
@property (nonatomic, strong) NSButton *closeButton;
@property (nonatomic, strong) NSColor *selectedBackground;
@property (nonatomic) BOOL selected;
- (void)displayNote:(NPNote *)note selected:(BOOL)selected;
@end

@implementation NPTab
- (void)displayNote:(NPNote *)note selected:(BOOL)selected {
    NSString *title = NoteTitle(note);
    self.selectButton.title = title;
    self.selectButton.font = [NSFont systemFontOfSize:12 weight:selected ? NSFontWeightSemibold : NSFontWeightRegular];
    self.selectButton.toolTip = note.filePath ?: title;
    self.closeButton.accessibilityLabel = [NSString stringWithFormat:@"Close %@", title];
    self.selected = selected;
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    if (!self.selected) return;
    NSRect background = NSInsetRect(self.bounds, 1, 1);
    NSBezierPath *shape = [NSBezierPath bezierPathWithRoundedRect:background xRadius:6 yRadius:6];
    [self.selectedBackground setFill];
    [shape fill];
    [NSColor.separatorColor setStroke];
    shape.lineWidth = 1;
    [shape stroke];
}
@end

@interface NPTabScroller : NSScrollView
@end

@implementation NPTabScroller
- (void)scrollWheel:(NSEvent *)event {
    NSClipView *clip = self.contentView;
    if (event.scrollingDeltaX == 0 && event.scrollingDeltaY != 0 &&
        NSWidth(self.documentView.frame) > NSWidth(clip.bounds)) {
        NSPoint origin = clip.bounds.origin;
        origin.x -= event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 12);
        [clip scrollToPoint:[clip constrainScrollPoint:origin]];
        [self reflectScrolledClipView:clip];
        return;
    }
    [super scrollWheel:event];
}
@end

@interface NPApp : NSObject <NSApplicationDelegate, NSWindowDelegate, NSTextViewDelegate>
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) NSView *editorHost;
@property (nonatomic, strong) NSBox *tabBarBackground;
@property (nonatomic) NPTheme theme;
@property (nonatomic) CGFloat editorTextSize;
@property (nonatomic) NPFontChoice fontChoice;
@property (nonatomic, strong) NPTabScroller *tabScroller;
@property (nonatomic, strong) NSView *tabDocument;
@property (nonatomic, strong) NSLayoutConstraint *tabWidth;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NPTab *> *tabViews;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSScrollView *> *editors;
@property (nonatomic, strong) NSMutableArray<NSString *> *pendingOpenPaths;
@property (nonatomic, strong) NPNote *visibleNote;
@property (nonatomic, strong) NPSession *session;
@property (nonatomic, strong) NSURL *sessionURL;
@property (nonatomic, strong) NSTimer *saveTimer;
@property (nonatomic, strong) NSTextField *saveWarning;
@property (nonatomic, strong) NSError *loadError;
@property (nonatomic) BOOL needsSave;
- (void)selectNote:(NPNote *)note;
- (void)scheduleSave;
- (BOOL)openURL:(NSURL *)url;
- (BOOL)saveSessionShowingError:(BOOL)showError;
- (void)newTab:(id)sender;
- (void)closeTab:(id)sender;
- (void)reopenTab:(id)sender;
- (void)nextTab:(id)sender;
- (void)previousTab:(id)sender;
- (void)openFiles:(id)sender;
- (void)saveFile:(id)sender;
- (void)saveFileAs:(id)sender;
- (void)toggleWrap:(id)sender;
- (void)changeTheme:(NSMenuItem *)sender;
- (void)formatBlock:(NSMenuItem *)sender;
- (void)formatInline:(NSMenuItem *)sender;
- (void)toggleTask:(id)sender;
- (void)changeTextSize:(NSMenuItem *)sender;
- (void)changeEditorFont:(NSMenuItem *)sender;
- (void)pasteMarkdown:(id)sender;
@end

static NSMenuItem *MenuItem(NSString *title, SEL action, NSString *key,
                            NSEventModifierFlags modifiers, id target) {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:key];
    item.keyEquivalentModifierMask = modifiers;
    item.target = target;
    return item;
}

static NSMenu *Submenu(NSMenu *parent, NSString *title) {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
    NSMenu *menu = [[NSMenu alloc] initWithTitle:title];
    item.submenu = menu;
    [parent addItem:item];
    return menu;
}

static NSButton *IconButton(NSString *symbol, NSString *label, id target, SEL action) {
    NSImage *image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:label];
    NSImageSymbolConfiguration *config = [NSImageSymbolConfiguration configurationWithPointSize:11 weight:NSFontWeightMedium];
    NSButton *button = [NSButton buttonWithImage:[image imageWithSymbolConfiguration:config]
                                         target:target action:action];
    button.bordered = NO;
    button.toolTip = label;
    button.accessibilityLabel = label;
    return button;
}

@implementation NPApp
- (instancetype)init {
    self = [super init];
    if (self) {
        _sessionURL = NPSession.defaultURL;
        NSError *error = nil;
        _session = [NPSession loadFromURL:_sessionURL error:&error];
        if (!_session) {
            _session = [[NPSession alloc] init];
            _loadError = error;
        }
        _tabViews = [NSMutableDictionary dictionary];
        _editors = [NSMutableDictionary dictionary];
        _pendingOpenPaths = [NSMutableArray array];
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSInteger savedTheme = [defaults integerForKey:NPThemeDefaultsKey];
        _theme = savedTheme >= NPThemeSystem && savedTheme <= NPThemePaper ? (NPTheme)savedTheme : NPThemeSystem;
        _editorTextSize = NPConstrainEditorTextSize([defaults doubleForKey:NPTextSizeDefaultsKey]);
        NSInteger savedFont = [defaults integerForKey:NPFontDefaultsKey];
        _fontChoice = savedFont >= NPFontComicSans && savedFont <= NPFontMonospaced ? (NPFontChoice)savedFont : NPFontComicSans;
    }
    return self;
}

- (void)installMenus {
    NSEventModifierFlags cmd = NSEventModifierFlagCommand;
    NSEventModifierFlags shift = NSEventModifierFlagShift;
    NSEventModifierFlags option = NSEventModifierFlagOption;
    NSMenu *bar = [[NSMenu alloc] initWithTitle:@""];
    NSMenu *app = Submenu(bar, @"Notepad");
    [app addItem:MenuItem(@"About Notepad", @selector(orderFrontStandardAboutPanel:), @"", 0, NSApp)];
    [app addItem:NSMenuItem.separatorItem];
    [app addItem:MenuItem(@"Hide Notepad", @selector(hide:), @"h", cmd, NSApp)];
    [app addItem:MenuItem(@"Hide Others", @selector(hideOtherApplications:), @"h", cmd | option, NSApp)];
    [app addItem:MenuItem(@"Show All", @selector(unhideAllApplications:), @"", 0, NSApp)];
    [app addItem:NSMenuItem.separatorItem];
    [app addItem:MenuItem(@"Quit Notepad", @selector(terminate:), @"q", cmd, NSApp)];

    NSMenu *file = Submenu(bar, @"File");
    [file addItem:MenuItem(@"New Tab", @selector(newTab:), @"t", cmd, self)];
    [file addItem:MenuItem(@"New", @selector(newTab:), @"n", cmd, self)];
    [file addItem:MenuItem(@"Open…", @selector(openFiles:), @"o", cmd, self)];
    [file addItem:NSMenuItem.separatorItem];
    [file addItem:MenuItem(@"Save", @selector(saveFile:), @"s", cmd, self)];
    [file addItem:MenuItem(@"Save As…", @selector(saveFileAs:), @"s", cmd | shift, self)];
    [file addItem:NSMenuItem.separatorItem];
    [file addItem:MenuItem(@"Close Tab", @selector(closeTab:), @"w", cmd, self)];
    [file addItem:MenuItem(@"Reopen Closed Tab", @selector(reopenTab:), @"t", cmd | shift, self)];
    [file addItem:MenuItem(@"Close Window", @selector(performClose:), @"w", cmd | shift, nil)];

    NSMenu *edit = Submenu(bar, @"Edit");
    [edit addItem:MenuItem(@"Undo", @selector(undo:), @"z", cmd, nil)];
    [edit addItem:MenuItem(@"Redo", @selector(redo:), @"z", cmd | shift, nil)];
    [edit addItem:NSMenuItem.separatorItem];
    [edit addItem:MenuItem(@"Cut", @selector(cut:), @"x", cmd, nil)];
    [edit addItem:MenuItem(@"Copy", @selector(copy:), @"c", cmd, nil)];
    [edit addItem:MenuItem(@"Paste", @selector(paste:), @"v", cmd, nil)];
    [edit addItem:MenuItem(@"Paste as Markdown", @selector(pasteMarkdown:), @"v", cmd | option | shift, self)];
    [edit addItem:MenuItem(@"Select All", @selector(selectAll:), @"a", cmd, nil)];
    [edit addItem:NSMenuItem.separatorItem];
    NSMenu *find = Submenu(edit, @"Find");
    NSMenuItem *showFind = MenuItem(@"Find…", @selector(performTextFinderAction:), @"f", cmd, nil);
    showFind.tag = NSTextFinderActionShowFindInterface;
    [find addItem:showFind];
    NSMenuItem *nextFind = MenuItem(@"Find Next", @selector(performTextFinderAction:), @"g", cmd, nil);
    nextFind.tag = NSTextFinderActionNextMatch;
    [find addItem:nextFind];
    NSMenuItem *previousFind = MenuItem(@"Find Previous", @selector(performTextFinderAction:), @"g", cmd | shift, nil);
    previousFind.tag = NSTextFinderActionPreviousMatch;
    [find addItem:previousFind];

    NSMenu *format = Submenu(bar, @"Format");
    NSMenuItem *bold = MenuItem(@"Bold", @selector(formatInline:), @"b", cmd, self);
    bold.tag = NPInlineBold;
    [format addItem:bold];
    NSMenuItem *italic = MenuItem(@"Italic", @selector(formatInline:), @"i", cmd, self);
    italic.tag = NPInlineItalic;
    [format addItem:italic];
    [format addItem:NSMenuItem.separatorItem];
    NSArray<NSString *> *blocks = @[@"Body", @"Heading 1", @"Heading 2", @"Heading 3", @"Heading 4", @"Heading 5", @"Heading 6", @"Bulleted List", @"Numbered List"];
    for (NSUInteger index = 0; index < blocks.count; index++) {
        NSMenuItem *item = MenuItem(blocks[index], @selector(formatBlock:), @"", 0, self);
        item.tag = index;
        [format addItem:item];
    }
    [format addItem:NSMenuItem.separatorItem];
    [format addItem:MenuItem(@"Toggle Checkbox", @selector(toggleTask:), @"", 0, self)];

    NSMenu *view = Submenu(bar, @"View");
    [view addItem:MenuItem(@"Word Wrap", @selector(toggleWrap:), @"", 0, self)];
    NSMenu *textSize = Submenu(view, @"Text Size");
    NSMenuItem *increase = MenuItem(@"Increase Text Size", @selector(changeTextSize:), @"=", cmd, self);
    increase.tag = 1;
    [textSize addItem:increase];
    NSMenuItem *increaseAlternate = MenuItem(@"Increase Text Size", @selector(changeTextSize:), @"+", cmd, self);
    increaseAlternate.tag = 1;
    increaseAlternate.hidden = YES;
    increaseAlternate.allowsKeyEquivalentWhenHidden = YES;
    [textSize addItem:increaseAlternate];
    NSMenuItem *decrease = MenuItem(@"Decrease Text Size", @selector(changeTextSize:), @"-", cmd, self);
    decrease.tag = -1;
    [textSize addItem:decrease];
    [textSize addItem:MenuItem(@"Actual Size", @selector(changeTextSize:), @"0", cmd, self)];

    NSMenu *fontMenu = Submenu(view, @"Font");
    NSArray<NSString *> *fonts = @[@"Comic Sans MS", @"System", @"Monospaced"];
    for (NSUInteger index = 0; index < fonts.count; index++) {
        NSMenuItem *item = MenuItem(fonts[index], @selector(changeEditorFont:), @"", 0, self);
        item.tag = index;
        [fontMenu addItem:item];
    }

    NSMenu *themeMenu = Submenu(view, @"Theme");
    NSArray<NSString *> *themeTitles = @[@"System", @"Light", @"Dark", @"Paper"];
    for (NSUInteger index = 0; index < themeTitles.count; index++) {
        NSMenuItem *item = MenuItem(themeTitles[index], @selector(changeTheme:), @"", 0, self);
        item.tag = index;
        [themeMenu addItem:item];
    }

    NSMenu *window = Submenu(bar, @"Window");
    [window addItem:MenuItem(@"Minimize", @selector(performMiniaturize:), @"m", cmd, nil)];
    [window addItem:MenuItem(@"Zoom", @selector(performZoom:), @"", 0, nil)];
    [window addItem:NSMenuItem.separatorItem];
    [window addItem:MenuItem(@"Select Next Tab", @selector(nextTab:), @"\t", NSEventModifierFlagControl, self)];
    [window addItem:MenuItem(@"Select Previous Tab", @selector(previousTab:), @"\t", NSEventModifierFlagControl | shift, self)];
    NSApp.mainMenu = bar;
    NSApp.windowsMenu = window;
}

- (NSColor *)editorBackground {
    if (self.theme != NPThemePaper) return NSColor.textBackgroundColor;
    return [NSColor colorWithSRGBRed:250.0 / 255.0 green:243.0 / 255.0 blue:226.0 / 255.0 alpha:1];
}

- (NSColor *)toolbarBackground {
    if (self.theme != NPThemePaper) return NSColor.windowBackgroundColor;
    return [NSColor colorWithSRGBRed:241.0 / 255.0 green:232.0 / 255.0 blue:211.0 / 255.0 alpha:1];
}

- (void)applyTheme {
    NSAppearanceName appearance = nil;
    if (self.theme == NPThemeLight || self.theme == NPThemePaper) appearance = NSAppearanceNameAqua;
    if (self.theme == NPThemeDark) appearance = NSAppearanceNameDarkAqua;
    NSApp.appearance = appearance ? [NSAppearance appearanceNamed:appearance] : nil;

    self.tabBarBackground.fillColor = [self toolbarBackground];
    NSColor *editorBackground = [self editorBackground];
    for (NSScrollView *scroll in self.editors.allValues) {
        scroll.backgroundColor = editorBackground;
        ((NSTextView *)scroll.documentView).backgroundColor = editorBackground;
    }
    for (NPTab *tab in self.tabViews.allValues) {
        tab.selectedBackground = editorBackground;
        [tab setNeedsDisplay:YES];
    }
}

- (void)changeTheme:(NSMenuItem *)sender {
    self.theme = (NPTheme)sender.tag;
    [NSUserDefaults.standardUserDefaults setInteger:self.theme forKey:NPThemeDefaultsKey];
    [self applyTheme];
}

- (NSString *)preferredEditorFontName {
    if (self.fontChoice == NPFontMonospaced) return nil;
    return self.fontChoice == NPFontComicSans ? NPComicSansFontName() ?: @"" : @"";
}

- (void)applyEditorTypography {
    NSString *fontName = [self preferredEditorFontName];
    for (NSScrollView *scroll in self.editors.allValues) {
        [(NPLiveEditor *)scroll.documentView configureTextSize:self.editorTextSize fontName:fontName];
    }
}

- (void)changeTextSize:(NSMenuItem *)sender {
    CGFloat size = sender.tag ? self.editorTextSize + sender.tag : NPDefaultEditorTextSize();
    self.editorTextSize = NPConstrainEditorTextSize(size);
    [NSUserDefaults.standardUserDefaults setDouble:self.editorTextSize forKey:NPTextSizeDefaultsKey];
    [self applyEditorTypography];
}

- (void)changeEditorFont:(NSMenuItem *)sender {
    self.fontChoice = (NPFontChoice)sender.tag;
    [NSUserDefaults.standardUserDefaults setInteger:self.fontChoice forKey:NPFontDefaultsKey];
    [self applyEditorTypography];
}

- (void)makeWindow {
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 760, 530)
                                             styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                       NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                               backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"Notepad";
    self.window.tabbingMode = NSWindowTabbingModeDisallowed;
    self.window.releasedWhenClosed = NO;
    self.window.delegate = self;
    self.window.contentMinSize = NSMakeSize(330, 240);
    [self.window center];
    [self.window setFrameAutosaveName:@"Notepad Window"];

    NSView *root = self.window.contentView;
    NSView *strip = [[NSView alloc] initWithFrame:NSZeroRect];
    strip.translatesAutoresizingMaskIntoConstraints = NO;
    NSBox *background = [[NSBox alloc] initWithFrame:NSZeroRect];
    background.boxType = NSBoxCustom;
    background.borderType = NSNoBorder;
    background.fillColor = [self toolbarBackground];
    background.translatesAutoresizingMaskIntoConstraints = NO;
    [strip addSubview:background];
    self.tabBarBackground = background;

    self.tabScroller = [[NPTabScroller alloc] initWithFrame:NSZeroRect];
    self.tabScroller.drawsBackground = NO;
    self.tabScroller.hasHorizontalScroller = YES;
    self.tabScroller.scrollerStyle = NSScrollerStyleOverlay;
    self.tabScroller.autohidesScrollers = YES;
    self.tabScroller.translatesAutoresizingMaskIntoConstraints = NO;
    [strip addSubview:self.tabScroller];
    self.tabDocument = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 0, 32)];
    self.tabScroller.documentView = self.tabDocument;
    self.tabWidth = [self.tabScroller.widthAnchor constraintEqualToConstant:0];
    self.tabWidth.priority = NSLayoutPriorityDefaultHigh;

    NSButton *add = IconButton(@"plus", @"New Tab (⌘T)", self, @selector(newTab:));
    add.translatesAutoresizingMaskIntoConstraints = NO;
    [strip addSubview:add];

    NSBox *separator = [[NSBox alloc] initWithFrame:NSZeroRect];
    separator.boxType = NSBoxSeparator;
    separator.translatesAutoresizingMaskIntoConstraints = NO;
    self.editorHost = [[NSView alloc] initWithFrame:NSZeroRect];
    self.editorHost.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:strip];
    [root addSubview:separator];
    [root addSubview:self.editorHost];

    self.saveWarning = [NSTextField labelWithString:@"Couldn’t save drafts."];
    self.saveWarning.font = [NSFont systemFontOfSize:11];
    self.saveWarning.textColor = NSColor.systemRedColor;
    self.saveWarning.hidden = YES;
    self.saveWarning.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:self.saveWarning];

    [NSLayoutConstraint activateConstraints:@[
        [strip.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [strip.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [strip.topAnchor constraintEqualToAnchor:root.topAnchor],
        [strip.heightAnchor constraintEqualToConstant:40],
        [background.leadingAnchor constraintEqualToAnchor:strip.leadingAnchor],
        [background.trailingAnchor constraintEqualToAnchor:strip.trailingAnchor],
        [background.topAnchor constraintEqualToAnchor:strip.topAnchor],
        [background.bottomAnchor constraintEqualToAnchor:strip.bottomAnchor],
        [self.tabScroller.leadingAnchor constraintEqualToAnchor:strip.leadingAnchor constant:9],
        [self.tabScroller.trailingAnchor constraintEqualToAnchor:add.leadingAnchor constant:-5],
        [self.tabScroller.centerYAnchor constraintEqualToAnchor:strip.centerYAnchor],
        [self.tabScroller.heightAnchor constraintEqualToConstant:32],
        self.tabWidth,
        [add.trailingAnchor constraintLessThanOrEqualToAnchor:strip.trailingAnchor constant:-8],
        [add.centerYAnchor constraintEqualToAnchor:strip.centerYAnchor],
        [add.widthAnchor constraintEqualToConstant:32],
        [add.heightAnchor constraintEqualToConstant:30],
        [separator.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [separator.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [separator.topAnchor constraintEqualToAnchor:strip.bottomAnchor],
        [separator.heightAnchor constraintEqualToConstant:1],
        [self.editorHost.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [self.editorHost.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [self.editorHost.topAnchor constraintEqualToAnchor:separator.bottomAnchor],
        [self.editorHost.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        [self.saveWarning.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:18],
        [self.saveWarning.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-8],
    ]];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [self applyTheme];
    [self makeWindow];
    if (self.session.notes.count == 0) [self.session.notes addObject:[[NPNote alloc] init]];
    NPNote *selected = self.session.notes.firstObject;
    for (NPNote *note in self.session.notes) {
        if ([note.identifier isEqualToString:self.session.selectedID]) {
            selected = note;
            break;
        }
    }
    [self.window makeKeyAndOrderFront:nil];
    [self.window.contentView layoutSubtreeIfNeeded];
    [self selectNote:selected];
    if (self.loadError) [self recoverUnreadableSession];
    if (self.pendingOpenPaths.count) {
        NSArray<NSString *> *paths = [self.pendingOpenPaths copy];
        [self.pendingOpenPaths removeAllObjects];
        [self application:NSApp openFiles:paths];
    }
}

- (void)recoverUnreadableSession {
    NSURL *backup = [[self.sessionURL URLByDeletingLastPathComponent]
                     URLByAppendingPathComponent:[NSString stringWithFormat:@"session-recovery-%@.json", NSUUID.UUID.UUIDString]];
    NSError *backupError = nil;
    BOOL moved = [NSFileManager.defaultManager moveItemAtURL:self.sessionURL toURL:backup error:&backupError];
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Notepad couldn’t restore your previous tabs.";
    if (moved) {
        self.loadError = nil;
        alert.informativeText = [NSString stringWithFormat:@"A copy of the previous session is at %@.", backup.path];
    } else {
        alert.informativeText = [NSString stringWithFormat:@"The previous session is still at %@. Notepad will keep it intact. %@", self.sessionURL.path, backupError.localizedDescription];
    }
    [alert addButtonWithTitle:@"OK"];
    [alert beginSheetModalForWindow:self.window completionHandler:nil];
}

- (void)applyWrappingToEditor:(NSScrollView *)scroll {
    NSTextView *text = (NSTextView *)scroll.documentView;
    BOOL wrap = self.session.wrapsLines;
    CGFloat width = MAX(1, NSWidth(scroll.contentView.bounds));
    text.horizontallyResizable = !wrap;
    text.autoresizingMask = wrap ? NSViewWidthSizable : NSViewNotSizable;
    text.textContainer.widthTracksTextView = wrap;
    text.textContainer.containerSize = NSMakeSize(wrap ? MAX(1, width - text.textContainerInset.width * 2) : CGFLOAT_MAX, CGFLOAT_MAX);
    if (wrap) [text setFrameSize:NSMakeSize(width, NSHeight(text.frame))];
    scroll.hasHorizontalScroller = !wrap;
}

- (NSScrollView *)editorForNote:(NPNote *)note {
    NSScrollView *scroll = self.editors[note.identifier];
    if (scroll) return scroll;
    NSRect rect = self.editorHost.bounds;
    scroll = [[NSScrollView alloc] initWithFrame:rect];
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.borderType = NSNoBorder;
    scroll.backgroundColor = [self editorBackground];

    NPLiveEditor *text = [[NPLiveEditor alloc] initWithFrame:rect];
    // List markers use the glyph geometry provided by TextKit 1.
    (void)text.layoutManager;
    text.tabUndoManager = [[NSUndoManager alloc] init];
    text.richText = YES;
    text.importsGraphics = NO;
    text.allowsUndo = YES;
    text.usesFindBar = YES;
    text.incrementalSearchingEnabled = YES;
    text.automaticQuoteSubstitutionEnabled = NO;
    text.automaticDashSubstitutionEnabled = NO;
    text.automaticTextReplacementEnabled = NO;
    text.automaticSpellingCorrectionEnabled = NO;
    text.continuousSpellCheckingEnabled = NO;
    text.grammarCheckingEnabled = NO;
    text.smartInsertDeleteEnabled = NO;
    [text configureTextSize:self.editorTextSize fontName:[self preferredEditorFontName]];
    text.backgroundColor = [self editorBackground];
    text.textColor = NSColor.textColor;
    text.insertionPointColor = NSColor.textColor;
    text.textContainerInset = NSMakeSize(17, 14);
    text.minSize = NSMakeSize(0, 0);
    text.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
    text.verticallyResizable = YES;
    text.accessibilityLabel = @"Note editor";
    NPBlockStyle trailingBlock = NPBlockBody;
    NSUInteger trailingListLevel = 0;
    NSAttributedString *document;
    if (!note.formatting && note.needsMarkdownImport) {
        document = NPDecodeMarkdownWithListLevel(note.text, &trailingBlock, &trailingListLevel);
        note.text = document.string;
        note.needsMarkdownImport = NO;
        [self scheduleSave];
    } else {
        document = NPTextWithFormatting(note.text, note.formatting, &trailingBlock);
        trailingListLevel = SavedListLevel(note.formatting);
    }
    NSUInteger caret = MIN(note.selection.location, document.length);
    note.selection = NSMakeRange(caret, MIN(note.selection.length, document.length - caret));
    [text loadDocument:document trailingBlock:trailingBlock listLevel:trailingListLevel];
    note.formatting = [text formattingSnapshot];
    scroll.documentView = text;
    [self applyWrappingToEditor:scroll];
    [text setSelectedRange:note.selection];
    [text refreshTypingAttributes];
    [text scrollRangeToVisible:note.selection];
    text.delegate = self;
    self.editors[note.identifier] = scroll;
    return scroll;
}

- (void)rebuildTabs {
    // Keep editor views intact so tab switching preserves each tab’s undo stack.
    for (NSView *view in self.tabDocument.subviews) [view removeFromSuperview];
    [self.tabViews removeAllObjects];
    CGFloat position = 0;
    for (NPNote *note in self.session.notes) {
        NPTab *tab = [[NPTab alloc] initWithFrame:NSMakeRect(position, 0, 166, 32)];
        tab.identifier = note.identifier;
        NSButton *select = [NSButton buttonWithTitle:@"" target:self action:@selector(tabClicked:)];
        select.frame = NSMakeRect(10, 1, 128, 30);
        select.bordered = NO;
        select.alignment = NSTextAlignmentLeft;
        select.cell.lineBreakMode = NSLineBreakByTruncatingTail;
        NSButton *close = IconButton(@"xmark", @"Close Tab", self, @selector(tabCloseClicked:));
        close.frame = NSMakeRect(139, 4, 24, 24);
        close.contentTintColor = NSColor.secondaryLabelColor;
        tab.selectButton = select;
        tab.closeButton = close;
        tab.selectedBackground = [self editorBackground];
        [tab addSubview:select];
        [tab addSubview:close];
        [tab displayNote:note selected:note == self.visibleNote];
        [self.tabDocument addSubview:tab];
        self.tabViews[note.identifier] = tab;
        position += 169;
    }
    [self.tabDocument setFrameSize:NSMakeSize(position, 32)];
    self.tabWidth.constant = position;
    [self.window.contentView layoutSubtreeIfNeeded];
}

- (void)selectNote:(NPNote *)note {
    if (!note) return;
    BOOL changed = self.visibleNote != note;
    if (changed) {
        [self.window makeFirstResponder:nil];
        if (self.visibleNote) [self.editors[self.visibleNote.identifier] removeFromSuperview];
        self.visibleNote = note;
    }
    self.session.selectedID = note.identifier;
    NSScrollView *scroll = [self editorForNote:note];
    if (!scroll.superview) {
        scroll.frame = self.editorHost.bounds;
        [self.editorHost addSubview:scroll];
        [self applyWrappingToEditor:scroll];
    }
    [self rebuildTabs];
    [self.tabDocument scrollRectToVisible:self.tabViews[note.identifier].frame];
    [self.window makeFirstResponder:scroll.documentView];
    if (changed) [self scheduleSave];
}

- (NPNote *)noteForTabButton:(NSButton *)button {
    NSString *identifier = button.superview.identifier;
    for (NPNote *note in self.session.notes) {
        if ([note.identifier isEqualToString:identifier]) return note;
    }
    return nil;
}

- (void)tabClicked:(NSButton *)button { [self selectNote:[self noteForTabButton:button]]; }
- (void)tabCloseClicked:(NSButton *)button { [self closeNote:[self noteForTabButton:button]]; }

- (void)newTab:(id)sender {
    NPNote *note = [[NPNote alloc] init];
    [self.session.notes addObject:note];
    [self selectNote:note];
    [self saveSessionShowingError:NO];
}

- (void)closeNote:(NPNote *)note {
    if (!note) return;
    NSUInteger index = [self.session.notes indexOfObjectIdenticalTo:note];
    if (index == NSNotFound) return;
    if (note == self.visibleNote) [self.window makeFirstResponder:nil];
    if (note.filePath || note.text.length > 0 || note.formatting.count > 0) {
        [self.session.closedNotes addObject:note];
        if (self.session.closedNotes.count > 20) [self.session.closedNotes removeObjectAtIndex:0];
    }
    [self.session.notes removeObjectAtIndex:index];
    [self.editors[note.identifier] removeFromSuperview];
    [self.editors removeObjectForKey:note.identifier];
    if (self.session.notes.count == 0) [self.session.notes addObject:[[NPNote alloc] init]];
    NPNote *next = note == self.visibleNote ? self.session.notes[MIN(index, self.session.notes.count - 1)] : self.visibleNote;
    [self selectNote:next];
    self.needsSave = YES;
    [self saveSessionShowingError:NO];
}

- (void)closeTab:(id)sender { [self closeNote:self.visibleNote]; }

- (void)reopenTab:(id)sender {
    NPNote *note = self.session.closedNotes.lastObject;
    if (!note) return;
    [self.session.closedNotes removeLastObject];
    [self.session.notes addObject:note];
    [self selectNote:note];
    [self saveSessionShowingError:NO];
}

- (void)cycleTabs:(NSInteger)offset {
    NSInteger count = (NSInteger)self.session.notes.count;
    NSInteger index = (NSInteger)[self.session.notes indexOfObjectIdenticalTo:self.visibleNote];
    if (count < 2 || index < 0 || index >= count) return;
    [self selectNote:self.session.notes[(index + offset + count) % count]];
}

- (void)nextTab:(id)sender { [self cycleTabs:1]; }
- (void)previousTab:(id)sender { [self cycleTabs:-1]; }

- (void)toggleWrap:(id)sender {
    self.session.wrapsLines = !self.session.wrapsLines;
    for (NSScrollView *scroll in self.editors.allValues) [self applyWrappingToEditor:scroll];
    [self scheduleSave];
}

- (NPLiveEditor *)activeEditor {
    if (!self.visibleNote) return nil;
    return (NPLiveEditor *)self.editors[self.visibleNote.identifier].documentView;
}

- (void)formatBlock:(NSMenuItem *)sender {
    [[self activeEditor] applyBlockStyle:(NPBlockStyle)sender.tag];
}

- (void)formatInline:(NSMenuItem *)sender {
    [[self activeEditor] toggleInlineStyle:(NPInlineStyle)sender.tag];
}

- (void)toggleTask:(id)sender {
    [[self activeEditor] toggleTaskAtSelection];
}

- (void)pasteMarkdown:(id)sender {
    NPLiveEditor *editor = [self activeEditor];
    if (!editor) return;
    [self.window makeFirstResponder:editor];
    [editor pasteAsMarkdown:sender];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    if (item.action == @selector(reopenTab:)) return self.session.closedNotes.count > 0;
    if (item.action == @selector(nextTab:) || item.action == @selector(previousTab:)) return self.session.notes.count > 1;
    if (item.action == @selector(toggleWrap:)) item.state = self.session.wrapsLines ? NSControlStateValueOn : NSControlStateValueOff;
    if (item.action == @selector(changeTheme:)) item.state = self.theme == item.tag ? NSControlStateValueOn : NSControlStateValueOff;
    if (item.action == @selector(formatInline:)) return [self activeEditor].selectedRange.length > 0;
    if (item.action == @selector(formatBlock:)) return [self activeEditor] != nil;
    if (item.action == @selector(toggleTask:)) return [[self activeEditor] hasTaskAtSelection];
    if (item.action == @selector(changeEditorFont:)) {
        BOOL comicAvailable = NPComicSansFontName() != nil;
        NPFontChoice current = self.fontChoice == NPFontComicSans && !comicAvailable ? NPFontSystem : self.fontChoice;
        item.state = current == item.tag ? NSControlStateValueOn : NSControlStateValueOff;
        if (item.tag == NPFontComicSans) item.title = comicAvailable ? @"Comic Sans MS" : @"Comic Sans MS (Unavailable)";
        return item.tag != NPFontComicSans || comicAvailable;
    }
    if (item.action == @selector(changeTextSize:)) {
        CGFloat requested = item.tag ? self.editorTextSize + item.tag : NPDefaultEditorTextSize();
        return self.editorTextSize != NPConstrainEditorTextSize(requested);
    }
    if (item.action == @selector(pasteMarkdown:)) {
        return [self activeEditor] != nil && [NSPasteboard.generalPasteboard availableTypeFromArray:@[NSPasteboardTypeString]] != nil;
    }
    return YES;
}

- (void)textDidChange:(NSNotification *)notification {
    if (!self.visibleNote || notification.object != self.editors[self.visibleNote.identifier].documentView) return;
    NPLiveEditor *text = notification.object;
    self.visibleNote.text = text.string;
    self.visibleNote.formatting = [text formattingSnapshot];
    self.visibleNote.needsMarkdownImport = NO;
    self.visibleNote.selection = text.selectedRange;
    self.visibleNote.dirty = YES;
    [self.tabViews[self.visibleNote.identifier] displayNote:self.visibleNote selected:YES];
    [self scheduleSave];
}

- (void)textViewDidChangeSelection:(NSNotification *)notification {
    if (!self.visibleNote || notification.object != self.editors[self.visibleNote.identifier].documentView) return;
    NPLiveEditor *text = notification.object;
    [text refreshTypingAttributes];
    NSRange selection = text.selectedRange;
    if (NSEqualRanges(selection, self.visibleNote.selection)) return;
    self.visibleNote.selection = selection;
    [self scheduleSave];
}

- (NSUndoManager *)undoManagerForTextView:(NSTextView *)view {
    return ((NPLiveEditor *)view).tabUndoManager;
}

- (void)scheduleSave {
    self.needsSave = YES;
    // A running timer also checkpoints continuous typing.
    if (self.saveTimer) return;
    __weak NPApp *app = self;
    self.saveTimer = [NSTimer scheduledTimerWithTimeInterval:0.35 repeats:NO block:^(NSTimer *timer) {
        app.saveTimer = nil;
        [app saveSessionShowingError:NO];
    }];
}

- (BOOL)saveSessionShowingError:(BOOL)showError {
    [self.saveTimer invalidate];
    self.saveTimer = nil;
    if (!self.needsSave) return YES;
    NSError *error = self.loadError;
    if (!error && [self.session writeToURL:self.sessionURL error:&error]) {
        self.needsSave = NO;
        self.saveWarning.hidden = YES;
        return YES;
    }
    self.saveWarning.hidden = NO;
    if (showError) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Notepad couldn’t save your open tabs.";
        alert.informativeText = [NSString stringWithFormat:@"%@ You can keep the window open and save important tabs as text files.", error.localizedDescription ?: @"An error occurred."];
        [alert addButtonWithTitle:@"Keep Notepad Open"];
        [alert addButtonWithTitle:@"Close Anyway"];
        return [alert runModal] == NSAlertSecondButtonReturn;
    }
    return NO;
}

- (void)applicationDidResignActive:(NSNotification *)notification {
    [self saveSessionShowingError:NO];
}

- (BOOL)windowShouldClose:(NSWindow *)window {
    [NSApp terminate:window];
    return NO;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    [self.window makeFirstResponder:nil];
    if ([self saveSessionShowingError:YES]) return NSTerminateNow;
    if (self.visibleNote) [self.window makeFirstResponder:self.editors[self.visibleNote.identifier].documentView];
    return NSTerminateCancel;
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)app hasVisibleWindows:(BOOL)visible {
    if (!visible) [self.window makeKeyAndOrderFront:nil];
    return YES;
}

- (void)showError:(NSError *)error title:(NSString *)title {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = title;
    alert.informativeText = error.localizedDescription ?: @"An error occurred.";
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
}

- (void)openFiles:(id)sender {
    NSOpenPanel *panel = NSOpenPanel.openPanel;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = YES;
    panel.message = @"Choose plain-text files to open in tabs.";
    if ([panel runModal] != NSModalResponseOK) return;
    for (NSURL *url in panel.URLs) [self openURL:url];
}

- (void)application:(NSApplication *)app openFiles:(NSArray<NSString *> *)filenames {
    if (!self.window) {
        [self.pendingOpenPaths addObjectsFromArray:filenames];
        return;
    }
    [self.window makeKeyAndOrderFront:nil];
    BOOL openedAll = YES;
    for (NSString *path in filenames) {
        if (![self openURL:[NSURL fileURLWithPath:path]]) openedAll = NO;
    }
    [app replyToOpenOrPrint:openedAll ? NSApplicationDelegateReplySuccess : NSApplicationDelegateReplyFailure];
}

- (BOOL)openURL:(NSURL *)url {
    NSURL *file = url.URLByResolvingSymlinksInPath;
    NSDate *date = FileModificationDate(file);
    NPNote *existingNote = nil;
    for (NPNote *note in self.session.notes) {
        if ([note.filePath isEqualToString:file.path]) {
            if (note.dirty || [note.fileModificationDate isEqualToDate:date]) {
                [self selectNote:note];
                return YES;
            }
            existingNote = note;
            break;
        }
    }
    NSError *error = nil;
    NSStringEncoding encoding = NSUTF8StringEncoding;
    NSData *data = [NSData dataWithContentsOfURL:file options:0 error:&error];
    NSString *text = nil;
    if (data) {
        const unsigned char *bytes = data.bytes;
        if (data.length >= 2 && ((bytes[0] == 0xff && bytes[1] == 0xfe) || (bytes[0] == 0xfe && bytes[1] == 0xff))) {
            encoding = NSUTF16StringEncoding;
        }
        text = [[NSString alloc] initWithData:data encoding:encoding];
    }
    unichar nullCharacter = 0;
    NSString *nullString = [NSString stringWithCharacters:&nullCharacter length:1];
    if (!text || [text rangeOfString:nullString].location != NSNotFound) {
        if (!error) error = [NSError errorWithDomain:@"Notepad" code:1 userInfo:@{
            NSLocalizedDescriptionKey: @"Choose a UTF-8 plain-text file or a UTF-16 text file with a byte-order mark."
        }];
        [self showError:error title:[NSString stringWithFormat:@"Couldn’t open %@.", file.lastPathComponent]];
        return NO;
    }
    NPNote *note = existingNote ?: [[NPNote alloc] init];
    note.filePath = file.path;
    note.fileModificationDate = date;
    note.fileEncoding = encoding;
    note.text = text;
    note.formatting = nil;
    note.needsMarkdownImport = NPPathUsesMarkdown(note.filePath);
    note.selection = NSMakeRange(MIN(note.selection.location, text.length), 0);
    if (existingNote) {
        if (self.visibleNote == note) [self.window makeFirstResponder:nil];
        [self.editors[note.identifier] removeFromSuperview];
        [self.editors removeObjectForKey:note.identifier];
        [self selectNote:note];
        self.needsSave = YES;
        [self saveSessionShowingError:NO];
        return YES;
    }
    if (self.session.notes.count == 1 && !self.visibleNote.filePath &&
        self.visibleNote.text.length == 0 && self.visibleNote.formatting.count == 0) {
        [self.session.notes removeAllObjects];
        [self.editors[self.visibleNote.identifier] removeFromSuperview];
        [self.editors removeObjectForKey:self.visibleNote.identifier];
    }
    [self.session.notes addObject:note];
    [self selectNote:note];
    [self saveSessionShowingError:NO];
    return YES;
}

- (void)saveFile:(id)sender {
    NPNote *note = self.visibleNote;
    if (!note.filePath) {
        [self saveFileAs:sender];
        return;
    }
    if (!note.dirty) return;
    NSURL *url = [NSURL fileURLWithPath:note.filePath];
    NSDate *date = FileModificationDate(url);
    if (!date || ![note.fileModificationDate isEqualToDate:date]) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"This file has changed on disk.";
        alert.informativeText = @"Save a copy to keep the current file, or replace it with the text in this tab.";
        [alert addButtonWithTitle:@"Save a Copy…"];
        [alert addButtonWithTitle:@"Cancel"];
        [alert addButtonWithTitle:@"Replace File"];
        NSModalResponse answer = [alert runModal];
        if (answer == NSAlertFirstButtonReturn) [self saveFileAs:sender];
        if (answer != NSAlertThirdButtonReturn) return;
    }
    [self writeNote:note toURL:url];
}

- (void)saveFileAs:(id)sender {
    NPNote *note = self.visibleNote;
    if (!note) return;
    NSSavePanel *panel = NSSavePanel.savePanel;
    if (note.filePath) {
        NSURL *url = [NSURL fileURLWithPath:note.filePath];
        panel.directoryURL = url.URLByDeletingLastPathComponent;
        panel.nameFieldStringValue = url.lastPathComponent;
    } else {
        panel.nameFieldStringValue = note.formatting.count ? @"Untitled.md" : @"Untitled.txt";
    }
    if ([panel runModal] == NSModalResponseOK) [self writeNote:note toURL:panel.URL.URLByResolvingSymlinksInPath];
}

- (void)writeNote:(NPNote *)note toURL:(NSURL *)url {
    NSError *error = nil;
    NSString *content = note.text;
    if (NPPathUsesMarkdown(url.path)) {
        NPBlockStyle trailing = NPBlockBody;
        NSAttributedString *document = NPTextWithFormatting(note.text, note.formatting, &trailing);
        content = NPEncodeMarkdownWithListLevel(document, trailing, SavedListLevel(note.formatting));
    }
    if (![content writeToURL:url atomically:YES encoding:note.fileEncoding error:&error]) {
        [self showError:error title:@"Couldn’t save the text file."];
        return;
    }
    note.filePath = url.path;
    note.dirty = NO;
    note.fileModificationDate = FileModificationDate(url);
    [self.tabViews[note.identifier] displayNote:note selected:note == self.visibleNote];
    self.needsSave = YES;
    [self saveSessionShowingError:NO];
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        __attribute__((objc_precise_lifetime)) NPApp *delegate = [[NPApp alloc] init];
        app.delegate = delegate;
        [delegate installMenus];
        [app run];
    }
    return 0;
}
