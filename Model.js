// OmaYoutube-dl helpers: parsing + command builders. Pure JS, no Qt deps.

// Must match Panel.qml searchMaxBytes: hard cap on untrusted yt-dlp -J
// output. Panel.qml kills the provider process above this size and rejects
// before parsing; this guard is defense-in-depth for direct callers/tests.
var SEARCH_MAX_BYTES = 1048576;
var SEARCH_MAX_ENTRIES = 50;

function parseSearchJson(raw) {
  var out = [];
  try {
    var s = String(raw || "");
    if (s === "" || s.length > SEARCH_MAX_BYTES) return out;
    var doc = JSON.parse(s);
    var entries = doc.entries || [];
    var n = Math.min(entries.length, SEARCH_MAX_ENTRIES);
    for (var i = 0; i < n; ++i) {
      var e = entries[i] || {};
      var id = String(e.id || "");
      // Video ids are [A-Za-z0-9_-]; reject anything else so a crafted
      // provider response cannot inject URLs/thumbnails.
      if (!/^[A-Za-z0-9_-]{1,32}$/.test(id)) continue;
      var dur = e.duration_string || "";
      if (!dur && e.duration) dur = formatDuration(e.duration);
      out.push({
        id: id,
        title: String(e.title || "Untitled").slice(0, 300),
        channel: String(e.channel || e.uploader || "Unknown").slice(0, 200),
        duration: String(dur || "--:--").slice(0, 16),
        url: "https://www.youtube.com/watch?v=" + id,
        thumb: "https://i.ytimg.com/vi/" + id + "/mqdefault.jpg"
      });
    }
  } catch (err) {}
  return out;
}

function formatDuration(secs) {
  secs = Math.round(secs);
  if (!isFinite(secs) || secs < 0) return "--:--";
  var h = Math.floor(secs / 3600);
  var m = Math.floor((secs % 3600) / 60);
  var s = secs % 60;
  function p(n) { return (n < 10 ? "0" : "") + n; }
  if (h > 0) return h + ":" + p(m) + ":" + p(s);
  return m + ":" + p(s);
}

function isPlaylistUrl(url) {
  return url.indexOf("list=") !== -1;
}

function expandHome(path, home) {
  if (path && path.charAt(0) === "~") return (home || "") + path.slice(1);
  return path;
}

function qualityHeight(quality) {
  switch (String(quality)) {
  case "2160": return 2160;
  case "1440": return 1440;
  case "1080": return 1080;
  case "720": return 720;
  case "480": return 480;
  case "360": return 360;
  default: return 0;
  }
}

// Quality + audio-language -> yt-dlp -f selector for VIDEO mode.
// The leading term asks for the wanted track; the trailing terms degrade
// gracefully to best audio / best combined when it does not exist.
function videoFormatFor(quality, audioLang) {
  var h = qualityHeight(quality);
  var vf = h > 0 ? ("bv*[height<=" + h + "]") : "bv*";
  var fb = h > 0 ? ("b[height<=" + h + "]") : "b";
  var lang = String(audioLang || "original");

  if (lang === "original+pt")
    return vf + "+ba[format_note*=original]+ba[language^=pt]/"
         + vf + "+ba[format_note*=original]/"
         + vf + "+ba/" + fb;
  if (lang === "pt+en")
    return vf + "+ba[language^=pt]+ba[language^=en]/"
         + vf + "+ba[language^=pt]/"
         + vf + "+ba/" + fb;
  if (lang === "pt")
    return vf + "+ba[language^=pt]/" + vf + "+ba/" + fb;
  return vf + "+ba/" + fb;
}

// Audio-language -> yt-dlp -f selector for AUDIO mode (single track, so the
// dub is preferred and the original is the fallback).
function audioFormatFor(audioLang) {
  switch (String(audioLang)) {
  case "pt":
  case "original+pt":
    return "ba[language^=pt]/ba";
  case "pt+en":
    return "ba[language^=pt]/ba[language^=en]/ba";
  default:
    return "ba";
  }
}

// ISO 639-2 code to tag the first audio track with, when we know the picked
// language (yt-dlp otherwise leaves a misleading tag like "eng" on a dub).
function audioLangTag(audioLang) {
  switch (String(audioLang)) {
  case "pt":
  case "pt+en":
    return "por";
  default:
    return "";
  }
}

function audioLangOptions() {
  return [
    { value: "original", label: "Original / best" },
    { value: "pt", label: "Portuguese dub (fallback original)" },
    { value: "original+pt", label: "Original + Portuguese (MKV)" },
    { value: "pt+en", label: "Portuguese + English (MKV)" }
  ];
}

function subLangsOptions() {
  return [
    { value: "off", label: "Off" },
    { value: "pt,pt-BR,pt-PT", label: "Portuguese" },
    { value: "pt,pt-BR,pt-PT,en", label: "Portuguese + English" },
    { value: "all", label: "All available" }
  ];
}

function whisperEngineOptions() {
  return [
    { value: "off", label: "Off" },
    { value: "local", label: "Local whisper" },
    { value: "openai", label: "OpenAI API" }
  ];
}

function whisperApiModelOptions() {
  return [
    { value: "whisper-1", label: "whisper-1 (SRT / VTT)" },
    { value: "gpt-4o-transcribe", label: "gpt-4o-transcribe (text)" },
    { value: "gpt-4o-mini-transcribe", label: "gpt-4o-mini (text)" }
  ];
}

function whisperModelOptions() {
  return [
    { value: "auto", label: "Auto (small → …)" },
    { value: "small", label: "small" },
    { value: "medium", label: "medium" },
    { value: "large-v3-turbo", label: "large-v3-turbo" }
  ];
}

// Build a yt-dlp download command array (no shell quoting needed).
// opts: { url, mode: "video"|"audio", quality, audioFormat, videoFormat,
//         audioLang, subLangs, embedSubs, outDir, playlist, home }
function buildDownloadCommand(opts) {
  var cmd = ["yt-dlp", "--newline", "--progress", "--no-warnings"];
  cmd = cmd.concat(cookiesArgs(opts.cookies));
  var playlist = opts.playlist === "playlist";
  cmd.push(playlist ? "--yes-playlist" : "--no-playlist");

  var audioLang = String(opts.audioLang || "original");
  var multiAudio = audioLang.indexOf("+") !== -1;
  var subLangs = String(opts.subLangs || "off");
  var wantSubs = subLangs !== "" && subLangs !== "off";
  // Subtitles can only be embedded in a video container, never in an
  // extracted audio file (which gets a sidecar .srt instead).
  var embedSubs = opts.embedSubs === true && opts.mode !== "audio";

  var outDir = expandHome(opts.outDir || "~/Videos/Omayoutube", opts.home);
  var template = outDir + "/%(title)s [%(id)s].%(ext)s";
  if (playlist) template = outDir + "/%(playlist_title)s/%(playlist_index)s - %(title)s [%(id)s].%(ext)s";
  cmd.push("-o", template);

  var container = opts.videoFormat || "mp4";

  if (opts.mode === "audio") {
    cmd.push("-x", "--audio-format", opts.audioFormat || "mp3");
    cmd.push("-f", audioFormatFor(audioLang));
  } else {
    cmd.push("-f", videoFormatFor(opts.quality || "1080", audioLang));
    if (multiAudio) cmd.push("--audio-multistreams");
    // MKV is the container that reliably holds several audio tracks and
    // embedded subtitles; use it whenever we need either.
    if (multiAudio || embedSubs) container = "mkv";
    if (container !== "best") cmd.push("--remux-video", container);
    var langTag = audioLangTag(audioLang);
    if (langTag !== "") {
      cmd.push("--postprocessor-args", "Merger+ffmpeg:-metadata:s:a:0 language=" + langTag);
      cmd.push("--postprocessor-args", "VideoRemuxer+ffmpeg:-metadata:s:a:0 language=" + langTag);
    }
  }

  if (wantSubs) {
    // Subtitle fetches are the flakiest part (YouTube rate-limits them, and
    // a missing translation aborts the run); keep the video download alive.
    cmd.push("--ignore-errors");
    cmd.push("--write-subs", "--write-auto-subs", "--sub-langs", subLangs, "--convert-subs", "srt");
    if (embedSubs) cmd.push("--embed-subs");
  }

  cmd.push(opts.url);
  return cmd;
}

// Parse one yt-dlp progress line. Returns { pct } or null.
function parseProgressLine(line) {
  var m = /\[download\]\s+(\d+(?:\.\d+)?)%/.exec(String(line));
  if (m) {
    var v = parseFloat(m[1]);
    if (isFinite(v)) return { pct: Math.max(0, Math.min(100, v)) };
  }
  return null;
}

// Shell-quote one argv for bash -c use.
function shellQuote(s) {
  return "'" + String(s).replace(/'/g, "'\\''") + "'";
}

// Single-shell download script: ensures the dir, then execs yt-dlp with
// stderr merged to stdout so one SplitParser sees every progress line.
function buildDownloadScript(opts) {
  var parts = buildDownloadCommand(opts);
  var quoted = [];
  for (var i = 0; i < parts.length; ++i) quoted.push(shellQuote(parts[i]));
  var outDir = expandHome(opts.outDir || "~/Videos/Omayoutube", opts.home);
  return "mkdir -p " + shellQuote(outDir) + " && exec " + quoted.join(" ") + " 2>&1";
}

// Build a bash script that downloads the audio for `url`, converts it to
// 16 kHz mono WAV, then writes a subtitle file with a local whisper CLI or
// the OpenAI transcription API.
// opts: { url, id, outDir, engine, localCmd, lang, apiModel, keyEnv, cacheDir, home }
function buildTranscribeScript(opts) {
  var url = String(opts.url || "");
  var id = String(opts.id || extractId(url) || "video");
  var outDir = expandHome(opts.outDir || "~/Videos/Omayoutube", opts.home);
  var cache = String(opts.cacheDir || cacheDir(opts.home));
  var engine = String(opts.engine || "local");
  var lang = String(opts.lang || "pt");
  var base = cache + "/tr-" + id;

  var L = [];
  L.push("set -o pipefail");
  // Prefer a user-local whisper-cli (e.g. a Vulkan/CUDA build in ~/.local/bin)
  // over the CPU-only one shipped by the distro in /usr/bin.
  L.push("export PATH=\"$HOME/.local/bin:$PATH\"");
  L.push("mkdir -p " + shellQuote(outDir) + " " + shellQuote(cache));
  L.push("rm -f " + shellQuote(base) + ".*");
  L.push("echo 'Downloading audio for transcription...'");
  var dlArgs = ["yt-dlp", "--no-playlist", "-f", "ba[language^=pt]/ba",
    "-x", "--audio-format", "m4a", "-o", base + ".%(ext)s"].concat(cookiesArgs(opts.cookies));
  dlArgs.push(url);
  var dlQuoted = [];
  for (var di = 0; di < dlArgs.length; ++di) dlQuoted.push(shellQuote(dlArgs[di]));
  L.push(dlQuoted.join(" ") + " 2>&1 | grep -E '\\[download\\]|[Ee]rror' || true");
  L.push("audio=$(ls " + shellQuote(base) + ".* 2>/dev/null | grep -v '\\.wav$' | head -n1)");
  L.push("if [ -z \"$audio\" ]; then echo 'ERROR: could not download audio'; exit 2; fi");
  L.push("echo 'Audio ready: '$(basename \"$audio\")");

  if (engine === "openai") {
    var keyEnv = String(opts.keyEnv || "OPENAI_API_KEY");
    var model = String(opts.apiModel || "whisper-1");
    var fmt = (model === "whisper-1") ? "srt" : "json";
    var outExt = (fmt === "srt") ? ".srt" : ".json";
    var srtOut = outDir + "/" + id + outExt;
    L.push("key=\"${" + keyEnv + ":-}\"");
    L.push("if [ -z \"$key\" ]; then echo 'ERROR: " + keyEnv + " is not set'; exit 3; fi");
    L.push("tmpmp3=" + shellQuote(base + ".mp3"));
    L.push("ffmpeg -y -i \"$audio\" -vn -ac 1 -ar 16000 -b:a 32k \"$tmpmp3\" >/dev/null 2>&1");
    L.push("sz=$(stat -c%s \"$tmpmp3\" 2>/dev/null || echo 0)");
    L.push("if [ \"$sz\" -gt 24000000 ]; then echo 'ERROR: audio exceeds the 24MB API limit; use local whisper'; exit 4; fi");
    L.push("echo 'Sending to OpenAI (" + model + ")...'");
    L.push("curl -sS https://api.openai.com/v1/audio/transcriptions"
         + " -H \"Authorization: Bearer $key\""
         + " -F file=@\"$tmpmp3\""
         + " -F model=" + shellQuote(model)
         + " -F response_format=" + shellQuote(fmt)
         + (fmt === "srt" ? " -F temperature=0" : "")
         + " -o " + shellQuote(srtOut));
    L.push("if [ ! -s " + shellQuote(srtOut) + " ]; then echo 'ERROR: transcription request failed'; exit 5; fi");
    L.push("rm -f " + shellQuote(base) + ".*");
    L.push("echo " + shellQuote("DONE:" + srtOut));
    return L.join("\n");
  }

  // Local: normalize to 16 kHz mono WAV, then run a whisper CLI.
  var wav = base + ".wav";
  var srtOutLocal = outDir + "/" + id + ".srt";
  L.push("wav=" + shellQuote(wav));
  L.push("ffmpeg -y -i \"$audio\" -vn -ac 1 -ar 16000 -c:a pcm_s16le \"$wav\" >/dev/null 2>&1 || true");
  L.push("if [ ! -s \"$wav\" ]; then wav=\"$audio\"; fi");

  var tmpl = String(opts.localCmd || "auto");
  if (tmpl === "" || tmpl === "auto") {
    var prefModel = String(opts.model || "medium");
    L.push("echo 'Running local whisper (auto)...'");
    L.push("if command -v whisper-cli >/dev/null 2>&1; then");
    L.push("  model=\"\"");
    L.push("  [ -f \"$HOME/.local/share/voxtype/models/ggml-" + prefModel + ".bin\" ] && model=\"$HOME/.local/share/voxtype/models/ggml-" + prefModel + ".bin\"");
    L.push("  if [ -z \"$model\" ]; then for m in \"$HOME/.local/share/voxtype/models/ggml-small.bin\" \"$HOME/.local/share/voxtype/models/ggml-medium.bin\" \"$HOME/.local/share/voxtype/models/ggml-large-v3-turbo.bin\" \"$HOME/.local/share/voxtype/models/ggml-base.bin\"; do [ -f \"$m\" ] && { model=\"$m\"; break; }; done; fi");
    L.push("  if [ -z \"$model\" ]; then echo 'ERROR: no GGML model found in ~/.local/share/voxtype/models (set a command in Settings)'; exit 6; fi");
    L.push("  echo 'whisper.cpp model: '$(basename \"$model\")");
    // Physical cores, not logical: hyperthreads make whisper.cpp slower here.
    L.push("  t=$(lscpu -p=Core,Socket 2>/dev/null | grep -v '^#' | sort -u | wc -l); [ \"${t:-0}\" -gt 0 ] 2>/dev/null || t=$(nproc)");
    L.push("  whisper-cli -m \"$model\" -f \"$wav\" -l " + lang + " -t \"$t\" -pp -osrt -of " + shellQuote(base));
    L.push("elif command -v whisper >/dev/null 2>&1; then");
    L.push("  whisper \"$wav\" --model small --language " + lang + " --output_format srt --output_dir " + shellQuote(cache));
    L.push("elif command -v whisper-ctranslate2 >/dev/null 2>&1; then");
    L.push("  whisper-ctranslate2 \"$wav\" --model small --language " + lang + " --output_format srt --output_dir " + shellQuote(cache));
    L.push("else");
    L.push("  echo 'ERROR: no whisper CLI found. Install whisper.cpp (whisper-cli), openai-whisper, or faster-whisper.'");
    L.push("  exit 6");
    L.push("fi");
  } else {
    var cmdline = tmpl.replace(/\{wav\}/g, "\"$wav\"")
                      .replace(/\{input\}/g, "\"$audio\"")
                      .replace(/\{dir\}/g, shellQuote(cache))
                      .replace(/\{lang\}/g, lang);
    L.push("echo 'Running local whisper (custom)...'");
    L.push(cmdline);
  }
  L.push("srt=$(ls " + shellQuote(base) + "*.srt " + shellQuote(base) + "*.vtt 2>/dev/null | head -n1)");
  L.push("if [ -z \"$srt\" ]; then echo 'ERROR: no .srt/.vtt produced (check the command in Settings)'; exit 7; fi");
  L.push("cp -f \"$srt\" " + shellQuote(srtOutLocal));
  L.push("rm -f " + shellQuote(base) + ".*");
  L.push("echo " + shellQuote("DONE:" + srtOutLocal));
  return L.join("\n");
}

function transcribeLangOptions() {
  return [
    { value: "auto", label: "Auto-detect" },
    { value: "pt", label: "Portuguese" },
    { value: "en", label: "English" },
    { value: "es", label: "Spanish" },
    { value: "fr", label: "French" },
    { value: "de", label: "German" },
    { value: "it", label: "Italian" },
    { value: "ja", label: "Japanese" }
  ];
}

// ms -> m:ss for player position labels.
function fmtTime(ms) {
  var s = Math.floor((ms || 0) / 1000);
  if (!isFinite(s) || s < 0) s = 0;
  var m = Math.floor(s / 60);
  var r = s % 60;
  return m + ":" + (r < 10 ? "0" : "") + r;
}

// Extract a YouTube video id from watch/shorts/share URLs.
function extractId(url) {
  var u = String(url || "");
  var m = /[?&]v=([A-Za-z0-9_-]{6,})/.exec(u);
  if (m) return m[1];
  m = /youtu\.be\/([A-Za-z0-9_-]{6,})/.exec(u);
  if (m) return m[1];
  m = /\/(shorts|live|embed)\/([A-Za-z0-9_-]{6,})/.exec(u);
  if (m) return m[2];
  return "";
}

function cacheDir(home) {
  return (home || "") + "/.cache/omayoutube-dl";
}

function cacheFileFor(id, home) {
  return cacheDir(home) + "/watch-" + (id || "video") + ".mp4";
}

// Cache script: download+merge to a local mp4 so the embedded player can
// play videos that have no progressive (single-file) stream.
// H.264 (avc1) is preferred: VAAPI hardware decoding is broken for AV1/VP9
// on some systems (black screen with sound), while H.264 decodes fine.
function buildCacheScript(url, file, cookies) {
  var dir = String(file).replace(/\/[^\/]*$/, "");
  var args = ["yt-dlp", "--newline", "--progress", "--no-warnings", "--no-playlist",
    "-f", "bv*[vcodec^=avc1][height<=720]+ba/b[vcodec^=avc1][height<=720]/bv*[height<=720]+ba/b[height<=720]",
    "--remux-video", "mp4", "--force-overwrites", "-o", file].concat(cookiesArgs(cookies));
  args.push(url);
  var quoted = [];
  for (var i = 0; i < args.length; ++i) quoted.push(shellQuote(args[i]));
  return "mkdir -p " + shellQuote(dir) + " && exec " + quoted.join(" ") + " 2>&1";
}

// Delete downloaded files for one video id. Our template names files
// "<title> [<id>].<ext>", so match "*[<id>].*".
function buildDeleteScript(outDir, id, home) {
  if (!id) return "exit 0";
  var d = expandHome(outDir, home);
  return "rm -f " + shellQuote(d) + "/*" + shellQuote("[" + id + "]") + ".* 2>/dev/null; exit 0";
}

// YouTube results-page `sp` filter codes (yt-dlp's own ytsearchdate was
// removed, so non-relevance sorts go through the search URL instead).
var SEARCH_SP = {
  date: "CAI%3D",          // upload date (newest first)
  views: "CAM%3D",         // view count
  short: "EgIYAQ%3D%3D",   // under 4 minutes
  long: "EgIYAw%3D%3D"     // over 20 minutes
};

function searchSpec(query, count, sort) {
  var q = String(query || "");
  var sp = SEARCH_SP[String(sort || "relevance")];
  if (sp) return "https://www.youtube.com/results?search_query=" + encodeURIComponent(q) + "&sp=" + sp;
  return "ytsearch" + (count || 10) + ":" + q;
}

// yt-dlp args for authenticating with browser cookies, to get past YouTube's
// "sign in to confirm you're not a bot" checks.
function cookiesArgs(browser) {
  var b = String(browser || "off");
  if (b === "" || b === "off") return [];
  return ["--cookies-from-browser", b];
}

function cookiesBrowserOptions() {
  return [
    { value: "off", label: "Off" },
    { value: "chromium", label: "Chromium" },
    { value: "chrome", label: "Chrome" },
    { value: "firefox", label: "Firefox" },
    { value: "brave", label: "Brave" },
    { value: "vivaldi", label: "Vivaldi" },
    { value: "edge", label: "Edge" },
    { value: "opera", label: "Opera" }
  ];
}

function searchSortOptions() {
  return [
    { value: "relevance", label: "Relevance" },
    { value: "date", label: "Newest" },
    { value: "views", label: "Most viewed" },
    { value: "short", label: "Short (<4 min)" },
    { value: "long", label: "Long (>20 min)" }
  ];
}

function qualityOptions() {
  return [
    { value: "best", label: "Best available" },
    { value: "2160", label: "4K (2160p max)" },
    { value: "1440", label: "1440p max" },
    { value: "1080", label: "1080p max" },
    { value: "720", label: "720p max" },
    { value: "480", label: "480p max" },
    { value: "360", label: "360p (small)" }
  ];
}

function audioFormatOptions() {
  return ["mp3", "m4a", "opus", "flac", "wav"];
}

function videoContainerOptions() {
  return ["mp4", "mkv", "webm", "best"];
}

function maxResultsOptions() {
  return ["5", "10", "15"];
}
