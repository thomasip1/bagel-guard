# BagelGuard

A macOS menu-bar app that stops the "bagel on an unlocked laptop" prank in Slack.

When someone puts a bagel into a Slack message box on your Mac (the 🥯 emoji, a `:bagel:`-style
shortcode, one of the custom bagel emoji, or the word "bagel"), BagelGuard:

1. clears the message box before it can be sent,
2. takes a webcam photo of whoever is at the keyboard,
3. covers every screen with an overlay showing the photo, what was caught and where,
4. saves the photo and a copy of the overlay to `~/Pictures/BagelGuard`, and
5. locks the screen when the overlay is clicked.

Reactions are not caught. The menu (🥯 in the menu bar) lets you disarm it, choose what happens on
a catch (overlay then lock, overlay only, lock right away, or only log it), turn the photo off,
preview the overlay, and start it at login.

## Install

Requires macOS 14 or later and the Xcode command line tools (`xcode-select --install`).

```bash
./build.sh
open ~/Applications/BagelGuard.app
```

`build.sh` compiles the app and installs it to `~/Applications/BagelGuard.app`.

On first launch, grant BagelGuard **Accessibility** access when macOS asks (System Settings →
Privacy & Security → Accessibility), and allow **Camera** access for the photo.

The build is signed ad hoc, so macOS asks for Accessibility again after every rebuild. To keep the
grant across rebuilds, create a self-signed code-signing certificate named `BagelGuard Local
Signing` in your login keychain; `build.sh` uses it when it exists.

If the 🥯 icon is hidden behind the notch, open the app again (double-click it in
`~/Applications`) to get its menu at the pointer.
