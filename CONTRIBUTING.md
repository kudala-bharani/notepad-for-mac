# Contributing to Notepad for Mac

Thanks for helping improve the app. Bug reports, small fixes, documentation, and feature ideas are welcome. The aim is to keep quick notes easy to write and easy to return to.

## Set up

You need a Mac running macOS 13 Ventura or later, Git, and Apple’s Command Line Tools or a compatible Xcode installation. Install the Command Line Tools with `xcode-select --install` if needed.

Clone the repository, create a branch, and build from the repository folder.

```bash
git clone https://github.com/kudala-bharani/notepad-for-mac.git
cd notepad-for-mac
git switch -c fix/short-description
./scripts/build.sh
```

The app builds with Apple’s AppKit and Foundation frameworks. The build script creates a local app bundle, and **Install Notepad.command** installs a copy in `~/Applications`.

## Report a bug

Use the bug-report issue template and include these details.

- Your macOS version, Mac architecture, and Notepad version.
- The steps that reproduce the problem, including the exact keystrokes for editing bugs.
- What you expected and what happened.
- A small sample of text that reproduces it, and a screenshot or recording if that helps.

Use sample text when reporting a problem with drafts. The session file contains your note text, so include only the relevant example you want to share.

For a feature idea, explain what you are trying to do and how the proposed change would help. A small example is often enough. Discuss larger changes in an issue before starting a pull request.

## Project structure

| Path | Purpose |
| --- | --- |
| `Sources/main.m` | App lifecycle, window, tabs, menus, file operations, and preferences |
| `Sources/LiveEditor.*` | Native editor, typing shortcuts, formatting, list layout, and undo integration |
| `Sources/LiveFormatting.*` | Semantic formatting attributes and draft snapshots |
| `Sources/LiveMarkdown.*` | Supported Markdown import, export, and inline matching |
| `Sources/TaskListEditing.*` | Checkbox list toggling, sorting, and selection mapping |
| `Sources/EditorTypography.*` | Font choices, style variants, and text-size limits |
| `Sources/SessionStore.*` | Tab models and session persistence |
| `Resources/` | App metadata and icon |
| `scripts/` | Local build and test commands |

## Test a change

Run the native checks from the repository folder.

```bash
./scripts/test.sh
```

For editor changes, also try the behavior in the app. Check typing, caret placement, selection, undo and redo, tab switching, and quitting and reopening. If a change affects Markdown, check both typing it and opening or saving an `.md` file.

Drafts live at `~/Library/Application Support/com.kudala.notepad/session.json`. Keep a copy of any important drafts before testing changes to session storage. Check older session data as well as newly created notes when changing the saved format.

Use a focused regression test when fixing a reproducible bug. Keep source changes readable and limit unrelated formatting changes so a reviewer can follow the fix.

## Send a pull request

Describe the behavior your change fixes or adds, explain how you tested it, and link the related issue when there is one. For visible changes, include a short screenshot or recording with sample text. Mention any checks you could not run.

Contributions are made under the project’s [MIT license](LICENSE).
