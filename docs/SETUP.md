# Kitchen — setup on your Mac

## Opening the project

```
git clone https://github.com/bkeeny8-wq/Kitchen.git
cd Kitchen
open Kitchen.xcodeproj
```

Build target is **iOS 17.0**, Swift 5, universal (iPhone + iPad). Signing is
pre-set to `DEVELOPMENT_TEAM = HHSFT2GD2H` and bundle id
`com.brandonkeeny.Kitchen`, matching your CFAL3 setup, so it should sign
without you touching the Signing & Capabilities tab.

## Getting it onto family phones

This app is never going to the App Store. Two routes:

- **Direct install** — plug the phone in, pick it as the run destination, hit
  Run. Free Apple IDs expire the provisioning profile after 7 days; a paid
  developer account (which team `HHSFT2GD2H` implies you have) gives a year.
- **TestFlight internal testing** — archive, upload, add family as internal
  testers. Still unpublished and not App Review'd for internal testers, and it
  avoids re-installing by cable every time a profile lapses. This is the better
  route for other people's phones.

## Claude Code permissions for this repo

The auto-mode classifier in the cloud session would not let me write
`.claude/settings.json` (it counts as modifying Claude's own config). Create it
yourself to stop Claude Code prompting on every build command — same contents as
your CFAL3 repo plus the test-result reader:

```json
{
  "permissions": {
    "allow": [
      "mcp__Claude_Code_iOS_Simulator__control",
      "Bash(xcodebuild *)",
      "Bash(xcrun simctl *)",
      "Bash(xcrun xcresulttool *)",
      "Bash(sips *)",
      "Bash(plutil *)"
    ]
  }
}
```

## A warning about this codebase's provenance

Every Swift file here was written in a Linux cloud container with **no Apple
toolchain** — nothing was ever compiled or run before it reached you. It went
through multiple adversarial review passes for compile correctness, SwiftData
legality and iOS 17 API availability, but review is not a compiler. Expect to
fix some build errors on the first open, and tell Claude what they are rather
than fixing them silently — the same mistake is probably in several files.
