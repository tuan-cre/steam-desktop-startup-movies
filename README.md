# Startup Movies

A [Millennium](https://millennium.dev/) plugin that plays a startup movie on Steam launch, similar to the Steam Deck experience.

## Installation

1. Download the latest release from [Releases](https://github.com/tuan-cre/startup-movies/releases)
2. Extract into your Millennium plugins directory
3. Place `.webm` or `.mp4` video files in the `movies/` folder
4. Restart Steam

## Features

- **Automatic playback** — video plays on Steam startup, dismissible by clicking
- **Movie selector** — choose which movie to play from the config panel
- **Video fit modes** — Contain (letterbox), Cover (crop), or Fill (stretch)
- **Thumbnail previews** — auto-generated preview images in the config panel
- **Plugin-local videos** — movies are stored inside the plugin folder, not Steam's config directory

## Adding Movies

Drop any `.webm` or `.mp4` file into the `movies/` folder. The plugin will detect it automatically on next startup.

Thumbnails are generated on first load using ffmpeg (must be installed on your system).

## Configuration

Open the plugin panel from Millennium's plugin settings:

- **Movie** — select which video to play at startup
- **Video Fit** — how the video scales to fill the screen

## Requirements

- [Millennium](https://millennium.dev/) v3+
- ffmpeg (for thumbnail generation)

## License

MIT
