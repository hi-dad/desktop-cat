# Desktop Cat

<img src="images/icon.png" alt="Desktop Cat app icon" width="128">

**A free, offline pixel-art cat that lives on your Mac desktop.**

<img src="images/desktop-cat-showcase.gif" alt="Desktop Cat: a pixel-art cat peeks over a window and hops on top, rides along as the window moves and is shaken off, chases the cursor, rolls over when tickled, is picked up by the scruff, bats a yarn ball, sits watching a movie, then lies down to sleep" width="720">

### [⬇️ Download Desktop Cat](https://github.com/hi-dad/desktop-cat/releases/latest/download/DesktopCat.dmg)
Free · macOS 14 or newer · always the latest version

## Install

1. Open **DesktopCat.dmg** and drag Desktop Cat into **Applications**.
2. Open it, and click **Open** when macOS asks if you're sure. (It's signed and checked by Apple.)

Everything is in the **cat icon** in your menu bar.

## What the cat does

- Wanders along the bottom of your screen, mostly keeping to the sides: walks, grooms, stretches, naps, looks up at what you're doing and paws at the screen.
- Sneaks behind your windows and hops up on top, rides along when you move them, and tumbles off if you shake one.
- Play-bows and pounces at your pointer, sits and watches videos with you, and runs to catch up when you swipe to another desktop.
- Pick it up and it dangles by the scruff. Wiggle the cursor to tickle it, or move slowly to pet it.
- Feed it, fill its water bowl, or toss it a ball of yarn. Nothing bad ever happens if you forget.
- **Talent Show** in the menu: half a minute of its best tricks, for showing it off.
- Two cats to choose from, sizes 1×–6×, Calm / Normal / Lively moods, and extras you can switch off.

Clicks pass straight through everything but the cat. It sleeps during full-screen apps and Low Power Mode. No accounts and no special permissions; the only time it goes online is a quick daily check for updates.

**Updates:** it offers new versions itself (or cat icon → **Check for Updates…**). **Remove:** cat icon → **Quit Desktop Cat**, then drag it to the Trash.

<details><summary>Build it yourself</summary>

Needs Xcode or the Command Line Tools.

```bash
./build.sh run    # builds DesktopCat.app and starts it
./build.sh dist   # makes dist/DesktopCat.dmg
swift test        # about 105 tests
```

Code is in `Sources/DesktopCat/`, behaviour and art rules in `specs/`, sprite tools in `tools/sprites/`.

</details>

MIT License
