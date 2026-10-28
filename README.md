# AmazOff

> Patch-based customization layer for the stock Amazon app on rooted LG webOS TVs.

> [!NOTE]
> AmazOff continues development of [azoffshowy/AmazOff](https://github.com/azoffshowy/AmazOff), which stopped at 0.2.3. It tracks Amazon's current player bundle and adds the fixes listed under [Changes since upstream 0.2.3](#changes-since-upstream-023).

![Screenshot](./Screenshot.png?raw=true)

## Changes since upstream 0.2.3

Version 0.3.1, compared with upstream 0.2.3:

**Supported**
- Amazon's current player bundle (October 2026), which `onebox1` and `wave1`-`wave3` now all serve. The no-ads patch is built per route and checked by hash.
- Prime Video app 6.3.42, including blocking its pre-rolls.
- [Glasshouse](https://github.com/rorygallagher2024/glasshouse) 0.100 or later with its ad blocker on. Glasshouse keeps AmazOff's hosts entry in its table.

**Fixed**
- AmazOff now uses its own CA, which is only valid for the player bundle host. The goproxy CA used up to 0.2.3 has a public private key; Start removes it from the Amazon app.
- AmazOff no longer sets `disable-ssl-cert` in the Amazon app's `default_config.json`. That flag turned off TLS certificate checks for every connection the app made, not only the player bundle. The CA pin is enough, because the app trusts the certificates in `bin/certs`. Start removes the flag, and Stop doesn't restore a backup that contains it.
- The webOS 3.x (lovefilm) patch no longer adds the goproxy CA; Start and Stop remove the copy older versions added.
- Stop also removes AmazOff's CA from the Amazon app and restores its `default_config.json`. Before, the app kept trusting the CA after Stop, and the CA's server key ships in every IPK.
- If another tool rewrites `/etc/hosts`, the monitor puts AmazOff's entry back, and the service shows *stopped* while the entry is missing.
- Stop removes the hosts entry, including from the rootfs `/etc/hosts` underneath a bind-mounted table. Before, Glasshouse could copy a stale entry back at boot and break Prime Video after AmazOff was switched off.
- Start works on TVs with a read-only `/etc/hosts`, such as a C4 on webOS 10.3.1 without Homebrew Channel's "Block system updates". AmazOff mounts a writable copy over it, as that option does. Before, Start failed with "Read-only file system".
- A failed Start now removes the hosts entries and restores Prime Video's config. Before, it could stop partway and leave Prime Video sending the player bundle to a local server that was no longer running, so playback failed.
- A toast and a warning in **Details** appear when another hosts entry overrides AmazOff's, for example a hosts list uploaded to Glasshouse that blocks `cloudfront.xp-assets.aiv-cdn.net`.
- Player analytics calls are no-ops, so telemetry is suppressed without breaking resume position or playback session reporting.
- On firmware without `cksum` (seen on webOS 5), the monitor uses `md5sum` to spot hosts file changes. Before, it logged an error every 10 seconds and rescanned the hosts files each time.
- With autostart on, Prime Video opened before AmazOff finished starting kept the unpatched player until it was restarted. Autostart now closes Prime Video if it's in the background, or shows a toast asking you to restart it if it's on screen.

**Updated**
- nginx 1.30.6 with OpenSSL 3.5.9, replacing nginx 1.26.0 with OpenSSL 1.1.1w. OpenSSL 1.1.1 has had no free security fixes since September 2023.

## Overview

**AmazOff** is an IPK application for **rooted LG webOS TVs**. It extends the Amazon Prime Video Player with following patches applied:
- Remove Ads (Pre-, Mid- and Endrolls)
- Suppress player telemetry (analytics, metrics, log uploads and ad beacons; resume position and playback session reporting are left intact)

As a result, all launch paths—including the **remote control’s dedicated Amazon button**—will open the modified version.

AmazOff requires **[Homebrew Channel](https://www.webosbrew.org/)** to be present and functional.

## Status

- **Development stage:** early / experimental  
- **Tested on:** webOS 3.x, webOS 4.x, webOS 5.x, webOS 6.5, webOS 9.x, webOS 10.x
- **Amazon app variants:** 4.1.15, 4.5.25, 5.3.10, 6.3.38, 6.3.42, 1.1.121

## WebOS < 4.0

On WebOS prior to 4.0 the No-Ads patch only removes loaded Ads. Pre-Rolls from prime themself are still embedded into the stream, but can be fast-forwarded out of.

## Requirements

- Rooted LG webOS TV  
- [Homebrew Channel](https://www.webosbrew.org/)  
- Stock Amazon Prime Video app installed  

## Installation

Preferred installation methods:

- Install the latest `.ipk` from [Releases](https://github.com/samoz83/AmazOff/releases) using **[Device Manager for webOS](https://github.com/webosbrew/dev-manager-desktop)**, or
- If you use [Glasshouse](https://github.com/rorygallagher2024/glasshouse), install it from the **Apps** tab under **Install app from a URL or file**, by uploading the `.ipk` or pasting the `.ipk` link from Releases. That section stays off until you switch it on there.

Both avoid manual packaging, signing, or SSH interaction.

## Moving from upstream AmazOff

This version installs over upstream 0.2.3, because it has the same app id (`com.amazoff.patcher`) and a higher version. After installing, open AmazOff and press **Stop**, then **Start**. Start removes upstream's goproxy CA and the `disable-ssl-cert` flag from the Amazon app.

## Usage

1. Launch **AmazOff**
2. Run **Start Service**
3. **Optional**: Enable Autostart
4. **Launch Target App**: Launch the Amazon Prime Video App.

Notes:
- A successful patch is confirmed by a **toast notification** when the Amazon app is launched (Only WebOS > 4.0).
- If the service cant be started you can check for possible fault in the **Details** page.

## Troubleshooting

**`Denied method call "exec" for category "/"`** (seen on webOS 26 / 11.2.0). Homebrew Channel no longer lets other apps call its root service. AmazOff is not the cause, and other root apps fail the same way. Over SSH as root:

1. Run `/media/developer/apps/usr/palm/services/org.webosbrew.hbchannel.service/elevate-service`, then reboot the TV.
2. If the error stays, give AmazOff access to the service, then reboot:
   ```sh
   echo '{"com.amazoff.patcher-*":["public"]}' > /var/luna-service2-dev/client-permissions.d/com.amazoff.patcher.app.json
   ```
3. As a last resort, run the service script directly: `sh /media/developer/apps/usr/palm/applications/com.amazoff.patcher/tools/patchctl.sh start`.

## Development Notes

The `development` folder is not shipped in the IPK.

- `createPackage.sh` builds the IPK, checks it against the source files, and writes the Homebrew Channel manifest. Needs `ares-package` from the webOS CLI.
- `amazon/` holds the scripts that patch Amazon's player bundle. See [Updating the Amazon player bundle](#updating-the-amazon-player-bundle). The `.patch` files and `logReceiver.py` are older diff-based aids.
- `nginx/build.sh` rebuilds `tools/nginx/nginx`, a static ARMv7 binary with OpenSSL linked in, from hash-checked sources. Needs Docker with ARM emulation.
- `mitm/` is a debug proxy for watching the Amazon app's traffic. See `development/mitm/README.md`.
- `lovefilm/` holds older aids for the webOS 3.x patch.

Pushing a `v_<version>` tag builds the IPK on GitHub and creates a draft release.

Feel free to PR additional patches.

## Updating the Amazon player bundle

The player JavaScript is served by Amazon and changes independently of the installed IPK. Amazon serves a different bundle per route (`onebox1` for webOS 4.x, `wave1`-`wave3` for newer webOS; as of October 2026 they all serve the same bundle). Run `development/amazon/setupDev.sh` to download each bundle, apply the structural no-ads transform (`build-patch.js`, which fails if any anchor is missing), and write `resources/amazon/patch/<route>/` with the patched bundle, `manifest.json` and nginx `identity.conf`. `development/amazon/prepareRelease.sh` re-checks the hashes, and you can point it at an unpacked IPK. `development/amazon/hosts_test.sh` tests the hosts-file handling. `development/amazon/checkUpstream.sh` compares the live bundles with the ones the patches were built from; a weekly GitHub Action runs it and opens an issue when Amazon ships a new bundle.

The service reports *running* only while nginx, the monitor, the hosts override and the CA in the Amazon app are all in place (the monitor puts the CA back after an Amazon app update), so a hosts file rewritten by another tool shows up as *stopped*. Another entry for the bundle host (such as a blocklist sinkhole) shows a toast and a warning in **Details**. A request for an unknown route shows a toast, and the request appears in **Details**. On webOS 6.5, restart the TV after the first Start so the cached player bundle is discarded.
