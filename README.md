# Startup Movies

A [Millennium](https://millennium.dev/) plugin that plays a startup movie on Steam launch, similar to the Steam Deck experience.

## Installation

1. Clone or download this repository
2. Place it in your Millennium plugins directory (`~/.local/share/millennium/plugins/`)
3. Place `.webm` or `.mp4` video files in the plugin's `movies/` folder
4. Restart Steam

## Features

- **Automatic playback** — video plays on Steam startup, dismissible by clicking
- **Movie selector** — choose which movie to play from the config panel
- **Video fit modes** — Contain (letterbox), Cover (crop), or Fill (stretch)
- **Thumbnail previews** — auto-generated preview images in the config panel (requires ffmpeg)
- **Plugin-local videos** — movies are stored inside the plugin folder, not Steam's config directory
- **Fade transition** — smooth fade-out when dismissed or video ends
- **Resilient server** — auto-detects port conflicts and restarts if the HTTP server crashes
- **Diagnostics** — status messages in the config panel when dependencies are missing

## Adding Movies

Drop any `.webm` or `.mp4` file into the `movies/` folder. The plugin will detect it automatically on next startup.

## Configuration

Open the plugin panel from Millennium's plugin settings:

- **Movie** — select which video to play at startup (shows file size)
- **Video Fit** — how the video scales to fill the screen

## Requirements

- [Millennium](https://millennium.dev/) v3+
- Python 3 (for the local HTTP server that serves video files)
- ffmpeg (optional, for thumbnail generation)

If either dependency is missing, the plugin will show a status message in the config panel explaining what's unavailable.

## License

MIT
