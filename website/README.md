# Open Speech ASR website

Static Chinese release site for Open Speech ASR.

## Public URLs

- Site: `https://openspeech.bumiaoai.com/`
- Download: `https://github.com/PacoZhou1/open-speech-asr/releases/latest`
- TP-7 Vibe Input: `https://openspeech.bumiaoai.com/tp7-vibe-input.html`
- TP-7 Vibe Input Download: `https://openspeech.bumiaoai.com/downloads/TP7VibeInput-2026-06-23.dmg`

## Files

- `index.html` - Chinese landing page with SEO metadata, structured data, download CTA, install notes, privacy notes, and checksum.
- `tp7-vibe-input.html` - TP-7 Vibe Input product page for the Open Speech hardware-controller workflow.
- `assets/icon-open-speech-terminal-clean-20260618.png` - clean generated app icon used by the page and social metadata.
- `assets/open-speech-app-icon.png` - current Open Speech ASR application icon.
- `assets/github-shortcut-mapping.png` - Open Speech shortcut and preset mapping reference.
- `assets/github-tp7-vibe-deck-overview.png` - TP-7 Vibe Deck overview screenshot.
- `assets/github-tp7-vibe-deck-mapping.png` - TP-7 Vibe Deck mapping screenshot.
- `assets/tp7-vibe-input-icon.png` - TP-7 Vibe Input icon used by the product page and Open Graph metadata.
- `assets/tp7-official-front-1024.webp` - TP-7 front product image from teenage engineering press assets.
- `assets/tp7-official-detail-1024.webp` - TP-7 detail product image from teenage engineering press assets.
- `assets/tp7-app-overview.jpg` - TP-7 Vibe Input app screenshot showing the full 3D mapping interface.
- `assets/tp7-app-3d-demo.jpg` - TP-7 Vibe Input app screenshot focused on the 3D model.
- `assets/tp7-app-mapping-panel.jpg` - TP-7 Vibe Input app screenshot focused on the mapping inspector.
- `assets/tp7-real-keyboard-web.jpg` - optimized real photo of TP-7 beside a keyboard for the product page interface section.
- `assets/tp7-real-desk-web.jpg` - optimized real desk photo showing TP-7 in the physical workspace.
- `assets/tp7.css` - TP-7 product page and homepage hardware-controller section styles.
- `assets/demo.gif` - reserved product demo asset.
- `llms.txt` - concise product summary for AI agents and answer engines.
- `robots.txt` - crawler policy and sitemap pointer.
- `sitemap.xml` - sitemap for `https://openspeech.bumiaoai.com/`.

## Release Artifact

Expected TP-7 Vibe Input DMG:

```text
TP7VibeInput.dmg
```

Website filename:

```text
downloads/TP7VibeInput-2026-06-23.dmg
```

SHA256:

```text
d960be0402e1fe4f33b30ccf3cc5bd49ad40cd3936739eca5d7cb919db42eb8e
```

TP-7 Vibe Input positions the app as a hardware controller layer for Open Speech ASR. It requires TP-7 MIDI `ctrl` mode, macOS Accessibility/Microphone permission, and an installed Open Speech ASR app. It is an independent utility, not official Teenage Engineering software.

TP-7 product imagery source: teenage engineering press images, `https://teenage.engineering/press`.

## Deploy

Serve this directory as the web root for `https://openspeech.bumiaoai.com/`.
Publish the Open Speech ASR DMG through the GitHub Release assets. GitHub's per-asset limit requires the full local-model DMG to be uploaded as numbered parts plus `Open-Speech-ASR.dmg.sha256`; the website download button points to the Release page where users can download and reassemble them.
Upload the TP-7 DMG to `downloads/TP7VibeInput-2026-06-23.dmg`.
