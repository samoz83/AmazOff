# AmazOff

> Patch-based customization layer for the stock Amazon app on rooted LG webOS TVs.

> [!NOTE]
> This is an updated fork of [azoffshowy/AmazOff](https://github.com/azoffshowy/AmazOff). It tracks Amazon's current player bundle and adds the fixes listed under [What's new in this fork](#whats-new-in-this-fork).

![Screenshot](./Screenshot.png?raw=true)

## What's new in this fork

Version 0.2.5, compared with upstream 0.2.3:

**Supported**
- Amazon's current player bundle (October 2026), which `onebox1` and `wave1`-`wave3` now all serve. The no-ads patch is built per route and checked by hash.
- Prime Video app 6.3.42, including blocking its pre-rolls.
- [Glasshouse](https://github.com/rorygallagher2024/glasshouse) 0.100 or later with its ad blocker on. Glasshouse keeps AmazOff's hosts entry in its table.

**Fixed**
- AmazOff now uses its own CA, which is only valid for the player bundle host. The goproxy CA used up to 0.2.3 has a public private key; Start removes it from the Amazon app.
- If another tool rewrites `/etc/hosts`, the monitor puts AmazOff's entry back, and the service shows *stopped* while the entry is missing.
- Stop removes the hosts entry, including from the rootfs `/etc/hosts` underneath a bind-mounted table. Before, Glasshouse could copy a stale entry back at boot and break Prime Video after AmazOff was switched off.
- A toast and a warning in **Details** appear when another hosts entry overrides AmazOff's, for example a hosts list uploaded to Glasshouse that blocks `cloudfront.xp-assets.aiv-cdn.net`.
- Player analytics calls are no-ops, so telemetry is suppressed without breaking resume position or playback session reporting.

## Overview

**AmazOff** is an IPK application for **rooted LG webOS TVs**. It extends the Amazon Prime Video Player with following patches applied:
- Remove Ads (Pre-, Mid- and Endrolls)
- Suppress player telemetry (analytics, metrics, log uploads and ad beacons; resume position and playback session reporting are left intact)

As a result, all launch paths—including the **remote control’s dedicated Amazon button**—will open the modified version.

AmazOff requires **[Homebrew Channel](https://www.webosbrew.org/)** to be present and functional.

## Status

- **Development stage:** early / experimental  
- **Tested on:** webOS 3.x, webOS 4.x, webOS 6.5, webOS 9.x, webOS 10.x
- **Amazon app variants:** 4.1.15, 6.3.38, 6.3.42, 1.1.121

## WebOS < 4.0

On WebOS prior to 4.0 the No-Ads patch only removes loaded Ads. Pre-Rolls from prime themself are still embedded into the stream, but can be fast-forwarded out of.

## Requirements

- Rooted LG webOS TV  
- [Homebrew Channel](https://www.webosbrew.org/)  
- Stock Amazon Prime Video app installed  

## Installation

Preferred installation method:

- Install the released `.ipk` using **[Device Manager for webOS](https://github.com/webosbrew/dev-manager-desktop)**

This avoids manual packaging, signing, or SSH interaction.

## Usage

1. Launch **AmazOff**
2. Run **Start Service**
3. **Optional**: Enable Autostart
4. **Launch Target App**: Launch the Amazon Prime Video App.

Notes:
- A successful patch is confirmed by a **toast notification** when the Amazon app is launched (Only WebOS > 4.0).
- If the service cant be started you can check for possible fault in the **Details** page.

## Development Notes

Within the folder **development** you can find the applied patches to the player resources. It also contains a setup script for development as well as a script how the dev-version was then packed. Feel free to PR additional patches.

## Updating the Amazon player bundle

The player JavaScript is served by Amazon and changes independently of the installed IPK. Amazon serves a different bundle per route (`onebox1` for webOS 4.x, `wave1`-`wave3` for newer webOS; as of October 2026 they all serve the same bundle). Run `development/amazon/setupDev.sh` to download each bundle, apply the structural no-ads transform (`build-patch.js`, which fails if any anchor is missing), and write `resources/amazon/patch/<route>/` with the patched bundle, `manifest.json` and nginx `identity.conf`. `development/amazon/prepareRelease.sh` re-checks the hashes, and you can point it at an unpacked IPK.

The service reports *running* only while nginx, the monitor and the hosts override are all in place, so a hosts file rewritten by another tool shows up as *stopped*. Another entry for the bundle host (such as a blocklist sinkhole) shows a toast and a warning in **Details**. A request for an unknown route shows a toast, and the request appears in **Details**. On webOS 6.5, restart the TV after the first Start so the cached player bundle is discarded.
