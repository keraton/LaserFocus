# LaserFocus

A distraction-free Markdown writer for the Mac. Only the part you're writing stays bright,
and everything else fades away.

Runs on **macOS 10.13 High Sierra and later**. The app is a universal build for Intel and Apple Silicon.

## Build

```bash
./build.sh
```

This produces `build/LaserFocus.app`. You need Xcode or the Xcode Command Line Tools installed.
The Swift runtime is bundled inside the app so it also runs on macOS versions older than 10.14.4.

## Features

| Feature | How |
|---|---|
| Focus modes | View menu: ⌘0 off, ⌘1 sentence, ⌘2 one paragraph, ⌘3 two paragraphs, ⌘4 three paragraphs |
| Dim or hide | ⇧⌘D switches between dimming unfocused text and hiding it completely |
| Themes | View ▸ Theme: Light, Dark, Match System. ⇧⌘L toggles |
| Markdown | Live styling of headings, bold, italic, code, code blocks, quotes, lists, links, strikethrough. Files are saved as plain `.md` |
| Autocomplete | Suggestions from the macOS spell checker appear faintly after the caret. **Tab** accepts, **Esc** dismisses, **⌥Esc** shows the full list. The language is detected per paragraph, and any language with a macOS dictionary works |
| Grammar colors | ⌥⌘G colors subject, predicate (verbs), object and modifiers |
| Outline sidebar | ⌃⌘S or View ▸ Show Outline shows the heading hierarchy on the left. Click a heading to jump to it. The section you're in is highlighted |
| Typewriter scrolling | ⌥⌘T keeps the current line centered |
| Fonts | View ▸ Font: Serif, Sans, Mono. ⌘= / ⌘- change the size |
| Saving | Standard macOS document behaviour: Save, Duplicate, Rename, Move To, Revert / browse versions, autosave, Open Recent |

### About grammar colors

macOS's built-in language tagger (`NSLinguisticTagger`) identifies parts of speech, not full
sentence structure. LaserFocus estimates roles from those parts of speech:

- Nouns and pronouns before the first verb count as the subject.
- Verbs count as the predicate.
- Nouns and pronouns after the verb count as the object, except inside a prepositional phrase.
- Adjectives and adverbs count as modifiers.

This works well for simple sentences. Complex clauses and imperatives can be colored wrongly.
Supported languages include English, French, German, Italian, Spanish, Portuguese, Russian
and Turkish.

## Layout

```
Sources/
  main.swift                 app entry point
  AppDelegate.swift          menus and preference actions
  Document.swift             NSDocument: load and save .md / .txt
  DocumentViewController.swift split view: outline sidebar + editor
  OutlineViewController.swift heading hierarchy sidebar
  EditorViewController.swift text column, focus dimming, typewriter mode, status line
  FocusTextView.swift        inline autocomplete
  MarkdownStyler.swift       Markdown and grammar highlighting
  GrammarTagger.swift        subject/predicate/object estimation
  Settings.swift             preferences and light/dark palettes
Resources/Info.plist         bundle info and document types
```
