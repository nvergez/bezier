# Own codec-enabled CEF builds, tracking the LTS channel

The Spotify-CDN CEF binaries ship without H.264/AAC, which a daily-driver browser cannot live without (the overlay spike had to test video with VP9). Bézier builds CEF from source with `proprietary_codecs=true ffmpeg_branding=Chrome` — the Chrome configuration, where both H.264 and AAC fully work — and tracks CEF's LTS channel so those heavy builds (hours, ~100GB disk) happen per LTS bump rather than monthly.

## Considered Options

- **Hardware-only proprietary decode** ([CEF #3559](https://github.com/chromiumembedded/cef/issues/3559)): no patent-licensing exposure (VideoToolbox carries it), and H.264 video works — but AAC audio is broken as of the maintainer's testing, so typical MP4s play silent. The escape hatch if licensing ever forces it and AAC gets fixed.
- **VP9/AV1-only on stock binaries**: no builds at all, but large parts of web video break.

## Consequences

Patent licensing (Via-LA AVC pool) is a *distribution* concern: irrelevant while builds are personal, to be verified before public binary distribution (reported royalty-free thresholds exist but must be confirmed then). LTS means new web-platform features and some fixes arrive later than monthly stable; revisit the channel choice if build automation makes monthly cheap.
