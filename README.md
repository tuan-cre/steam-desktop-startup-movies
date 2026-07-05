# Steam Desktop Startup Movies

A [Millennium](https://millennium.dev/) plugin that plays a custom startup movie on Steam desktop launch — just like the Steam Deck startup animation, but for your PC.

## Why This Plugin?

Steam only supports startup movies in Big Picture mode. This plugin brings that experience to the regular desktop Steam client. Drop in a video, restart Steam, and enjoy your custom intro every time.

## Installation

1. Install [Millennium](https://millennium.dev/) (v3+)
2. Clone or download this repository into your Millennium plugins directory (`~/.local/share/millennium/plugins/`)
3. Place `.webm` or `.mp4` video files in the plugin's `movies/` folder
4. Restart Steam

## Features

- **Automatic playback** — video plays on Steam startup, dismissible by clicking
- **Movie selector** — choose which movie to play from the config panel
- **Video fit modes** — Contain (letterbox), Cover (crop), or Fill (stretch)
- **Thumbnail previews** — auto-generated preview images in the config panel (requires ffmpeg)
- **Plugin-local videos** — movies are stored inside the plugin folder, not Steam's config directory
- **Configurable transition** — choose between smooth fade or instant cut
- **Shuffle mode** — randomly pick a different movie each startup
- **Resilient server** — auto-detects port conflicts and restarts if the HTTP server crashes
- **Diagnostics** — status messages in the config panel when dependencies are missing

## Adding Movies

Drop any `.webm` or `.mp4` file into the `movies/` folder. The plugin will detect it automatically on next startup.

## Configuration

Open the plugin panel from Millennium's plugin settings:

- **Movie** — select which video to play at startup (shows file size and thumbnail)
- **Video Fit** — how the video scales to fill the screen (contain, cover, or fill)
- **Transition** — fade out or instant cut when dismissing the video
- **Playback Mode** — static (always plays the selected movie) or shuffle (random pick each startup)

## Requirements

- [Millennium](https://millennium.dev/) v3+
- Python 3 (for the local HTTP server that serves video files)
- ffmpeg (optional, for thumbnail generation)

If either dependency is missing, the plugin will show a status message in the config panel explaining what's unavailable.

## Troubleshooting

- **No movies appear** — Make sure `.webm` or `.mp4` files are in the `movies/` folder inside the plugin directory
- **Video doesn't play** — Check that Python 3 is installed and available on your PATH
- **Thumbnails missing** — Install ffmpeg for automatic thumbnail generation

## License

MIT
