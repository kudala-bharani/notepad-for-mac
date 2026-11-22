# Notepad for Mac

I missed Windows Notepad after switching to a Mac, so I built the notepad I wanted.

Write anything, open a few tabs, close the app, and come back to your drafts later. Notepad for Mac is a native macOS app with automatic session restore, themes, and Markdown that formats as you type.

This started as something I built for myself. I’m sharing it for anyone who wants the same experience, and anyone who wants to help improve it. Bug reports, feature ideas, and pull requests are welcome.

## What it does

- Keeps open tabs and drafts when you quit and reopen the app.
- Formats headings, bold, italics, quotes, strikethrough, links, and code as you type.
- Supports checkboxes that strike through completed tasks and move them below unfinished tasks in the same list.
- Creates nested lists with Tab and Shift-Tab.
- Offers System, Light, Dark, and Paper themes, with saved font and text-size choices.
- Opens and saves plain-text and Markdown files, with Find and a separate undo history for each open tab.

The app is written in Objective-C using AppKit and Foundation. Notes are stored on your Mac, and the source builds with Apple’s tools.

## Install

Notepad runs on macOS 13 Ventura or later. The disk image includes one app for both Apple silicon and Intel Macs.

### Install from a disk image

1. For a published version, look for a `.dmg` under **Assets** on the [Releases page](https://github.com/kudala-bharani/notepad-for-mac/releases). To try a preview, sign in to GitHub, open a successful [macOS build and tests](https://github.com/kudala-bharani/notepad-for-mac/actions/workflows/macos.yml) run, and download the preview DMG under **Artifacts**.
2. Double-click the `.dmg` in Finder. Drag **Notepad** onto the **Applications** shortcut in the window.
3. Eject the disk image in Finder, then open **Notepad** from Applications. You can delete the downloaded disk image after that.

**Updating a previous installation?** Quit Notepad with **⌘Q** first. Drag the app from the disk image into the folder that contains your existing copy and choose **Replace**. The source installer uses your home Applications folder. To open it in Finder, press **⇧⌘G**, enter `~/Applications`, and press Return. Your tabs and drafts are stored separately and reopen with the updated app.

### If Apple can’t verify Notepad on first launch

The initial 1.5 DMG hasn’t been notarized by Apple, so macOS may say it can’t verify the developer or check Notepad for malicious software. If you downloaded the DMG from this GitHub repository and trust the build, you can approve this copy of Notepad.

1. Open **Notepad** from your Applications folder. If the verification alert appears, dismiss it with **Done** or **Cancel**.
2. Open **Apple menu → System Settings → Privacy & Security** and scroll to **Security**. Find the entry for **Notepad** and choose **Open Anyway**. On some macOS versions, click **Open** first.
3. Confirm that you want to open Notepad and authenticate if prompted. After that, you can launch this copy normally.

If the button is missing, try opening Notepad once more, then return to Settings. The button is available for about an hour after a blocked attempt. If macOS says the app **will damage your computer** or **is damaged**, discard that copy. [Apple’s guide to opening downloaded apps](https://support.apple.com/en-us/102445)

### Build and install from source

Download the repository with **Code → Download ZIP** and extract it, or clone it. Open the repository folder and double-click **Install Notepad.command**. The installer builds the app for your Mac using Apple’s Command Line Tools or Xcode, installs it at `~/Applications/Notepad.app`, and opens it. If it asks for Command Line Tools, run `xcode-select --install` in Terminal, finish Apple’s installation, and run the installer again. See [INSTALL.txt](INSTALL.txt) for the full instructions.

## Writing and formatting

Formatting works in the editor as you type. The **Format** menu also lets you apply paragraph and inline styles to existing text.

| Type or press | Result |
| --- | --- |
| `#` then Space at the start of a line | Heading 1. Use up to six hashes for other heading levels. |
| A new heading marker at the start of an existing heading | Changes that line’s heading level. |
| Return at the end of a heading | Starts regular text on the next line. |
| Return at the start of a heading with text | Inserts a regular line above it and preserves the heading below. |
| `**bold**` | Bold text. You can also type two stars, put the caret between them, and start writing. |
| `_italic_` or `__italic__` | Italic text while typing. You can also write between two prewritten underscores. |
| `~~text~~` | Strikethrough. |
| `>` then Space at the start of a line | Quote. |
| `-` then Space, or `1.` then Space | Bulleted or numbered list. |
| Tab at the start of a list item | Indents the item into a sublist. Shift-Tab moves it back a level. |
| `[]` or `[ ]` at the start of a line | Checkbox. Click it or use **Format → Toggle Checkbox** to change its state. |
| `[text](https://example.com)` | Link. |
| A word between single backticks | Inline code. |
| Three backticks on a line, then Return | Code block. Type three backticks on their own line and press Return to finish. |

Return continues a list at its current level. On an empty nested item, Return moves back one level. On an empty top-level item, Return ends the list. A completed checkbox moves within its uninterrupted task list, keeping any nested children with it.

When writing between prewritten emphasis markers, press Right Arrow or Escape to finish that typing style. Live typing accepts `__italic__` as a convenience. Opening a Markdown file follows the usual convention that double underscores mean bold.

**Edit → Paste as Markdown** formats supported Markdown from your clipboard. Ordinary paste inserts the clipboard text literally. Saving as `.md` preserves supported formatting as Markdown. Saving as `.txt` writes the visible plain text.

## Shortcuts and appearance

| Shortcut | Action |
| --- | --- |
| ⌘T | New tab |
| ⌘W | Close tab |
| ⇧⌘T | Reopen a recently closed tab |
| ⌘O | Open a file |
| ⌘S | Save the current tab as a file |
| ⇧⌘S | Save As |
| ⌘F | Find in the current tab |
| ⌘Z / ⇧⌘Z | Undo / redo |
| ⌥⇧⌘V | Paste as Markdown |
| ⌘+ or ⌘= / ⌘− / ⌘0 | Increase / decrease / reset text size |

Choose a theme under **View → Theme**, a font under **View → Font**, and text size under **View → Text Size**. Comic Sans MS is used when it is installed. System and Monospaced are also available. Code stays monospaced.

## Drafts and files

Open tabs and their formatting are saved in `~/Library/Application Support/com.kudala.notepad/session.json`. This draft data is separate from the installed app, so updating the app preserves it. Closing a tab is a separate action from quitting the app; **⇧⌘T** reopens recently closed tabs.

Use **⌘S** when you want a file outside the app. Edits to an opened file remain in the draft session until you explicitly save the file. Theme, font, and text-size preferences use macOS user defaults.

You can remove the downloaded ZIP and source folder after installation. Move any notes you saved inside that folder before deleting it.

## Build and contribute

To build without installing, run this from the repository folder on your Mac.

```bash
./scripts/build.sh
```

Run the native checks with this command.

```bash
./scripts/test.sh
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for setup, project structure, and what to include in a bug report or pull request. Small fixes, editing improvements, and accessibility work are welcome. For larger features, open an issue first so we can discuss how they fit the simple scratchpad workflow.

This is an early community release. Native editing behavior and draft recovery are the most important areas to test across macOS versions.

## License

[MIT](LICENSE). Created by Kudala Bharani Kumar Reddy.
