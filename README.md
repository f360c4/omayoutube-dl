# OmaYoutube-dl (fork)

Search YouTube, preview audio, download videos/audios/playlists — and now grab
**dubbed audio tracks, native subtitles, or Whisper-generated `.srt`** — straight
from the Omarchy bar.

Built for the Omarchy Quattro shell as a `bar-widget` with a nested details panel.

This is a fork of [`Aznit11/omayoutube-dl`](https://github.com/Aznit11/omayoutube-dl)
with extra features (see **Fork additions** below).

## Install

```sh
omarchy plugin add https://github.com/f360c4/omayoutube-dl.git --enable
```

Requires system tools (already on most Omarchy installs):

```sh
command -v yt-dlp mpv ffmpeg socat
```

### Fresh machine (format) quickstart

```sh
# 1. plugin
omarchy plugin add https://github.com/f360c4/omayoutube-dl.git --enable

# 2. GPU Whisper build (recommended; reuses voxtype's GGML models)
~/.config/omarchy/plugins/io.github.aznit11.omayoutube-dl/scripts/setup-whisper-vulkan.sh
```

That's it — set the bar widget and the plugin's `auto` mode will use the GPU build.

## Usage

- Click the `YT` bar button to open the panel.
- **Search tab**: type a query, pick a **Search filter** (Relevance / Newest /
  Most viewed / Short / Long), hit Search.
  - `Watch` plays the video EMBEDDED in the panel (progressive mp4 stream).
  - `Download` queues the item for download (auto-switches to Downloads tab).
  - `Subs` transcribes the item to a `.srt` with local Whisper (see GPU setup).
- **Direct URL**: paste a video or playlist URL, hit Queue.
- **Player card**: Play/Pause, Stop, seek slider, `Player` (default player),
  `mpv` (fullscreen), `Subtitles (whisper)`. Falls back to an mpv audio preview
  when there is no embeddable stream.
- **Downloads tab**: live progress, queue, completed history, cancel, open-folder.
- **Settings tab**: everything below, plus a dependency check.

Playback controls use `mpv --input-ipc-server=/tmp/omayoutube-mpv.sock` + `socat`.

## Fork additions

- **Audio track / dub** — select the original, a Portuguese dub (with original
  fallback), or multiple tracks (Original + PT / PT + EN) merged into one MKV.
  Uses yt-dlp format filters (`ba[language^=pt]`); multi-track adds
  `--audio-multistreams`. YouTube auto-dub availability varies per video, so the
  original is always the fallback.
- **Native subtitles** — Off / Portuguese / Portuguese + English / all, with an
  **Embed** toggle (embed into MKV, or save a sidecar `.srt`). Uses YouTube's own
  captions and auto-translations (no Whisper needed).
- **Whisper transcription** — a `Subs` button on each result and in the player.
  Downloads the audio, converts it to 16 kHz mono WAV, then runs:
  - **Local** (default): auto-detects `whisper-cli` / `whisper` /
    `whisper-ctranslate2`, reusing the GGML models already downloaded by
    **voxtype** (`~/.local/share/voxtype/models/`). A GPU (Vulkan) build is
    strongly recommended — see below.
  - **OpenAI** (optional, off): `--cookies`-free API path; `whisper-1` gives
    real SRT/VTT timestamps.
- **Search filter** — sort results by date/views or filter by duration.
- **Browser cookies** — pass `--cookies-from-browser <browser>` to yt-dlp to get
  past YouTube's "confirm you're not a bot" checks.

### GPU (Vulkan) Whisper — recommended

The distro `whisper-cpp` package is **CPU-only** and slow on long videos. This
fork ships a script that builds a **static Vulkan** `whisper-cli` into
`~/.local/bin`, which the plugin's `auto` mode then uses automatically:

```sh
# from the installed plugin directory (see Install)
~/.config/omarchy/plugins/io.github.aznit11.omayoutube-dl/scripts/setup-whisper-vulkan.sh
```

No root needed. It installs `cmake`/`ninja` via `mise` if missing, clones
whisper.cpp + Vulkan/SPIRV headers, and builds. Requires the Vulkan loader and
`glslc` (usually present). Each transcription runs as its own process, so the
model is loaded into VRAM on start and freed when it exits.

Models: `small` (~1 GB VRAM), `medium` (~1.5 GB), `large-v3-turbo` (~1.6 GB).
On a 4 GB GPU with a browser/editor open, **medium** is the sweet spot.

## Configure

Settings persist inline in `~/.config/omarchy/shell.json` on the plugin entry:

| key | default | meaning |
|---|---|---|
| `downloadDir` | `~/Videos/Omayoutube` | download target |
| `quality` | `1080` | max video height |
| `audioFormat` | `mp3` | audio extract format |
| `videoFormat` | `mp4` | remux container |
| `dlMode` | `video` | `video` or `audio` |
| `playlistMode` | `single` | `single` or `playlist` |
| `maxResults` | `10` | search result count |
| `searchSort` | `relevance` | `relevance`/`date`/`views`/`short`/`long` |
| `cookiesBrowser` | `off` | `off`/`chromium`/`chrome`/`firefox`/... |
| `audioLang` | `original` | `original`/`pt`/`original+pt`/`pt+en` |
| `subLangs` | `off` | subtitle languages, e.g. `pt,pt-BR,pt-PT` |
| `embedSubs` | `false` | embed subs into the video (forces MKV) |
| `whisperEngine` | `local` | `off`/`local`/`openai` |
| `whisperLang` | `pt` | transcription language |
| `whisperModel` | `medium` | `auto`/`small`/`medium`/`large-v3-turbo` |
| `whisperCmd` | `auto` | `auto` or a custom template (`{wav} {input} {dir} {lang}`) |
| `whisperApiModel` | `whisper-1` | OpenAI model (`whisper-1` for SRT) |
| `whisperKeyEnv` | `OPENAI_API_KEY` | env var holding the API key |

Move the widget:

```sh
omarchy bar move io.github.aznit11.omayoutube-dl --section right
```

## IPC

```sh
qs -p /usr/share/omarchy/shell ipc call io.github.aznit11.omayoutube-dl toggle
qs -p /usr/share/omarchy/shell ipc call io.github.aznit11.omayoutube-dl transcribe "https://youtu.be/VIDEO_ID"
```

## Remove

```sh
omarchy plugin remove io.github.aznit11.omayoutube-dl
```

Killing the panel stops the audio preview. Cancelling downloads stops yt-dlp;
partial `.part` files stay in the download folder for resume.

## License

MIT (same as upstream).
