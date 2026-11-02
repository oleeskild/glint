# Glint

<img src="Resources/AppIcon.png" width="128" alt="Glint icon">

A menu bar screenshot and screen recording app for macOS, inspired by CleanShot X.
Written from scratch in Swift (AppKit, ScreenCaptureKit, Vision, AVFoundation) with no dependencies.
It is not affiliated with CleanShot.

## Features

- **Area, window, fullscreen and previous-area capture.** The screen freezes while you select, and you get a crosshair, a pixel magnifier and a size label.
- **Quick Access thumbnails** after each capture. Use them to copy, save, annotate, pin or OCR the capture, or drag it out into another app as a file.
  - Two-finger swipe left closes a thumbnail.
  - Swipe down tucks the whole stack into a small tab until you bring it back.
- **Annotation editor** with arrows, lines, shapes, pen, highlighter, text, numbered counters, pixelate and crop, plus undo/redo.
- **Screen recording** to H.264 `.mp4`.
- **Text capture (OCR)**, copied straight to the clipboard.
- **Pin to screen**: a floating, always-on-top image you can zoom.
- **Custom global shortcuts**, set in Settings.
- **`glint://` URL scheme** for scripts and launchers.

## Install

Requires macOS 15.2 or later.

Download `Glint.zip` from [Releases](https://github.com/oleeskild/glint/releases), unzip it and move Glint to Applications. Or build it yourself:

```sh
./scripts/bundle.sh        # builds a universal build/Glint.app
open build/Glint.app
```

Then grant Screen Recording permission under System Settings → Privacy & Security → Screen & System Audio Recording, and relaunch Glint.

The script signs the app with your Apple Development identity if you have one, and falls back to ad-hoc signing otherwise.
Release builds aren't notarized. On first launch, use **Open Anyway** in Privacy & Security, or run:

```sh
xattr -dr com.apple.quarantine /Applications/Glint.app
```

## Default shortcuts

| | |
|---|---|
| ⌥⇧1 | Capture area (press Space for window mode) |
| ⌥⇧2 | Capture previous area |
| ⌥⇧3 | Capture fullscreen |
| ⌥⇧4 | Capture window |
| ⌥⇧5 | Start/stop recording |
| ⌥⇧6 | Capture text (OCR) |
| ⌥⇧7 | Pin area to screen |

### Editor keys

| Key | Action |
|---|---|
| V | Select / move |
| A | Arrow |
| L | Line |
| R | Rectangle |
| O | Ellipse |
| P | Pen |
| H | Highlighter |
| T | Text |
| N | Numbered counter |
| X | Pixelate |
| C | Crop |
| ⌘Z / ⇧⌘Z | Undo / redo |
| ⌘C | Copy |
| ⌘S | Save |
| Return | Done |

## URL scheme

```sh
open "glint://capture-area"    # capture-fullscreen, capture-window, capture-previous-area,
                               # capture-text, record-screen, pin-area, annotate-clipboard,
                               # close-overlays, open-settings
open "glint://open-annotate?filepath=~/Desktop/shot.png"
open "glint://pin?filepath=~/Desktop/shot.png"
```

## Not yet

Scrolling capture, self-timer, audio or webcam in recordings, GIF export, capture history.

## License

[MIT](LICENSE)
