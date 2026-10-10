# AmazOff

> Patch-based customization layer for the stock Amazon app on rooted LG webOS TVs.

![Screenshot](./Screenshot.png?raw=true)

## Overview

**AmazOff** is an IPK application for **rooted LG webOS TVs**. It extends the Amazon Prime Video Player with following patches applied:
- Remove Ads (Pre-, Mid- and Endrolls)
- Suppress telemetry

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

The player JavaScript is served by Amazon and changes independently of the installed IPK. Amazon serves a different bundle per route (`onebox1` for webOS 4.x, `wave1`-`wave3` for newer webOS). Run `development/amazon/setupDev.sh` to download each bundle, apply the structural no-ads transform (`build-patch.js`, which fails if any anchor is missing), and write `resources/amazon/patch/<route>/` with the patched bundle, `manifest.json` and nginx `identity.conf`. `development/amazon/prepareRelease.sh` re-checks the hashes, and you can point it at an unpacked IPK.

On Start, the service compares Amazon's live bundles to the manifests. A mismatch only logs a warning and shows a toast; the older patched bundle keeps being served. A request for an unknown route shows a toast, and the request appears in **Details**. On webOS 6.5, restart the TV after the first Start so the cached player bundle is discarded.
