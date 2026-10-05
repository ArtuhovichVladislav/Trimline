# Releasing

Trimline is distributed without an Apple Developer account: the app is signed ad hoc and not notarized. The DMG,
the Sparkle update feed and the FFmpeg sources are attached to GitHub Releases of
[ArtuhovichVladislav/Trimline](https://github.com/ArtuhovichVladislav/Trimline); the website only links to them.
The only release secret is the Sparkle EdDSA private key.

## Updates through Sparkle

Trimline updates itself through [Sparkle 2](https://sparkle-project.org) (a Swift package; the 2.x version is
pinned in `Trimline.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`). Every update is signed
with EdDSA (ed25519): the app holds the public key, and the update archive is signed with the private key, which
only the release owner has.

### Configuration

The feed URL and the public key are set in one place, `Config/Updates.xcconfig`:

| Build setting | Info.plist key | Value |
| --- | --- | --- |
| `TRIMLINE_UPDATE_FEED_URL` | `SUFeedURL` | `https://github.com/ArtuhovichVladislav/Trimline/releases/latest/download/appcast.xml` |
| `TRIMLINE_SPARKLE_PUBLIC_KEY` | `SUPublicEDKey` | `Q+NKbBZiLUAcm0uVv/NfuUmXQfVanLRJReZHZ16R7Rw=` |

In an xcconfig file `//` starts a comment, so the URL is written as `https:/$()/…`.

The other Sparkle keys are in `Trimline/Resources/Info.plist`:

- `SUEnableAutomaticChecks = YES`: checking is on from the start, without Sparkle asking on the second launch; it
  can be turned off in Settings ▸ Updates.
- `SUEnableSystemProfiling = NO`: Sparkle sends no system information. The feed request carries only the usual
  `User-Agent` with the app version.

Debug builds, and any build with a placeholder instead of a key, don't start Sparkle (`UpdaterService`): Check for
Updates… is disabled, the toggles in Settings are off and no network requests are made. Otherwise development and
fork builds would check the release feed, since the real public key is committed.

### Keys: create once

Sparkle's tools are in the package after `xcodebuild -resolvePackageDependencies` (or any build):

```sh
SPARKLE_BIN=build/SourcePackages/artifacts/sparkle/Sparkle/bin
```

Or download `Sparkle-2.x.y.tar.xz` from the [Sparkle releases page](https://github.com/sparkle-project/Sparkle/releases);
it has the same `bin/` folder.

1. **Create a key pair** (once, on the release owner's Mac):
   ```sh
   "$SPARKLE_BIN/generate_keys"
   ```
   The private key is stored in the login keychain as the password of the "Private key for signing Sparkle
   updates" item (account `ed25519`, the default for `sign_update` and `generate_appcast`); it is never written to
   a file. The command prints the public key (base64, 44 characters).
2. **Put the public key** in `Config/Updates.xcconfig` in place of the placeholder and commit it. It isn't secret.
   To print it again: `generate_keys -p`.
3. **Back up the private key** outside the repository; without it no update can be shipped to installed copies:
   ```sh
   "$SPARKLE_BIN/generate_keys" -x ~/trimline-sparkle-private-key.txt
   ```
   The file holds the key itself in base64. Put it in a password manager and delete it from disk. To restore it on
   another Mac: `generate_keys -f FILE`.

Never create a new key if the old one exists: apps with the old public key reject updates signed with a new one.

### CI

The private key is stored in the repository secret `SPARKLE_PRIVATE_KEY`, the contents of the file from
`generate_keys -x`. Sparkle's tools read it from standard input, so no key file is needed on disk:

```sh
echo "$SPARKLE_PRIVATE_KEY" | "$SPARKLE_BIN/sign_update" --ed-key-file - Trimline-1.0.dmg
```

`scripts/release.sh` takes the key from `SPARKLE_PRIVATE_KEY` or from the file in `SPARKLE_KEY_FILE`, and from
the keychain otherwise. It stops the release if `SUPublicEDKey` is still a placeholder, if there is no key, or if
the key doesn't match `SUPublicEDKey`.

### Update signature and feed

- **`sign_update FILE`** signs one archive (DMG or ZIP) and prints the `sparkle:edSignature="…" length="…"`
  attributes for the feed's `<enclosure>`. `--verify FILE SIGNATURE` checks a signature.
- **`generate_appcast DIR`** signs every archive in the folder itself and writes or extends `DIR/appcast.xml`. It
  takes the version from `CFBundleVersion`/`CFBundleShortVersionString` and the minimum system from
  `LSMinimumSystemVersion`. An `.html` or `.md` file with the same name as the archive becomes the release notes.
  Flags used: `--ed-key-file -` (key from standard input; without it the keychain is used) and
  `--download-url-prefix https://github.com/ArtuhovichVladislav/Trimline/releases/download/v<version>/`.

Sparkle compares `CFBundleVersion` (`CURRENT_PROJECT_VERSION`), so the build number must grow with every release.
`appcast.xml` is served from the `SUFeedURL` address, and the archives from `--download-url-prefix`.

### Sparkle and ad hoc signing

Checked against the Sparkle 2.10.0 sources:

- **EdDSA is required.** Sparkle accepts an update if the archive's EdDSA signature is valid or if the new app's
  Apple code signature satisfies the old one's designated requirement (`SUUpdateValidator.m`). For an ad hoc
  signed app that requirement is its own cdhash (`codesign -d -r-` shows `designated => cdhash H"…"`), which a new
  version never satisfies. So a Trimline update goes through only with a valid EdDSA signature made with the
  private key whose public key is in the **already installed** version.
- **The key can't be changed or lost.** Key rotation in Sparkle relies on Apple code signing (the new version is
  vouched for by the Developer ID, and the new key by the new version). Without a Developer ID there is no such
  chain: installed copies reject an update signed with another key, and users have to download the DMG by hand.
- **An unsigned build is not an option.** The app must be signed at least ad hoc: if the old version is signed and
  the new one isn't, Sparkle rejects the update. The EdDSA key can't be removed from a new version either.
- **Quarantine.** Before installing, Sparkle removes `com.apple.quarantine` from the whole new bundle
  (`SUPlainInstaller.m`, `SUFileManager releaseItemFromQuarantineAtRootURL`), then on macOS 14.4+ runs
  `gktool scan`. The updated app launches without a Gatekeeper prompt: approval in System Settings is needed only
  for the first install from the DMG.
- **Install location.** If the app runs from a disk image, a read-only volume or the Downloads folder without being
  moved (App Translocation), Sparkle refuses to update and asks to move the app to Applications
  (`SPUBasicUpdateDriver.m`, `SUHost.m`).

### Code signing

Ad hoc signing (`CODE_SIGN_IDENTITY = -`) and the hardened runtime are set in the project; `release.sh` passes the
same settings to `xcodebuild archive` and copies the app out of the archive (no export step). Xcode signs the app
and re-signs every framework it embeds (FFmpeg, dav1d, Sparkle). Sparkle's nested `Autoupdate`, `Updater.app` and
XPC services come from the SwiftPM artifact already signed ad hoc with the hardened runtime and are sealed by the
signature of `Sparkle.framework`, so the inside-out order holds without an extra pass. If you ever have to sign by
hand: the XPC services, `Autoupdate`, `Updater.app`, the framework itself, then the app, each with
`codesign --force -s - -o runtime`, never `--deep`.

The app isn't sandboxed, so Sparkle's XPC services aren't used and `SUEnableInstallerLauncherService` and
`SUEnableDownloaderService` aren't needed. All binaries are signed ad hoc. Library validation under the hardened
runtime accepts only libraries with the same Team ID, and an ad hoc signature has none, so without an exception the
app crashes at launch loading `libavutil` ("different Team IDs"). Debug builds don't show this because
`get-task-allow` disables the check. That is why the app has a single entitlement,
`com.apple.security.cs.disable-library-validation` (`Trimline/Resources/Trimline.entitlements`); the rest of the
hardened runtime, including the ban on `DYLD_*` variables, stays. For an ad hoc app the check gave almost nothing
anyway: whoever can write to the bundle can re-sign all of it. With a Developer ID the entitlement can go, since
every library would then share one Team ID.

### Before the first release

1. Create the keys and set the public key (see above), and back up the private key.
2. Add the `SPARKLE_PRIVATE_KEY` secret to the repository.
3. The repository must stay public, and releases must be neither drafts nor pre-releases: `releases/latest` points
   to the latest published regular release, and only a public repository serves files without signing in.
4. Install the previous version in Applications and check updating through Check for Updates….

## Installing (for users)

The app isn't notarized, so Gatekeeper blocks the first launch. The download page has to say so.

1. Open the DMG and drag Trimline to Applications. Run it from Applications, not from the disk image: otherwise
   Sparkle can't update it.
2. Open Trimline. macOS says it can't verify the app; click Done.
3. **macOS 15 and later:** System Settings ▸ Privacy & Security, at the bottom under Security: "Trimline was
   blocked…" ▸ Open Anyway, confirm with your password or Touch ID, then Open Anyway again in the dialog. The button
   stays for about an hour after the launch attempt. Since macOS 15, Control-click ▸ Open no longer works for such
   apps ([Apple](https://developer.apple.com/news/?id=saqachfa)).
4. **macOS 14:** the same in System Settings, or Control-click the app ▸ Open ▸ Open.

This is needed once: updates through Sparkle arrive without quarantine and don't ask again. From Terminal:
`xattr -dr com.apple.quarantine /Applications/Trimline.app`.

## Building a release: `scripts/release.sh`

One script does the whole release, locally or in CI. In order:

1. **Preflight:** Xcode 26 or later, a clean git tree, `Frameworks/*.xcframework` present (otherwise it runs
   `scripts/build-ffmpeg.sh`), `SUPublicEDKey` in `Config/Updates.xcconfig` not a placeholder (unless
   `--skip-sparkle`).
2. **`xcodebuild archive`** (Release, `generic/platform=macOS`, arm64 + x86_64, ad hoc). `CFBundleVersion` is the
   commit count (`git rev-list --count HEAD`) or `BUILD_NUMBER`. The app is copied from the archive to
   `build/release/Trimline.app`.
3. **Every Mach-O in the bundle is checked:** `codesign --verify --deep --strict`; hardened runtime; ad hoc
   signature like the app's; both architectures; only `@rpath`, `@executable_path`, `@loader_path`, `/usr/lib` and
   `/System` in `otool -arch all -L`; no `get-task-allow`.
4. **`scripts/check-size.sh`:** a build over 30 MB stops the release, over 28 MB gives a warning. Each part is
   compared with its budget from the [spec](spec.md#size-budget).
5. **DMG** (`hdiutil`, ULMO, volume "Trimline <version>", the app and a link to `/Applications`), `hdiutil verify`,
   then the image is mounted to verify the app's signature inside. The DMG itself isn't signed: an ad hoc
   signature on an image proves nothing.
6. **`spctl -a -vv`** on the app, for information only; `rejected` is expected.
7. **Sparkle:** `sign_update` and `generate_appcast` → `dist/appcast.xml`. Beforehand the script checks that the
   private key's public key matches `SUPublicEDKey`, and afterwards that the feed has a signature
   (`generate_appcast` silently writes an entry without one if the key in the app is wrong). For an ad hoc app an
   unsigned entry is an update nobody can install.
8. **FFmpeg/dav1d sources** for the LGPL (`scripts/package-ffmpeg-source.sh`) and the DMG's SHA-256.

The output goes to `dist/` (ignored by git): `Trimline-<version>.dmg`, a `Trimline.dmg` copy, `.sha256`,
`.sparkle` (signature attributes), `appcast.xml` and `trimline-ffmpeg-source-<version>.tar.xz`. Intermediate files
and logs are in `build/release/`.

```sh
# Release on the owner's Mac (Sparkle key in the keychain or in SPARKLE_KEY_FILE)
./scripts/release.sh

# Dry run without the Sparkle key: archive → checks → size → DMG
./scripts/release.sh --allow-dirty --skip-sparkle
```

Flags: `--skip-ffmpeg` (don't build FFmpeg; fail if it's missing), `--skip-sparkle` (no EdDSA signature and no
feed; never publish such a DMG), `--skip-source`, `--allow-dirty`, `--expect-version X` (CI passes the version from
the tag).

Environment variables (secrets are read only from the environment and never printed):

| Variable | Meaning |
| --- | --- |
| `SPARKLE_KEY_FILE` / `SPARKLE_PRIVATE_KEY` | Sparkle private key (file or contents); without them, the keychain |
| `RELEASES_REPO` | Repository whose releases host the DMG and the feed, `ArtuhovichVladislav/Trimline` by default (`github.repository` in CI) |
| `DOWNLOAD_URL_PREFIX` | Where the DMG is downloaded from, `https://github.com/<RELEASES_REPO>/releases/download/v<version>/` by default |
| `APPCAST_SEED` | Previous feed (path or URL) to append the new version to; `dist/appcast.xml` by default |
| `RELEASE_NOTES` | HTML release notes embedded in the feed |
| `BUILD_NUMBER`, `RELEASE_WORK`, `DIST_DIR`, `SPARKLE_BIN` | Build number, intermediate folder, output folder, path to Sparkle's tools |

## GitHub Actions

- **`.github/workflows/ci.yml`** runs on every push to `main` and every pull request: `swift-format lint --strict`,
  `swift test` in `TrimlineCore`, a Debug build (warnings are errors), then
  `release.sh --skip-ffmpeg --skip-sparkle --skip-source`: universal archive, all signature and linkage checks,
  size budget, DMG. The DMG and the size report are kept as an artifact for 7 days.
- **`.github/workflows/release.yml`** runs on a `v*` tag (for example `git tag v1.0 && git push origin v1.0`):
  `release.sh --skip-ffmpeg --expect-version <tag without v>` with the key from `SPARKLE_PRIVATE_KEY`, then the
  DMG, `.sha256`, `appcast.xml` and the FFmpeg sources are uploaded to a GitHub release. The previous feed is taken
  from the latest release's assets, so older versions stay in it.
- Shared steps live in `.github/actions/setup`: picking the newest `/Applications/Xcode_26*.app`, caching
  `Frameworks/*.xcframework` and `.build-ffmpeg/{arm64,x86_64}` keyed by `hashFiles('scripts/build-ffmpeg.sh')`,
  and `brew install` of the build tools. FFmpeg is built (≈ 15 min) only on a cache miss.
- **Runner:** `macos-26` (Apple silicon) with Xcode 26.x. If GitHub retires the label or moves Xcode, update
  `runs-on` in both workflows and the `xcode` input of the setup action.

### Repository secrets

Settings ▸ Secrets and variables ▸ Actions:

| Name | Type | Where to get it |
| --- | --- | --- |
| `SPARKLE_PRIVATE_KEY` | secret | Output of `generate_keys -x` (see above) |

No certificates, Team ID or App Store Connect keys are needed.

### After tagging

1. Nothing has to be uploaded by hand: the release already has `Trimline-<version>.dmg`, its copy `Trimline.dmg`
   (the website's Download button points to
   `https://github.com/ArtuhovichVladislav/Trimline/releases/latest/download/Trimline.dmg`), `appcast.xml` (the
   `SUFeedURL` address) and the FFmpeg source bundle (linked from the About window's license section and the
   website). The website lives in [trimlineapp/trimlineapp.github.io](https://github.com/trimlineapp/trimlineapp.github.io)
   and is deployed separately.
2. Check: install the DMG on a clean system or user account and go through Open Anyway (see "Installing"), then
   update the previous version in Applications through Check for Updates… and make sure the updated app launches
   without a Gatekeeper prompt.
