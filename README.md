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
| Annotations | Select text and press ⌥⌘A (or right-click ▸ Add Annotation) to attach a note without changing your text. With nothing selected, the current sentence is annotated. Notes appear as cards in the sidebar's **Notes** tab (⌃⌘A). Click a card to jump to its text. Annotated text is highlighted and stays attached while you edit |
| Writing coach | A Claude-powered coach on the right (⌃⌘K). See below |
| Typewriter scrolling | ⌥⌘T keeps the current line centered |
| Fonts | View ▸ Font: Serif, Sans, Mono. ⌘= / ⌘- change the size |
| Saving | Standard macOS document behaviour: Save, Duplicate, Rename, Move To, Revert / browse versions, autosave, Open Recent |

### Writing coach

The coach panel on the right helps you keep writing:

1. **Plan.** Click **Plan my writing** (⌃⌘P). The coach asks a few questions, one at a
   time: what you're writing, how long it should be, your deadline, and when you can write.
   It then proposes a plan as a card, for example "about 300 words every weekday until
   15 March", with milestones. Click **Approve**, or **Request changes** and say what
   should change.
2. **Reminders.** Every time you open the document, the coach recaps today's goal and
   whether you're on track or behind. The top of the panel shows today's progress and
   overall progress.
3. **Nudges.** LaserFocus watches your typing rhythm on your Mac and only asks Claude for a
   message when you seem stuck:
   - you pause mid-sentence for about 90 seconds
   - you delete and retype a lot within a minute and a half
   - you go idle for 4 minutes

   When you're stuck on a word, the coach can suggest alternatives. Nudges are at most one
   every 8 minutes and can be turned off in the Coach menu. The coach also celebrates when
   you reach today's goal.
4. **Chat.** Message the coach at any time (⌃⌘M). Asking it to change the plan works too.

**Setup:** the coach can reach Claude in two ways (Coach menu):

- **Use Claude Subscription (via Claude Code)** is the default and costs nothing extra.
  LaserFocus runs Claude Code headlessly on your Mac, using your Claude plan's usage
  limits. It uses an installed `claude` CLI if there is one, otherwise the copy bundled
  with the Claude desktop app. Sign it in once: when the coach asks, click
  **Copy Sign-In Command**, paste it into Terminal, press Return and sign in in your browser.
  If you have the CLI installed, `claude auth login --claudeai` does the same. Replies use
  your Claude Code default model.
- **Use Anthropic API Key** uses the Claude API, billed separately per use. Paste a key
  from [console.anthropic.com](https://console.anthropic.com) in Coach ▸ Anthropic API Key….
  The key is stored in the macOS Keychain and only sent to Anthropic. This mode uses
  `claude-opus-5-5`.

Problems are logged to `~/Library/Logs/LaserFocus/coach.log`, without keys or text.

**Privacy:** the coach sends Claude your plan, progress numbers and the conversation.
With **Coach ▸ Share Current Paragraph With Coach** on (the default), it also sends the
paragraph you're working on, and the opening of the document while planning. Turn it off
to share numbers only. Without an API key, reminders and nudges fall back to built-in
messages.

The plan, daily progress and conversation are saved in the document, in the same kind of
hidden block as annotations (`<!-- laserfocus:coach … -->`).

### How annotations are saved

Annotations live in the same `.md` file, in a hidden HTML comment block at the very end:

```
<!-- laserfocus:annotations
[
{"anchor":"lazy dog","id":"…","length":8,"location":412,"note":"Replace with something original."}
]
-->
```

LaserFocus hides this block in the editor, and Markdown viewers don't render HTML comments,
so your text stays clean. The notes also travel with the file when it is copied, synced or renamed.
If the file is edited in another app, each note re-attaches to the nearest copy of its
annotated text.

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
  DocumentViewController.swift split view: sidebar + editor, Add Annotation
  SidebarViewController.swift Outline / Notes tabs
  OutlineViewController.swift heading hierarchy
  AnnotationsViewController.swift annotation cards
  AnnotationStore.swift      annotation model, anchoring and file storage
  HiddenBlock.swift          hidden data blocks at the end of the .md file, word/paragraph counts
  CoachViewController.swift  coach panel: progress, chat, plan cards
  WritingCoach.swift         coach logic: planning, plan status, stuck detection, prompts
  CoachStore.swift           plan / progress / chat model saved in the document
  ClaudeClient.swift         Claude Messages API client, Keychain key storage, coach log
  ClaudeCodeClient.swift     runs the coach through Claude Code on your Claude subscription
  EditorViewController.swift text column, focus dimming, typewriter mode, status line
  FocusTextView.swift        inline autocomplete
  MarkdownStyler.swift       Markdown and grammar highlighting
  GrammarTagger.swift        subject/predicate/object estimation
  Settings.swift             preferences and light/dark palettes
Resources/Info.plist         bundle info and document types
```
