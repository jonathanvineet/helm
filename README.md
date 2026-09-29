# helm

A macOS screensaver that shows your Apple Notes and Reminders on frosted glass
over a Ken Burns photo slideshow, with a menu bar app that keeps it in sync.

## Install

```sh
brew install --cask jonathanvineet/tap/helm
```

(Plain `brew install helm` installs the unrelated Kubernetes tool.)

Then:

1. **System Settings → Screen Saver:** pick Helm.
2. **Open Helm.** It lives in the menu bar and starts at login.
3. **Grant access** to Reminders, and Full Disk Access so Helm can read Apple Notes.

Helm isn't notarized yet, so the cask clears macOS's download quarantine flag on install.

## Build from source

```sh
./build.sh --install
```

## Release

```sh
./release.sh 0.3.0
```

This writes `dist/Helm-0.3.0.zip` and `dist/helm.rb`. Upload the zip to a GitHub
release tagged `v0.3.0`, then copy `helm.rb` to `Casks/helm.rb` in
[jonathanvineet/homebrew-tap](https://github.com/jonathanvineet/homebrew-tap).
