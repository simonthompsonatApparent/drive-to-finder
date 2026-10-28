# Drive to Finder

A Chrome button that jumps from Google Drive in the browser to the same file or folder in Finder, using Google Drive for desktop.

For the team, there's nothing to install: IT pushes it through Iru, and a pinned button simply appears in Chrome.

## Using it

- **Toolbar button** (pinned automatically). In Drive, select a file and click it: Finder opens with that file highlighted. With nothing selected, it opens the folder you're looking at.
- **Inside a Doc, Sheet or Slides file**: click the button to reveal that file in Finder.
- **Right-click any Drive or Docs link** (Gmail, Slack in the browser, Notion…) and choose **Show in Finder**.
- **Shortcut**: Control + Shift + F. People can change it at `chrome://extensions/shortcuts`.

The first time, Google asks the person to allow read-only access to file names and folders. macOS may also ask once whether Chrome can access files in Google Drive. They click Allow both times, and that's it.

## How it works

1. The extension reads the file ID from the page (the URL, or the selected item in Drive).
2. It asks the Drive API for the folder chain above that item (names only, read-only scope `drive.metadata.readonly`).
3. It passes those folder names to a small helper on the Mac. The helper finds `~/Library/CloudStorage/GoogleDrive-<email>/` and runs `open`.
4. If the exact item isn't on the Mac yet (for example, it's still syncing), the helper opens the closest folder it can find instead.

The helper is JavaScript for Automation, so it uses only what's built into macOS: no Python and no extra runtimes.

## One-time setup (Simo)

**1. Create the Google sign-in client** (about 5 minutes, in an Apparent-owned Google Cloud project)

1. In **APIs & Services**, enable the **Google Drive API**.
2. In **Google Auth Platform**, set the audience to **Internal**, the app name to "Drive to Finder", and add the scope `.../auth/drive.metadata.readonly`.
3. Under **Clients**, choose **Create client**. Set the type to **Chrome Extension** and the Item ID to `pikhmpompojbkhbckmgolnbmnakaakbe`.
4. Copy the client ID.

**2. Choose where the extension is hosted.** This can be any HTTPS location that serves static files. A GitHub Pages repo is the quickest.

**3. Build**

```
./build.sh <CLIENT_ID> https://<your-host>/drive-to-finder
```

Then upload `dist/drive-to-finder.crx` and `dist/update.xml` to that URL.

## Rollout through Iru (IT)

| Iru Library item | File | Settings |
|---|---|---|
| Custom Script | `dist/install-helper.sh` | Run once per device. Also offer it in Self Service if you like. |
| Custom Profile | `dist/chrome-policy.mobileconfig` | Assign to the same Blueprint |

The profile force-installs and pins the extension. Chrome allows extensions from outside the Web Store when the Mac is MDM-managed, which these Macs are through Iru. **If Apparent already pushes Chrome `ExtensionSettings` in another profile, merge this entry into that one** rather than adding a second profile, because two profiles setting the same key will clash.

To remove it, run `dist/uninstall-helper.sh` and unassign the profile.

**Updating:** bump `version` in `extension/manifest.json`, run `./build.sh` again and re-upload the two files. Chrome picks up the update on its own.

**Chrome Web Store alternative:** publish privately to the Apparent domain instead of self-hosting. The store assigns a new extension ID, so add that ID to `allowed_origins` in the helper manifest inside `install-helper.sh`.

## Testing on your own Mac first

1. Put your client ID into `extension/manifest.json`.
2. Go to `chrome://extensions`, turn on Developer mode and choose **Load unpacked** → `extension/`. The key in the manifest keeps the ID fixed, so the helper recognises it.
3. Run `sudo bash deploy/install-helper.sh`.
4. In Drive, select a file and click the button.

## Troubleshooting

| What you see | Why |
|---|---|
| "helper isn't installed" | The Iru script hasn't run on that Mac yet. |
| "isn't in your My Drive or a shared drive" | The item is only "Shared with me", so Drive for desktop doesn't sync it. |
| "isn't signed in as …" | Chrome's Google account doesn't match the account signed in to Drive for desktop. |
| Opens the parent folder instead of the file | The file hasn't synced yet, or its name contains characters macOS changes. |

Errors from the helper appear in `chrome://extensions` → Drive to Finder → **service worker** → Console.

## Files

```
extension/        Chrome extension (Manifest V3)
helper/           Mac helper source + Chrome native-messaging manifest
deploy/           Iru install/uninstall scripts, Chrome policy profile template
keys/             Signing key: keeps the extension ID stable. Keep it private and don't lose it.
build.sh          Builds dist/ for hosting and Iru
```
