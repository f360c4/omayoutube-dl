import QtQuick
import Quickshell
import Quickshell.Io
import QtMultimedia
import qs.Commons
import qs.Ui
import "Model.js" as Model

// OmaYoutube-dl panel: search YouTube via yt-dlp, watch video EMBEDDED via
// QtMultimedia (progressive mp4 stream resolved with yt-dlp -g), fall back
// to mpv audio when no progressive stream exists, download video/audio +
// playlists with live progress, settings persisted to shell.json.
Panel {
  id: root
  moduleName: "io.github.aznit11.omayoutube-dl"
  manageIpc: false

  // Panel body text. Use the fixed theme bar text (like first-party panels),
  // NOT the wallpaper-adaptive barForeground: with a transparent bar over a
  // light wallpaper that resolves to a dark color and vanishes on the dark
  // popup surface.
  readonly property color panelForeground: bar ? bar.foreground : Color.foreground

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ---- settings (persisted inline in shell.json) ----
  readonly property string homeDir: Quickshell.env("HOME")
  property string downloadDir: setting("downloadDir", "~/Videos/Omayoutube")
  property string quality: setting("quality", "1080")
  property string audioFormat: setting("audioFormat", "mp3")
  property string videoFormat: setting("videoFormat", "mp4")
  property string dlMode: setting("dlMode", "video")
  property string playlistMode: setting("playlistMode", "single")
  property string maxResults: setting("maxResults", "10")
  property string searchSort: setting("searchSort", "relevance")
  property string cookiesBrowser: setting("cookiesBrowser", "off")
  property bool showVideo: setting("showVideo", true)
  property string audioLang: setting("audioLang", "original")
  property string subLangs: setting("subLangs", "off")
  property bool embedSubs: setting("embedSubs", false)
  property string whisperEngine: setting("whisperEngine", "local")
  property string whisperLang: setting("whisperLang", "pt")
  property string whisperModel: setting("whisperModel", "medium")
  property string whisperCmd: setting("whisperCmd", "auto")
  property string whisperApiModel: setting("whisperApiModel", "whisper-1")
  property string whisperKeyEnv: setting("whisperKeyEnv", "OPENAI_API_KEY")

  // ---- ui state ----
  property string tab: "search"
  property string query: ""
  property bool searching: false
  property string searchError: ""
  property string statusLine: "Search YouTube, watch inside, download anything."

  // ---- search safety limits (untrusted yt-dlp -J output) ----
  // Hard output cap + deadline: kill the provider process and reject the
  // request when either is exceeded, before JSON parsing.
  readonly property int searchMaxBytes: 1048576
  readonly property int searchTimeoutMs: 30000
  property string searchAbortReason: ""

  // ---- in-plugin player ----
  property string nowTitle: ""
  property string nowUrl: ""
  property string nowId: ""
  property bool resolving: false
  property bool caching: false
  property real cachePct: 0
  property string cacheDetail: ""
  property string cacheFile: ""
  property bool videoActive: false
  property bool audioFallback: false
  property bool previewPlaying: false
  property bool previewPaused: false
  property string playerError: ""

  // ---- downloads ----
  property bool downloading: false
  property real activePct: 0
  property string activeTitle: ""
  property string activeId: ""
  property string activeUrl: ""
  property string activeDetail: "idle"
  property string lastDone: ""

  // ---- transcription (whisper, local by default) ----
  property bool transcribing: false
  property string transcribeTitle: ""
  property string transcribeDetail: "idle"
  property real transcribePct: 0

  function setting(name, fallback) {
    var v = settings ? settings[name] : undefined;
    return (v === undefined || v === null || v === "") ? fallback : v;
  }

  function persistSettings(values) {
    var entry = { id: root.moduleName };
    for (var k in root.settings) if (k !== "id") entry[k] = root.settings[k];
    for (var key in values) entry[key] = values[key];
    root.settings = entry;
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry;
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry);
  }

  function open(payloadJson) {
    root.controller.show();
    Qt.callLater(function() {
      if (root.opened) setHoverSuppressed(true);
    });
    // Deep-link: summon with {"play": "<youtube-url>", "title": "..."}
    // starts playback immediately (used by tests + future launcher hooks).
    try {
      var payload = JSON.parse(payloadJson || "{}") || {};
      if (payload.play) Qt.callLater(function() { root.playVideo(String(payload.title || payload.play), String(payload.play)); });
    } catch (e) {}
  }

  function close() {
    // Hide only: playback keeps going in the background (mpv process or
    // Qt Video). The Stop button ends it on demand.
    setHoverSuppressed(false);
    root.controller.hide();
  }

  function toggle() {
    if (root.opened) root.close();
    else root.open();
  }

  function closeForPopoutSwitch() {
    root.close();
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction);
    return false;
  }

  function setHoverSuppressed(value) {
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value);
    else if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value;
  }

  // ================= search =================
  function searchOutputSize() {
    var n = 0;
    try { n += searchStdout.text.length; } catch (e) {}
    try { n += searchStderr.text.length; } catch (e) {}
    return n;
  }

  function abortSearch(reason) {
    if (root.searchAbortReason === "") root.searchAbortReason = reason;
    searchTimeout.stop();
    if (searchProc.running) searchProc.running = false;
    if (root.searching) {
      root.searching = false;
      if (reason === "timeout") {
        root.searchError = "Search timed out after " + Math.round(root.searchTimeoutMs / 1000) + "s. Try again.";
        root.statusLine = "Search timed out.";
      } else {
        root.searchError = "Search response too large (>" + Math.round(root.searchMaxBytes / 1024) + " KB). Rejected.";
        root.statusLine = "Search rejected: response too large.";
      }
    }
  }

  function enforceSearchLimits() {
    if (!root.searching || root.searchAbortReason !== "") return;
    if (root.searchOutputSize() > root.searchMaxBytes) root.abortSearch("too-large");
  }

  function doSearch() {
    var q = searchField.text.replace(/^\s+|\s+$/g, "");
    if (q === "" || searchProc.running) return;
    root.query = q;
    root.searching = true;
    root.searchAbortReason = "";
    root.searchError = "";
    root.statusLine = "Searching for \"" + q + "\"…";
    resultsModel.clear();
    searchProc.command = ["yt-dlp", Model.searchSpec(q, root.maxResults, root.searchSort), "--flat-playlist", "--playlist-end", root.maxResults, "-J", "--no-warnings"].concat(Model.cookiesArgs(root.cookiesBrowser));
    searchProc.running = true;
    searchTimeout.restart();
  }

  function handleSearchDone(text) {
    searchTimeout.stop();
    if (root.searchAbortReason !== "") return;
    root.searching = false;
    var s = String(text || "");
    if (s.length > root.searchMaxBytes) {
      root.searchError = "Search response too large (>" + Math.round(root.searchMaxBytes / 1024) + " KB). Rejected.";
      root.statusLine = "Search rejected: response too large.";
      return;
    }
    var items = Model.parseSearchJson(s);
    resultsModel.clear();
    for (var i = 0; i < items.length; ++i) resultsModel.append(items[i]);
    if (items.length === 0) {
      root.searchError = "No results. Check network or try another query.";
      root.statusLine = "Search returned nothing.";
    } else {
      root.statusLine = items.length + " results for \"" + root.query + "\".";
    }
  }

  // ================= in-plugin video =================
  function playVideo(title, url) {
    var u = String(url || "");
    // Tapping the current video toggles pause instead of restarting.
    if (u !== "" && u === root.nowUrl && (root.videoActive || root.audioFallback) && root.previewPlaying) {
      root.togglePause();
      return;
    }
    stopPlayback();
    root.nowTitle = String(title || u);
    root.nowUrl = u;
    root.nowId = Model.extractId(u);
    // Audio mode: straight to audio preview, no video section.
    if (root.dlMode === "audio") {
      playAudioFallback();
      return;
    }
    root.resolving = true;
    root.caching = false;
    root.videoActive = false;
    root.statusLine = "Resolving stream: " + root.nowTitle;
    // Progressive H.264 mp4 (video+audio in one URL) so the player shows
    // picture + sound. itag 22/18 are H.264; VAAPI is broken for AV1/VP9
    // here (black screen), so avc is preferred throughout.
    resolveProc.command = ["yt-dlp", "-g", "-f", "22/18/17/36/b[vcodec^=avc1][height<=480]/b[height<=480]/w", "--no-warnings"].concat(Model.cookiesArgs(root.cookiesBrowser)).concat([root.nowUrl]);
    resolveProc.running = true;
  }

  function handleResolveDone(text) {
    root.resolving = false;
    var lines = String(text || "").split("\n");
    var stream = "";
    for (var i = 0; i < lines.length; ++i) {
      var t = lines[i].replace(/^\s+|\s+$/g, "");
      if (t.indexOf("http") === 0) { stream = t; break; }
    }
    if (stream !== "") {
      root.videoActive = true;
      root.playerError = "";
      mplayer.source = stream;
      mplayer.play();
      root.statusLine = "Playing in plugin: " + root.nowTitle;
    } else {
      // No progressive stream (DASH-only upload): cache the video to a
      // local mp4 first, then play the file inside the plugin.
      startCacheWatch();
    }
  }

  function startCacheWatch() {
    if (root.nowUrl === "") return;
    root.caching = true;
    root.cachePct = 0;
    root.cacheDetail = "caching video for in-plugin playback…";
    root.cacheFile = Model.cacheFileFor(root.nowId, root.homeDir);
    root.statusLine = "Caching video (one-time)…";
    cacheProc.command = ["bash", "-c", Model.buildCacheScript(root.nowUrl, root.cacheFile, root.cookiesBrowser)];
    cacheProc.running = true;
  }

  function handleCacheLine(line) {
    var s = String(line || "");
    if (s.trim() === "") return;
    var r = Model.parseProgressLine(s);
    if (r) {
      root.cachePct = r.pct;
      root.cacheDetail = s.trim().slice(0, 80);
    } else {
      var t = s.trim();
      if (t.indexOf("Destination:") !== -1 || t.indexOf("Merging") !== -1 || t.indexOf("[info]") === 0)
        root.cacheDetail = t.slice(0, 80);
    }
  }

  function handleCacheDone(ok) {
    root.caching = false;
    if (ok) {
      root.videoActive = true;
      root.playerError = "";
      mplayer.source = "file://" + root.cacheFile;
      mplayer.play();
      root.statusLine = "Playing in plugin: " + root.nowTitle;
    } else {
      // Last resort: mpv audio preview.
      playAudioFallback();
    }
  }

  function playAudioFallback() {
    root.audioFallback = true;
    root.previewPlaying = true;
    root.previewPaused = false;
    previewProc.command = ["mpv", root.nowUrl, "--no-video", "--force-window=no",
      "--input-ipc-server=/tmp/omayoutube-mpv.sock",
      "--ytdl-format=bestaudio/best", "--no-terminal"];
    previewProc.running = true;
    root.statusLine = "Audio preview (no embeddable stream): " + root.nowTitle;
  }

  function togglePause() {
    if (root.videoActive) {
      if (mplayer.playbackState === MediaPlayer.PlayingState) mplayer.pause();
      else mplayer.play();
      return;
    }
    if (root.audioFallback && root.previewPlaying) {
      ctlProc.command = ["bash", "-c", "echo '{\"command\":[\"cycle\",\"pause\"]}' | socat - /tmp/omayoutube-mpv.sock >/dev/null 2>&1"];
      ctlProc.running = true;
      root.previewPaused = !root.previewPaused;
    }
  }

  function stopPlayback() {
    if (previewProc.running) previewProc.running = false;
    if (cacheProc.running) cacheProc.running = false;
    try { mplayer.stop(); } catch (e) {}
    mplayer.source = "";
    root.videoActive = false;
    root.audioFallback = false;
    root.previewPlaying = false;
    root.previewPaused = false;
    root.resolving = false;
    root.caching = false;
    root.playerError = "";
  }

  function playExternal(url) {
    var u = String(url || root.nowUrl || "");
    if (u === "") return;
    openProc.command = ["bash", "-c", "xdg-open " + Model.shellQuote(u) + " >/dev/null 2>&1 &"];
    openProc.running = true;
    root.statusLine = "Opened in default player.";
  }

  function playVideoMpv(url) {
    var u = String(url || root.nowUrl || "");
    if (u === "") return;
    openProc.command = ["bash", "-c", "mpv " + Model.shellQuote(u) + " --fs >/dev/null 2>&1 &"];
    openProc.running = true;
    root.statusLine = "Opened fullscreen in mpv.";
  }

  // ================= downloads =================
  function queueDownload(title, url) {
    var t = String(title || url || "download");
    var u = String(url || "");
    if (u === "") {
      root.statusLine = "Cannot queue: empty URL.";
      return;
    }
    dlQueueModel.append({ title: t, url: u, vid: Model.extractId(u) });
    root.tab = "downloads";
    root.statusLine = "Queued: " + t + " (" + dlQueueModel.count + " waiting)";
    if (!root.downloading) startNextDownload();
  }

  function downloadUrlDirect() {
    var u = urlField.text.replace(/^\s+|\s+$/g, "");
    if (u === "") return;
    if (Model.isPlaylistUrl(u) && root.playlistMode === "playlist") queueDownload("Playlist: " + u, u);
    else queueDownload(u, u);
    urlField.clear();
  }

  function startNextDownload() {
    if (root.downloading || dlQueueModel.count === 0) return;
    var job = dlQueueModel.get(0);
    var jobTitle = (job && job.title) ? String(job.title) : "";
    var jobUrl = (job && job.url) ? String(job.url) : "";
    var jobId = (job && job.vid) ? String(job.vid) : Model.extractId(jobUrl);
    dlQueueModel.remove(0);
    if (jobUrl === "") {
      root.statusLine = "Skipped a queued item with no URL.";
      Qt.callLater(root.startNextDownload);
      return;
    }
    root.activeTitle = jobTitle !== "" ? jobTitle : jobUrl;
    root.activeId = jobId;
    root.activeUrl = jobUrl;
    root.activePct = 0;
    root.activeDetail = "starting yt-dlp…";
    root.downloading = true;
    root.statusLine = "Downloading: " + root.activeTitle;
    var script = Model.buildDownloadScript({
      url: jobUrl, mode: root.dlMode, quality: root.quality,
      audioFormat: root.audioFormat, videoFormat: root.videoFormat,
      audioLang: root.audioLang, subLangs: root.subLangs, embedSubs: root.embedSubs, cookies: root.cookiesBrowser,
      outDir: root.downloadDir, playlist: root.playlistMode, home: root.homeDir
    });
    dlProc.command = ["bash", "-c", script];
    dlProc.running = true;
  }

  function handleDlLine(line) {
    var s = String(line || "");
    if (s.trim() === "") return;
    var r = Model.parseProgressLine(s);
    if (r) {
      root.activePct = r.pct;
      root.activeDetail = s.trim().slice(0, 100);
      return;
    }
    var t = s.trim();
    // Keep last meaningful status; skip carriage-return noise.
    if (t.indexOf("[info]") === 0 || t.indexOf("[youtube]") === 0
        || t.indexOf("Destination:") !== -1 || t.indexOf("Merging") !== -1
        || t.indexOf("Deleting") !== -1 || t.indexOf("ExtractAudio") !== -1
        || t.indexOf("ERROR") !== -1 || t.indexOf("WARNING") !== -1)
      root.activeDetail = t.slice(0, 110);
  }

  function finishDownload(ok, errText) {
    if (ok) {
      root.activePct = 100;
      root.lastDone = "Done: " + root.activeTitle;
      historyModel.insert(0, { title: root.activeTitle, detail: "100% • " + root.dlMode + " • " + root.quality, vid: root.activeId, url: root.activeUrl });
      root.statusLine = root.lastDone;
    } else {
      root.statusLine = "Failed: " + root.activeTitle;
      if (errText && String(errText).trim() !== "") root.activeDetail = String(errText).slice(0, 140);
    }
    root.downloading = false;
    if (dlQueueModel.count > 0) {
      Qt.callLater(root.startNextDownload);
    } else {
      if (!ok) root.activePct = 0;
      else Qt.callLater(function() { if (!root.downloading) root.activePct = 0; });
    }
  }

  function cancelDownload() {
    if (dlProc.running) dlProc.running = false;
    dlQueueModel.clear();
    root.downloading = false;
    root.activePct = 0;
    root.activeDetail = "cancelled";
    root.statusLine = "Download cancelled.";
  }

  function openDownloadFolder() {
    var outDir = Model.expandHome(root.downloadDir, root.homeDir);
    openProc.command = ["bash", "-c", "mkdir -p " + Model.shellQuote(outDir) + "; xdg-open " + Model.shellQuote(outDir) + " >/dev/null 2>&1 &"];
    openProc.running = true;
  }

  function removeQueued(index) {
    if (index < 0 || index >= dlQueueModel.count) return;
    dlQueueModel.remove(index);
    root.statusLine = "Removed from queue.";
  }

  function deleteHistory(index) {
    if (index < 0 || index >= historyModel.count) return;
    var item = historyModel.get(index);
    var vid = (item && item.vid) ? String(item.vid) : "";
    historyModel.remove(index);
    if (vid !== "") {
      delProc.command = ["bash", "-c", Model.buildDeleteScript(root.downloadDir, vid, root.homeDir)];
      delProc.running = true;
      root.statusLine = "Deleted download + files.";
    } else {
      root.statusLine = "Removed entry.";
    }
  }

  function clearHistory() {
    historyModel.clear();
    root.statusLine = "History cleared.";
  }

  function clearVideoCache() {
    openProc.command = ["bash", "-c", "rm -rf " + Model.shellQuote(Model.cacheDir(root.homeDir)) + " && echo cleared"];
    openProc.running = true;
    root.statusLine = "Video cache cleared.";
  }

  function checkDeps() {
    depProc.running = true;
  }

  // ================= transcription (whisper) =================
  function transcribe(title, url) {
    var u = String(url || "");
    console.log("[omayoutube] transcribe() engine=" + root.whisperEngine + " url=" + u.slice(0, 60));
    if (u === "") { root.statusLine = "No URL to transcribe."; return; }
    if (root.transcribing) { root.statusLine = "Already transcribing."; return; }
    if (root.whisperEngine === "off") {
      root.statusLine = "Transcription is off — pick an engine in Settings.";
      root.tab = "settings";
      return;
    }
    root.transcribing = true;
    root.transcribeTitle = String(title || u);
    root.transcribePct = 0;
    root.transcribeDetail = "starting…";
    root.statusLine = "Transcribing: " + root.transcribeTitle;
    root.tab = "downloads";
    var script = Model.buildTranscribeScript({
      url: u, id: "", outDir: root.downloadDir, engine: root.whisperEngine,
      localCmd: root.whisperCmd, lang: root.whisperLang, model: root.whisperModel,
      apiModel: root.whisperApiModel,
      keyEnv: root.whisperKeyEnv, cookies: root.cookiesBrowser, cacheDir: Model.cacheDir(root.homeDir), home: root.homeDir
    });
    trProc.command = ["bash", "-c", script];
    trProc.running = true;
  }

  function handleTrLine(line) {
    var s = String(line || "");
    if (s.trim() === "") return;
    // yt-dlp download progress (0-100).
    var r = Model.parseProgressLine(s);
    if (r) {
      root.transcribePct = r.pct;
      root.transcribeDetail = "Downloading audio… " + Math.round(r.pct) + "%";
      return;
    }
    // whisper.cpp progress (-pp), e.g. "whisper_print_progress_callback: progress =  42%".
    var wp = /progress\s*=\s*(\d+)\s*%/.exec(s);
    if (wp) {
      var v = parseInt(wp[1], 10);
      if (isFinite(v)) root.transcribePct = Math.max(0, Math.min(100, v));
      root.transcribeDetail = "Transcribing… " + Math.round(root.transcribePct) + "%";
      return;
    }
    var t = s.trim();
    if (t.indexOf("DONE:") === 0) {
      root.transcribePct = 100;
      root.transcribeDetail = "saved " + t.slice(5);
      return;
    }
    root.transcribeDetail = t.slice(0, 120);
  }

  function cancelTranscribe() {
    if (trProc.running) trProc.running = false;
    root.transcribing = false;
    root.transcribePct = 0;
    root.transcribeDetail = "cancelled";
    root.statusLine = "Transcription cancelled.";
  }

  function dismissTranscribe() {
    root.transcribeDetail = "idle";
    root.transcribePct = 0;
  }

  // Live player diagnostics are logged ([omayoutube] state/tracks/error)
  // for troubleshooting with `qs log`.

  // ---- models ----
  ListModel { id: resultsModel }
  ListModel { id: dlQueueModel }
  ListModel { id: historyModel }

  // Headless autoplay sentinel (diagnostics + scripting):
  // writing a URL to ~/.cache/omayoutube-dl/autoplay.url plays it.
  readonly property string autoPlayFile: homeDir + "/.cache/omayoutube-dl/autoplay.url"
  FileView {
    id: autoPlayView
    path: root.autoPlayFile
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var u = String(text() || "").trim().split("\n")[0] || "";
      if (u !== "") {
        console.log("[omayoutube] autoplay sentinel: " + u.slice(0, 60));
        root.playVideo("autoplay", u);
      }
    }
  }

  // ---- processes ----
  // Hard deadline for the search provider: a hanging yt-dlp is killed and
  // the request rejected instead of buffering forever.
  Timer {
    id: searchTimeout
    interval: root.searchTimeoutMs
    repeat: false
    onTriggered: root.abortSearch("timeout")
  }

  Process {
    id: searchProc
    stdout: StdioCollector {
      id: searchStdout
      waitForEnd: true
      onDataChanged: root.enforceSearchLimits()
      onStreamFinished: {
        if (root.searchAbortReason === "") root.handleSearchDone(String(text || ""));
      }
    }
    stderr: StdioCollector {
      id: searchStderr
      waitForEnd: true
      onDataChanged: root.enforceSearchLimits()
    }
    onExited: function(code) {
      searchTimeout.stop();
      if (root.searchAbortReason !== "") return;
      if (code !== 0 && root.searching) {
        root.searching = false;
        root.searchError = "Search failed (exit " + code + "). Is yt-dlp installed?";
      } else if (code !== 0 && resultsModel.count === 0) {
        root.searchError = "Search failed (exit " + code + ").";
      }
    }
  }

  Process {
    id: resolveProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleResolveDone(String(text || ""))
    }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(code) {
      if (code !== 0 && root.resolving) {
        root.resolving = false;
        root.playAudioFallback();
      }
    }
  }

  Process {
    id: dlProc
    stdout: SplitParser { onRead: function(line) { root.handleDlLine(line); } }
    stderr: SplitParser { onRead: function(line) { root.handleDlLine(line); } }
    onExited: function(code) {
      if (!root.downloading) return;
      if (code === 0) root.finishDownload(true, "");
      else root.finishDownload(false, root.activeDetail);
    }
  }

  Process {
    id: cacheProc
    stdout: SplitParser { onRead: function(line) { root.handleCacheLine(line); } }
    stderr: SplitParser { onRead: function(line) { root.handleCacheLine(line); } }
    onExited: function(code) {
      if (!root.caching) return;
      root.handleCacheDone(code === 0);
    }
  }

  Process { id: delProc }

  Process {
    id: previewProc
    onExited: function() {
      if (root.audioFallback) {
        root.audioFallback = false;
        root.previewPlaying = false;
        root.previewPaused = false;
      }
    }
  }

  Process { id: ctlProc }
  Process { id: openProc }

  Process {
    id: trProc
    stdout: SplitParser { onRead: function(line) { root.handleTrLine(line); } }
    stderr: SplitParser { onRead: function(line) { root.handleTrLine(line); } }
    onExited: function(code) {
      console.log("[omayoutube] transcribe process exited code=" + code + " transcribing=" + root.transcribing);
      if (!root.transcribing) return;
      root.transcribing = false;
      if (code === 0) {
        root.transcribePct = 100;
        root.statusLine = "Subtitles ready: " + root.transcribeDetail;
        historyModel.insert(0, {
          title: root.transcribeTitle,
          detail: ".srt • " + (root.whisperEngine === "openai" ? root.whisperApiModel : "whisper local"),
          vid: "", url: ""
        });
      } else {
        root.statusLine = "Transcription failed (exit " + code + "). " + root.transcribeDetail;
      }
    }
  }

  Process {
    id: depProc
    command: ["bash", "-c", "echo -n 'yt-dlp '; (yt-dlp --version 2>/dev/null || echo missing); echo -n 'mpv '; (mpv --version 2>/dev/null | head -n1 || echo missing); echo -n 'ffmpeg '; (ffmpeg -version 2>/dev/null | head -n1 || echo missing); echo -n 'whisper '; (command -v whisper-cli || command -v whisper || echo missing); echo -n 'curl '; (command -v curl || echo missing)"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { depText.text = String(text || "").trim(); }
    }
    stderr: StdioCollector { waitForEnd: true }
  }

  // Canonical Qt6 playback chain: player decodes, VideoOutput paints the
  // picture, AudioOutput routes the sound. Keeps A/V together.
  MediaPlayer {
    id: mplayer
    autoPlay: false
    audioOutput: AudioOutput { id: mplayerAudio }
    videoOutput: vout
    onPlaybackStateChanged: {
      root.previewPlaying = (playbackState !== MediaPlayer.StoppedState);
      root.previewPaused = (playbackState === MediaPlayer.PausedState);
      console.log("[omayoutube] mplayer state=" + playbackState + " hasVideo=" + mplayer.hasVideo
        + " hasAudio=" + mplayer.hasAudio + " videoTracks=" + mplayer.videoTracks.length
        + " pos=" + mplayer.position + " dur=" + mplayer.duration + " err=" + mplayer.errorString);
    }
    onTracksChanged: {
      console.log("[omayoutube] tracks video=" + mplayer.videoTracks.length + " audio=" + mplayer.audioTracks.length);
    }
    onErrorOccurred: function(error, errorString) {
      root.playerError = String(errorString || "playback error").slice(0, 140);
      root.statusLine = "Player error: " + root.playerError;
      console.log("[omayoutube] mplayer ERROR " + error + " " + root.playerError);
    }
  }

  // ================= UI =================
  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(700))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: searchField.activeFocus || urlField.activeFocus || dirField.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction); }

      Column {
        id: content
        width: parent.width
        spacing: Style.space(10)

        // header
        Row {
          width: parent.width
          spacing: Style.space(10)
          Rectangle {
            width: Style.space(44)
            height: Style.space(44)
            radius: width / 2
            color: Color.accent
            anchors.verticalCenter: parent.verticalCenter
            Text {
              anchors.centerIn: parent
              text: "󰇚"
              color: "#101315"
              font.pixelSize: 22
            }
          }
          Column {
            spacing: 0
            anchors.verticalCenter: parent.verticalCenter
            Text {
              text: "OMAYOUTUBE-DL"
              color: root.panelForeground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
            }
            Text {
              text: root.statusLine
              textFormat: Text.PlainText
              color: Qt.darker(root.panelForeground, 1.4)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
              width: Style.space(500)
            }
          }
        }

        // search row
        Row {
          width: parent.width
          spacing: Style.space(8)
          TextField {
            id: searchField
            width: parent.width - Style.space(104)
            placeholderText: "Search YouTube… (title, artist, URL)"
            foreground: root.panelForeground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.doSearch();
                event.accepted = true;
              } else if (event.key === Qt.Key_Escape) {
                root.close();
                event.accepted = true;
              }
            }
          }
          Button {
            width: Style.space(96)
            text: root.searching ? "…" : "Search"
            iconText: root.searching ? "" : ""
            iconSpinning: root.searching
            bordered: true
            foreground: root.panelForeground
            accent: Color.accent
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            tooltipText: "Search YouTube"
            onClicked: root.doSearch()
          }
        }

        // search sort/filter
        Dropdown {
          width: parent.width
          label: "Search filter"
          value: root.searchSort
          options: Model.searchSortOptions()
          foreground: root.panelForeground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          onChanged: function(v) {
            root.searchSort = v;
            root.persistSettings({ searchSort: v });
          }
        }

        // direct URL row
        Row {
          width: parent.width
          spacing: Style.space(8)
          TextField {
            id: urlField
            width: parent.width - Style.space(104)
            placeholderText: "Paste video / playlist URL…"
            foreground: root.panelForeground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.downloadUrlDirect();
                event.accepted = true;
              }
            }
          }
          Button {
            width: Style.space(96)
            text: "Queue"
            iconText: ""
            bordered: true
            foreground: root.panelForeground
            accent: Color.accent
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            tooltipText: "Queue URL for download"
            onClicked: root.downloadUrlDirect()
          }
        }

        // mode toggles
        Row {
          width: parent.width
          spacing: Style.space(8)
          Button {
            text: "Video"
            iconText: ""
            selected: root.dlMode === "video"
            bordered: true
            foreground: root.panelForeground
            accent: Color.accent
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            tooltipText: "Download full video"
            onClicked: {
              root.dlMode = "video";
              root.persistSettings({ dlMode: "video" });
            }
          }
          Button {
            text: "Audio"
            iconText: ""
            selected: root.dlMode === "audio"
            bordered: true
            foreground: root.panelForeground
            accent: Color.accent
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            tooltipText: "Extract audio only"
            onClicked: {
              root.dlMode = "audio";
              root.persistSettings({ dlMode: "audio" });
            }
          }
          Button {
            text: root.playlistMode === "playlist" ? "Playlist" : "Single"
            iconText: ""
            selected: root.playlistMode === "playlist"
            bordered: true
            foreground: root.panelForeground
            accent: Color.accent
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            tooltipText: "Toggle full-playlist vs single-video downloads"
            onClicked: {
              var next = root.playlistMode === "playlist" ? "single" : "playlist";
              root.playlistMode = next;
              root.persistSettings({ playlistMode: next });
            }
          }
        }

        // tabs
        Row {
          width: parent.width
          spacing: Style.space(6)
          Button {
            text: "Search"
            iconText: ""
            selected: root.tab === "search"
            bordered: root.tab === "search"
            foreground: root.panelForeground
            accent: Color.accent
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            onClicked: root.tab = "search"
          }
          Button {
            text: "Downloads" + (root.downloading ? " " + Math.round(root.activePct) + "%" : (dlQueueModel.count > 0 ? " (" + dlQueueModel.count + ")" : ""))
            iconText: ""
            selected: root.tab === "downloads"
            bordered: root.tab === "downloads"
            foreground: root.panelForeground
            accent: Color.accent
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            onClicked: root.tab = "downloads"
          }
          Button {
            text: "Settings"
            iconText: ""
            selected: root.tab === "settings"
            bordered: root.tab === "settings"
            foreground: root.panelForeground
            accent: Color.accent
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            onClicked: root.tab = "settings"
          }
        }

        // ===== active download progress =====
        Rectangle {
          visible: root.downloading
          width: parent.width
          height: progressCard.implicitHeight + Style.space(20)
          radius: Style.cornerRadius
          color: Qt.rgba(root.panelForeground.r, root.panelForeground.g, root.panelForeground.b, 0.07)
          border.width: 1
          border.color: Color.accent
          Column {
            id: progressCard
            width: parent.width - Style.space(20)
            x: Style.space(10)
            y: Style.space(10)
            spacing: Style.space(6)
            Row {
              width: parent.width
              spacing: Style.space(8)
              Text {
                width: parent.width - Style.space(150)
                text: "⬇ " + root.activeTitle
                textFormat: Text.PlainText
                color: root.panelForeground
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.bodySmall
                font.bold: true
                elide: Text.ElideRight
              }
              Text {
                width: Style.space(60)
                horizontalAlignment: Text.AlignRight
                text: Math.round(root.activePct) + "%"
                color: Color.accent
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.title
                font.bold: true
              }
              Button {
                width: Style.space(74)
                text: "Cancel"
                iconText: ""
                foreground: root.panelForeground
                accent: Color.accent
                fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                tooltipText: "Cancel all downloads"
                onClicked: root.cancelDownload()
              }
            }
            Rectangle {
              width: parent.width
              height: Style.space(12)
              radius: height / 2
              color: Qt.rgba(root.panelForeground.r, root.panelForeground.g, root.panelForeground.b, 0.15)
              Rectangle {
                width: Math.max(Style.space(12), Math.round(parent.width * Math.max(0, Math.min(1, root.activePct / 100))))
                height: parent.height
                radius: parent.radius
                color: Color.accent
              }
            }
            Text {
              width: parent.width
              text: root.activeDetail
              textFormat: Text.PlainText
              color: Qt.darker(root.panelForeground, 1.5)
              font.family: "monospace"
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }
        }

        // ===== transcription progress =====
        Rectangle {
          visible: root.transcribing || (root.transcribeDetail !== "idle" && root.transcribeDetail !== "")
          width: parent.width
          height: trCard.implicitHeight + Style.space(20)
          radius: Style.cornerRadius
          color: Qt.rgba(root.panelForeground.r, root.panelForeground.g, root.panelForeground.b, 0.07)
          border.width: 1
          border.color: Color.accent
          Column {
            id: trCard
            width: parent.width - Style.space(20)
            x: Style.space(10)
            y: Style.space(10)
            spacing: Style.space(6)
            Row {
              width: parent.width
              spacing: Style.space(8)
              Text {
                width: parent.width - Style.space(150)
                text: "󰈙 " + root.transcribeTitle
                textFormat: Text.PlainText
                color: root.panelForeground
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.bodySmall
                font.bold: true
                elide: Text.ElideRight
              }
              Text {
                width: Style.space(60)
                horizontalAlignment: Text.AlignRight
                text: Math.round(root.transcribePct) + "%"
                color: Color.accent
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.title
                font.bold: true
              }
              Button {
                width: Style.space(74)
                text: root.transcribing ? "Cancel" : "Close"
                iconText: ""
                foreground: root.panelForeground
                accent: Color.accent
                fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                tooltipText: root.transcribing ? "Cancel transcription" : "Dismiss"
                onClicked: root.transcribing ? root.cancelTranscribe() : root.dismissTranscribe()
              }
            }
            Rectangle {
              width: parent.width
              height: Style.space(12)
              radius: height / 2
              color: Qt.rgba(root.panelForeground.r, root.panelForeground.g, root.panelForeground.b, 0.15)
              Rectangle {
                width: Math.max(Style.space(12), Math.round(parent.width * Math.max(0, Math.min(1, root.transcribePct / 100))))
                height: parent.height
                radius: parent.radius
                color: Color.accent
              }
            }
            Text {
              width: parent.width
              text: root.transcribeDetail
              textFormat: Text.PlainText
              color: Qt.darker(root.panelForeground, 1.5)
              font.family: "monospace"
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }
        }

        // ---- SEARCH TAB ----
        Column {
          visible: root.tab === "search"
          width: parent.width
          spacing: Style.space(6)
          Text {
            visible: root.searchError !== ""
            width: parent.width
            text: root.searchError
            color: Color.urgent
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }
          Text {
            visible: resultsModel.count === 0 && !root.searching && root.searchError === ""
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: "Search above — results appear here with watch + download actions."
            color: Qt.darker(root.panelForeground, 1.5)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
            font.italic: true
          }
          // Player left, results right (results go full width when idle).
          Row {
            width: parent.width
            spacing: Style.space(8)
            // ===== mini player (left column) =====
            Rectangle {
              visible: root.nowTitle !== ""
              width: Style.space(264)
              height: miniCol.implicitHeight + Style.space(20)
              radius: Style.cornerRadius
              color: Qt.rgba(root.panelForeground.r, root.panelForeground.g, root.panelForeground.b, 0.07)
              border.width: 1
              border.color: Color.accent
              Column {
                id: miniCol
                width: parent.width - Style.space(16)
                x: Style.space(8)
                y: Style.space(10)
                spacing: Style.space(6)
                Text {
                  width: parent.width
                  text: (root.resolving || root.caching ? "◌ " : (root.previewPaused ? "⏸ " : "▶ ")) + root.nowTitle
                  textFormat: Text.PlainText
                  color: root.panelForeground
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                  elide: Text.ElideRight
                  maximumLineCount: 2
                  wrapMode: Text.WordWrap
                }
                Rectangle {
                  visible: root.videoActive && root.showVideo && root.dlMode !== "audio"
                  width: parent.width
                  height: Style.space(132)
                  radius: Style.space(6)
                  color: "black"
                  clip: true
                  VideoOutput {
                    id: vout
                    anchors.fill: parent
                    fillMode: VideoOutput.PreserveAspectFit
                  }
                  Text {
                    visible: root.resolving
                    anchors.centerIn: parent
                    text: "Resolving…"
                    color: "white"
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.bodySmall
                  }
                }
                Text {
                  visible: root.playerError !== ""
                  width: parent.width
                  text: "⚠ " + root.playerError
                  textFormat: Text.PlainText
                  color: Color.urgent
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }
                Text {
                  visible: root.audioFallback
                  width: parent.width
                  text: "♪ Audio-only preview."
                  color: Qt.darker(root.panelForeground, 1.3)
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.caption
                  font.italic: true
                }
                Column {
                  visible: root.caching
                  width: parent.width
                  spacing: Style.space(4)
                  Text {
                    width: parent.width
                    text: "Caching… " + Math.round(root.cachePct) + "%"
                    color: Color.accent
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                  }
                  Rectangle {
                    width: parent.width
                    height: Style.space(8)
                    radius: height / 2
                    color: Qt.rgba(root.panelForeground.r, root.panelForeground.g, root.panelForeground.b, 0.15)
                    Rectangle {
                      width: Math.max(Style.space(8), Math.round(parent.width * Math.max(0, Math.min(1, root.cachePct / 100))))
                      height: parent.height
                      radius: parent.radius
                      color: Color.accent
                    }
                  }
                }
                Row {
                  visible: root.videoActive && mplayer.duration > 0
                  width: parent.width
                  spacing: Style.space(6)
                  Text {
                    width: Style.space(76)
                    text: Model.fmtTime(mplayer.position) + "/" + Model.fmtTime(mplayer.duration)
                    color: Qt.darker(root.panelForeground, 1.3)
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.caption
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  PanelSlider {
                    id: seekBar
                    width: parent.width - Style.space(82)
                    bar: root.bar
                    minimum: 0
                    maximum: mplayer.duration > 0 ? mplayer.duration : 1
                    value: mplayer.position
                    anchors.verticalCenter: parent.verticalCenter
                    onReleased: function(v) { mplayer.setPosition(v); }
                  }
                }
                Column {
                  width: parent.width
                  spacing: Style.space(6)
                  Row {
                    width: parent.width
                    spacing: Style.space(6)
                    Button {
                      width: (parent.width - Style.space(6)) / 2
                      text: root.previewPaused ? "Play" : "Pause"
                      iconText: root.previewPaused ? "" : ""
                      bordered: true
                      selected: root.previewPlaying && !root.previewPaused
                      foreground: root.panelForeground
                      accent: Color.accent
                      fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                      tooltipText: "Play / pause"
                      onClicked: root.togglePause()
                    }
                    Button {
                      width: (parent.width - Style.space(6)) / 2
                      text: "Stop"
                      iconText: ""
                      bordered: true
                      foreground: root.panelForeground
                      accent: Color.accent
                      fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                      tooltipText: "Stop playback"
                      onClicked: root.stopPlayback()
                    }
                  }
                  Row {
                    width: parent.width
                    spacing: Style.space(6)
                    Button {
                      width: (parent.width - Style.space(6)) / 2
                      text: "Player"
                      iconText: ""
                      bordered: true
                      foreground: root.panelForeground
                      accent: Color.accent
                      fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                      tooltipText: "Open in default video player"
                      onClicked: root.playExternal(root.nowUrl)
                    }
                    Button {
                      width: (parent.width - Style.space(6)) / 2
                      text: "mpv"
                      iconText: "⛶"
                      bordered: true
                      foreground: root.panelForeground
                      accent: Color.accent
                      fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                      tooltipText: "Open fullscreen in mpv"
                      onClicked: root.playVideoMpv(root.nowUrl)
                    }
                  }
                  Row {
                    width: parent.width
                    Button {
                      width: parent.width
                      text: "Subtitles (whisper)"
                      iconText: "󰈙"
                      bordered: true
                      foreground: root.panelForeground
                      accent: Color.accent
                      fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                      tooltipText: "Transcribe this video to .srt"
                      onClicked: root.transcribe(root.nowTitle, root.nowUrl)
                    }
                  }
                }
              }
            }
            ListView {
              id: resultsList
              width: root.nowTitle !== "" ? parent.width - Style.space(264) - Style.space(8) : parent.width
              height: Math.min(Style.space(420), Math.max(Style.space(72), contentHeight))
            interactive: contentHeight > height
            clip: true
            model: resultsModel
            spacing: Style.space(6)
            delegate: Rectangle {
              required property string title
              required property string channel
              required property string duration
              required property string url
              required property string thumb
              required property int index
              width: resultsList.width
              height: Style.space(116)
              radius: Style.cornerRadius
              color: rowMouse.containsMouse ? Qt.rgba(root.panelForeground.r, root.panelForeground.g, root.panelForeground.b, 0.10) : Qt.rgba(root.panelForeground.r, root.panelForeground.g, root.panelForeground.b, 0.04)
              border.width: 1
              border.color: rowMouse.containsMouse ? Color.accent : "transparent"
              Row {
                anchors.fill: parent
                anchors.margins: Style.space(6)
                spacing: Style.space(8)
                Rectangle {
                  width: Style.space(104)
                  height: Style.space(66)
                  radius: Style.space(6)
                  color: Qt.rgba(root.panelForeground.r, root.panelForeground.g, root.panelForeground.b, 0.12)
                  clip: true
                  Image {
                    anchors.fill: parent
                    source: thumb
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                  }
                  Text {
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.margins: 3
                    text: " " + duration + " "
                    textFormat: Text.PlainText
                    color: "white"
                    font.pixelSize: Style.font.caption
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    Rectangle {
                      anchors.fill: parent
                      color: "black"
                      opacity: 0.65
                      z: -1
                    }
                  }
                }
                Column {
                  width: parent.width - Style.space(104) - Style.space(116)
                  spacing: Style.space(2)
                  anchors.verticalCenter: parent.verticalCenter
                  Text {
                    width: parent.width
                    text: title
                    textFormat: Text.PlainText
                    color: root.panelForeground
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.body
                    font.bold: true
                    elide: Text.ElideRight
                    maximumLineCount: 2
                    wrapMode: Text.WordWrap
                  }
                  Text {
                    width: parent.width
                    text: channel
                    textFormat: Text.PlainText
                    color: Qt.darker(root.panelForeground, 1.4)
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideRight
                  }
                }
                Column {
                  spacing: Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                  Button {
                    width: Style.space(104)
                    text: (url === root.nowUrl && root.previewPlaying && !root.previewPaused) ? "Pause" : "Watch"
                    iconText: (url === root.nowUrl && root.previewPlaying && !root.previewPaused) ? "" : ""
                    bordered: true
                    selected: url === root.nowUrl && root.previewPlaying
                    foreground: root.panelForeground
                    accent: Color.accent
                    fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                    tooltipText: (url === root.nowUrl && root.previewPlaying && !root.previewPaused) ? "Pause this video" : "Watch inside the plugin"
                    onClicked: root.playVideo(title, url)
                  }
                  Button {
                    width: Style.space(104)
                    text: "Download"
                    iconText: ""
                    bordered: true
                    foreground: root.panelForeground
                    accent: Color.accent
                    fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                    tooltipText: "Queue for download"
                    onClicked: root.queueDownload(title, url)
                  }
                  Button {
                    width: Style.space(104)
                    text: "Subs"
                    iconText: "󰈙"
                    bordered: true
                    foreground: root.panelForeground
                    accent: Color.accent
                    fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                    tooltipText: "Transcribe to .srt with local whisper"
                    onClicked: root.transcribe(title, url)
                  }
                }
              }
              MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.NoButton
              }
            }
            }
          }
        }

        // ---- DOWNLOADS TAB ----
        Column {
          visible: root.tab === "downloads"
          width: parent.width
          spacing: Style.space(6)
          Row {
            width: parent.width
            spacing: Style.space(8)
            Button {
              text: "Open folder"
              iconText: ""
              bordered: true
              foreground: root.panelForeground
              accent: Color.accent
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              tooltipText: "Open download folder"
              onClicked: root.openDownloadFolder()
            }
            Button {
              visible: root.downloading
              text: "Cancel all"
              iconText: ""
              foreground: root.panelForeground
              accent: Color.accent
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              onClicked: root.cancelDownload()
            }
            Text {
              visible: !root.downloading && dlQueueModel.count === 0 && historyModel.count === 0
              text: "Queue empty — add from Search or paste a URL."
              color: Qt.darker(root.panelForeground, 1.5)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
              font.italic: true
              anchors.verticalCenter: parent.verticalCenter
            }
          }
          Text {
            visible: dlQueueModel.count > 0
            text: "UP NEXT (" + dlQueueModel.count + ")"
            color: Qt.darker(root.panelForeground, 1.4)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: true
          }
          ListView {
            visible: dlQueueModel.count > 0
            width: parent.width
            height: Math.min(Style.space(140), Math.max(Style.space(40), contentHeight))
            interactive: contentHeight > height
            clip: true
            model: dlQueueModel
            spacing: Style.space(4)
            delegate: Rectangle {
              required property string title
              required property int index
              width: parent.width
              height: Style.space(40)
              radius: Style.cornerRadius
              color: Qt.rgba(root.panelForeground.r, root.panelForeground.g, root.panelForeground.b, 0.06)
              Row {
                anchors.fill: parent
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(6)
                spacing: Style.space(6)
                Text {
                  width: parent.width - Style.space(52)
                  text: (index + 1) + ". " + title
                  textFormat: Text.PlainText
                  color: root.panelForeground
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                  anchors.verticalCenter: parent.verticalCenter
                }
                Button {
                  width: Style.space(40)
                  text: ""
                  iconText: ""
                  foreground: root.panelForeground
                  accent: Color.accent
                  fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                  tooltipText: "Remove from queue"
                  onClicked: root.removeQueued(index)
                }
              }
            }
          }
          Row {
            visible: historyModel.count > 0
            width: parent.width
            spacing: Style.space(8)
            Text {
              width: parent.width - Style.space(150)
              text: "COMPLETED"
              color: Qt.darker(root.panelForeground, 1.4)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
              anchors.verticalCenter: parent.verticalCenter
            }
            Button {
              width: Style.space(142)
              text: "Clear all"
              iconText: ""
              foreground: root.panelForeground
              accent: Color.accent
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              tooltipText: "Clear completed list"
              onClicked: root.clearHistory()
            }
          }
          ListView {
            visible: historyModel.count > 0
            width: parent.width
            height: Math.min(Style.space(160), Math.max(Style.space(56), contentHeight))
            interactive: contentHeight > height
            clip: true
            model: historyModel
            spacing: Style.space(4)
            delegate: Rectangle {
              required property string title
              required property string detail
              required property int index
              width: parent.width
              height: Style.space(56)
              radius: Style.cornerRadius
              color: Qt.rgba(root.panelForeground.r, root.panelForeground.g, root.panelForeground.b, 0.05)
              Row {
                anchors.fill: parent
                anchors.margins: Style.space(6)
                spacing: Style.space(6)
                Column {
                  width: parent.width - Style.space(104)
                  spacing: 0
                  anchors.verticalCenter: parent.verticalCenter
                  Text {
                    width: parent.width
                    text: "✓ " + title
                    textFormat: Text.PlainText
                    color: root.panelForeground
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideRight
                  }
                  Text {
                    width: parent.width
                    text: detail
                    textFormat: Text.PlainText
                    color: Qt.darker(root.panelForeground, 1.5)
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.caption
                  }
                }
                Button {
                  width: Style.space(92)
                  text: "Delete"
                  iconText: ""
                  bordered: true
                  foreground: root.panelForeground
                  accent: Color.accent
                  fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                  tooltipText: "Delete entry + downloaded files"
                  onClicked: root.deleteHistory(index)
                }
              }
            }
          }
        }

        // ---- SETTINGS TAB (scrollable) ----
        Flickable {
          id: settingsFlick
          visible: root.tab === "settings"
          width: parent.width
          height: Math.min(settingsCol.implicitHeight, Style.space(520))
          contentWidth: width
          contentHeight: settingsCol.implicitHeight
          clip: true
          interactive: contentHeight > height
          boundsBehavior: Flickable.StopAtBounds
          Column {
            id: settingsCol
            width: settingsFlick.width
            spacing: Style.space(8)
          Text {
            text: "DOWNLOAD LOCATION"
            color: Qt.darker(root.panelForeground, 1.4)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: true
          }
          Row {
            width: parent.width
            spacing: Style.space(8)
            TextField {
              id: dirField
              width: parent.width - Style.space(88)
              text: root.downloadDir
              foreground: root.panelForeground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              onEditingFinished: {
                root.downloadDir = text;
                root.persistSettings({ downloadDir: text });
              }
            }
            Button {
              width: Style.space(80)
              text: "Save"
              iconText: ""
              bordered: true
              foreground: root.panelForeground
              accent: Color.accent
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              onClicked: {
                root.downloadDir = dirField.text;
                root.persistSettings({ downloadDir: dirField.text });
                root.statusLine = "Download folder: " + dirField.text;
              }
            }
          }
          Dropdown {
            width: parent.width
            label: "Video quality"
            value: root.quality
            options: Model.qualityOptions()
            foreground: root.panelForeground
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            onChanged: function(v) {
              root.quality = v;
              root.persistSettings({ quality: v });
            }
          }
          Row {
            width: parent.width
            spacing: Style.space(8)
            Dropdown {
              width: (parent.width - Style.space(8)) / 2
              label: "Audio format"
              value: root.audioFormat
              options: Model.audioFormatOptions()
              foreground: root.panelForeground
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              onChanged: function(v) {
                root.audioFormat = v;
                root.persistSettings({ audioFormat: v });
              }
            }
            Dropdown {
              width: (parent.width - Style.space(8)) / 2
              label: "Video container"
              value: root.videoFormat
              options: Model.videoContainerOptions()
              foreground: root.panelForeground
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              onChanged: function(v) {
                root.videoFormat = v;
                root.persistSettings({ videoFormat: v });
              }
            }
          }
          Dropdown {
            width: parent.width
            label: "Results per search"
            value: root.maxResults
            options: Model.maxResultsOptions()
            foreground: root.panelForeground
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            onChanged: function(v) {
              root.maxResults = v;
              root.persistSettings({ maxResults: v });
            }
          }
          Dropdown {
            width: parent.width
            label: "Browser cookies"
            value: root.cookiesBrowser
            options: Model.cookiesBrowserOptions()
            foreground: root.panelForeground
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            onChanged: function(v) {
              root.cookiesBrowser = v;
              root.persistSettings({ cookiesBrowser: v });
            }
          }
          Text {
            width: parent.width
            text: "Cookies das settings do navegador (yt-dlp --cookies-from-browser) para passar no check de bot do YouTube."
            color: Qt.darker(root.panelForeground, 1.5)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
          Toggle {
            width: parent.width
            label: "Playlist mode"
            description: "ON downloads full playlists, OFF single videos only"
            checked: root.playlistMode === "playlist"
            foreground: root.panelForeground
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            onClicked: {
              var next = root.playlistMode === "playlist" ? "single" : "playlist";
              root.playlistMode = next;
              root.persistSettings({ playlistMode: next });
            }
          }
          Toggle {
            width: parent.width
            label: "Show video picture"
            description: "OFF keeps a tiny audio-style player"
            checked: root.showVideo
            foreground: root.panelForeground
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            onClicked: {
              root.showVideo = !root.showVideo;
              root.persistSettings({ showVideo: root.showVideo });
            }
          }
          Text {
            text: "AUDIO TRACK & SUBTITLES"
            color: Qt.darker(root.panelForeground, 1.4)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: true
          }
          Dropdown {
            width: parent.width
            label: "Audio track (dub)"
            value: root.audioLang
            options: Model.audioLangOptions()
            foreground: root.panelForeground
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            onChanged: function(v) {
              root.audioLang = v;
              root.persistSettings({ audioLang: v });
            }
          }
          Dropdown {
            width: parent.width
            label: "Subtitles (native)"
            value: root.subLangs
            options: Model.subLangsOptions()
            foreground: root.panelForeground
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            onChanged: function(v) {
              root.subLangs = v;
              root.persistSettings({ subLangs: v });
            }
          }
          Toggle {
            width: parent.width
            label: "Embed subtitles"
            description: "ON embeds into the video (forces MKV); OFF saves a .srt beside it"
            checked: root.embedSubs
            foreground: root.panelForeground
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            onClicked: {
              root.embedSubs = !root.embedSubs;
              root.persistSettings({ embedSubs: root.embedSubs });
            }
          }
          Text {
            text: "TRANSCRIPTION (WHISPER)"
            color: Qt.darker(root.panelForeground, 1.4)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: true
          }
          Dropdown {
            width: parent.width
            label: "Engine"
            value: root.whisperEngine
            options: Model.whisperEngineOptions()
            foreground: root.panelForeground
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            onChanged: function(v) {
              root.whisperEngine = v;
              root.persistSettings({ whisperEngine: v });
            }
          }
          Dropdown {
            width: parent.width
            label: "Transcription language"
            value: root.whisperLang
            options: Model.transcribeLangOptions()
            foreground: root.panelForeground
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            onChanged: function(v) {
              root.whisperLang = v;
              root.persistSettings({ whisperLang: v });
            }
          }
          Dropdown {
            width: parent.width
            label: "Local model"
            value: root.whisperModel
            options: Model.whisperModelOptions()
            foreground: root.panelForeground
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            onChanged: function(v) {
              root.whisperModel = v;
              root.persistSettings({ whisperModel: v });
            }
          }
          Row {
            width: parent.width
            spacing: Style.space(8)
            TextField {
              id: whisperCmdField
              width: parent.width - Style.space(88)
              text: root.whisperCmd
              foreground: root.panelForeground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              placeholderText: "auto"
              onEditingFinished: {
                root.whisperCmd = text;
                root.persistSettings({ whisperCmd: text });
              }
            }
            Button {
              width: Style.space(80)
              text: "Save"
              iconText: ""
              bordered: true
              foreground: root.panelForeground
              accent: Color.accent
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              onClicked: {
                root.whisperCmd = whisperCmdField.text;
                root.persistSettings({ whisperCmd: whisperCmdField.text });
                root.statusLine = "Whisper command saved.";
              }
            }
          }
          Text {
            width: parent.width
            text: "'auto' runs whisper-cli with your voxtype GGML models. Custom template: {wav} {input} {dir} {lang}."
            color: Qt.darker(root.panelForeground, 1.5)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
          Row {
            visible: root.whisperEngine === "openai"
            width: parent.width
            spacing: Style.space(8)
            Dropdown {
              width: (parent.width - Style.space(8)) / 2
              label: "API model"
              value: root.whisperApiModel
              options: Model.whisperApiModelOptions()
              foreground: root.panelForeground
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              onChanged: function(v) {
                root.whisperApiModel = v;
                root.persistSettings({ whisperApiModel: v });
              }
            }
            TextField {
              id: keyEnvField
              width: (parent.width - Style.space(8)) / 2
              text: root.whisperKeyEnv
              foreground: root.panelForeground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              placeholderText: "OPENAI_API_KEY"
              onEditingFinished: {
                root.whisperKeyEnv = text;
                root.persistSettings({ whisperKeyEnv: text });
              }
            }
          }
          Row {
            width: parent.width
            spacing: Style.space(8)
            Button {
              text: "Check dependencies"
              iconText: ""
              bordered: true
              foreground: root.panelForeground
              accent: Color.accent
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              onClicked: root.checkDeps()
            }
            Button {
              text: "Open folder"
              iconText: ""
              foreground: root.panelForeground
              accent: Color.accent
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              onClicked: root.openDownloadFolder()
            }
            Button {
              text: "Clear cache"
              iconText: ""
              foreground: root.panelForeground
              accent: Color.accent
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              tooltipText: "Delete cached preview videos"
              onClicked: root.clearVideoCache()
            }
          }
          Text {
            id: depText
            width: parent.width
            text: "yt-dlp + mpv + ffmpeg required. Click check."
            color: Qt.darker(root.panelForeground, 1.4)
            font.family: "monospace"
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
          }
        }
      }
    }
  }
}
