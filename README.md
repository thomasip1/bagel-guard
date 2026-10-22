# BagelGuard

A macOS menu-bar app that stops the "bagel on an unlocked laptop" prank in Slack.

![BagelGuard overlay](screenshot.jpg)

When someone puts a bagel into a Slack message box on your Mac (the 🥯 emoji, a `:bagel:`-style
shortcode, one of the custom bagel emoji, or the word "bagel"), BagelGuard:

1. clears the message box before it can be sent,
2. takes a webcam photo of whoever is at the keyboard,
3. identifies them against a lineup of known faces,
4. covers every screen with an overlay showing the photo, who they are, what was caught and where,
5. saves the photo and a copy of the overlay to `~/Pictures/BagelGuard`, and
6. locks the screen when the overlay is clicked.

It also intercepts the Return key and clicks on the Send button while a bagel is in the message box,
so even if detection is a frame behind, the message never goes out.

Reactions are not caught. The menu (🥯 in the menu bar) lets you disarm it, choose what happens on
a catch (overlay then lock, overlay only, lock right away, or only log it), turn the photo off,
preview the overlay, and start it at login. Every change in the menu, including Quit, needs Touch
ID, and anything that weakens the guard is only a pause: disarming, a milder catch action, turning
the photo off, turning off start at login, or quitting all undo themselves after 3 minutes.

## Jev check

The rules above only catch bagels that say they are bagels. A bagel emoji uploaded under another
name gets past them, so BagelGuard also uses [Jev](https://docs.typesafe.ai) (`jev-1.14.0`, TypeSafe's
System One model) in two ways.

**Emoji book.** Every emoji BagelGuard sees in Slack, in the message box or anywhere on screen, is
cut out of a screenshot and Jev judges once whether it's a bagel, next to a reference 🥯. The
answer is remembered, and an emoji judged a bagel (50% or more) is from then on caught by name the
moment it lands in the message box, like `:bagel:`. Its name typed as a word ("legab haha") counts
too.

**Sent messages.** When the message box goes from holding something to empty, a message went out.
BagelGuard checks it after the fact: its emoji against the emoji book, the local rules again, and
Jev on the text, asking whether it looks like someone else typing on your unlocked laptop rather
than a message a software engineer would send (50% or more). A flagged message is deleted through
Slack's own UI (Up focuses your last message, Delete, confirm), then handled like any other catch.

Both work from Slack's accessibility tree, not keystrokes, so they keep working when macOS leaves
Secure Keyboard Entry stuck on after a screen unlock (which blinds the Return backstop).

The disguises Jev's text question is told to expect are also caught by the local rules before a send:
lookalike letters ("bаgel" with a Cyrillic а), spacing ("b a g e l"), leetspeak ("b4g3l") and a few
other languages (ベーグル, 贝果) all normalise to the bagel word. Jev is **fail-closed**: if it is set
up but can't be reached (after a few retries), a message it couldn't screen is treated as not having
passed and is pulled, so turn BagelGuard off (Touch ID) to chat while offline. Long messages are
trimmed before being sent to Jev so a wall of text can't push the request over its limit.

Needs `JEV_API_KEY`, either in the environment or set in your fish config (`set -gx JEV_API_KEY …`),
and **Screen Recording** permission to see emoji pictures. Sent messages' text and emoji names, and
pictures of emoji, are sent to TypeSafe's API.

## Face check

Every send also has to pass a face check: the message only goes out if your face was at the camera in
the second or so around it. The camera runs while Slack is in front (and for a grace period after),
each frame is matched against your enrolled face, and a send with a stranger's face — or no face —
is pulled and shown on the overlay. **Enrol your face** from the menu ("Enrol my face for sending");
it stores your face embedding in the signed store, so swapping the `Thomas Ip.jpg` file in the lineup
folder can't make someone else the owner. Without enrolment it falls back to that file.

## Hardening

- **Settings are signed.** Armed, the catch action, the re-engage clocks and the emoji book live in a
  blob signed with a key in the Keychain, not plain `defaults`, so `defaults write …` can't disarm
  BagelGuard behind the Touch ID the menu requires. A tampered or deleted store fails closed to armed.
- **Re-engage dates are capped** at three minutes from now on read, so a pre-planted far-future date
  can't hold a safeguard off.
- **Relaunch if force-quit.** A menu toggle (Touch ID) installs a LaunchAgent that brings BagelGuard
  back if it's killed with `killall` or Activity Monitor, but not when you quit it cleanly. (A frozen
  process, `kill -STOP`, isn't covered.)
- **Editing a sent message** to insert a bagel is caught too, and saving an edit is face-gated.
- **Deleting a flagged message** walks up recent messages to find it, so sending something innocent
  right after the prank doesn't save the prank.

Try a message without Slack:

```bash
~/Applications/BagelGuard.app/Contents/MacOS/BagelGuard --jev-test "I'm buying bagels for everyone"
```

## Face lineup

Drop photos into `~/Pictures/BagelGuard/Lineup/` named `Firstname Lastname.jpg`. At launch,
BagelGuard indexes every face using the SFace model (112x112 aligned embeddings, cosine similarity
threshold 0.363). When a mugshot is caught, the face is matched against the lineup and the overlay
shows who it is.

If a `-linkedin` variant exists (e.g. `Jane Doe-linkedin.jpg` alongside `Jane Doe.jpg`),
the LinkedIn version is preferred for indexing.

## Install

Requires macOS 14 or later and the Xcode command line tools (`xcode-select --install`).

```bash
./build.sh
open ~/Applications/BagelGuard.app
```

`build.sh` compiles the app and installs it to `~/Applications/BagelGuard.app`.

On first launch, grant BagelGuard **Accessibility** access when macOS asks (System Settings →
Privacy & Security → Accessibility), allow **Camera** access for the photo, and allow **Screen
Recording** for the Jev check.

The build is signed ad hoc, so macOS asks for Accessibility again after every rebuild. To keep the
grant across rebuilds, create a self-signed code-signing certificate named `BagelGuard Local
Signing` in your login keychain; `build.sh` uses it when it exists.

If the 🥯 icon is hidden behind the notch, open the app again (double-click it in
`~/Applications`) to get its menu at the pointer.
