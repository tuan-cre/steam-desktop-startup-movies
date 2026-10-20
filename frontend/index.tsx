import {
    definePlugin,
    routerHook,
    PanelSection,
    PanelSectionRow,
    DialogButton,
    Dropdown,
    Millennium,
    EUIMode
} from "@steambrew/client";

import React from "react";

const OVERLAY_ID = "StartupMovieOverlay";
const HIDE_STYLE_ID = "startup-movies-hide";

// Inline pre-hide stylesheet, injected from the bundle itself.
//
// Millennium's add_browser_css/add_browser_js serve hook paths from
// <millennium>/themes/ (src/engine/http_hooks.cc:298-301 +
// plugin_loader.cc:677-678), never from the plugin directory, so the old
// `millennium.add_browser_css("frontend/steam-hide.css")` call silently
// 404'd ("https://millennium.host/v1/themes/frontend/steam-hide.js" in the
// webhelper log) and the pre-hide never applied. Serving it needs a path
// relative to themes/ on Linux, so inject the rules directly instead.
//
// `visibility` rather than `opacity`: global components (this overlay)
// render inside Steam's app root (router-hook.tsx), and an ancestor's
// opacity:0 is a compositing group that no child can escape. visibility is
// inherited but overridable, so the overlay can re-enable itself.
function hideSteamUI() {
    if (document.getElementById(HIDE_STYLE_ID)) return;
    const style = document.createElement("style");
    style.id = HIDE_STYLE_ID;
    style.textContent =
        "body { visibility: hidden !important; }\n" +
        "#" + OVERLAY_ID + ", #" + OVERLAY_ID + " * { visibility: visible !important; }";
    (document.head || document.documentElement).appendChild(style);
}

function showSteamUI() {
    document.getElementById(HIDE_STYLE_ID)?.remove();
}

// Hide as early as possible: the bundle is evaluated before React mounts.
hideSteamUI();

// Failsafe: never leave Steam's UI hidden when the overlay isn't on screen
// (module error, non-desktop UI mode). Checks the DOM rather than module
// state so it still works if the rest of this module failed to evaluate.
setTimeout(() => {
    if (!document.getElementById(OVERLAY_ID)) showSteamUI();
}, 5000);

const OBJECT_FIT_KEY = "startup-movies-object-fit";
const MOVIE_KEY = "startup-movies-selected";
const TRANSITION_KEY = "startup-movies-transition";
const MODE_KEY = "startup-movies-mode";
const AUDIO_KEY = "startup-movies-audio";

function readOption<T extends string>(key: string, options: readonly T[], fallback: T): T {
    const value = localStorage.getItem(key);
    return options.find(option => option === value) || fallback;
}

let _overlayPlay: ((url: string) => void) | null = null;
let _pendingPlayUrl: string | null = null;
let _pendingNoMovies = false;
let _objectFit = readOption(OBJECT_FIT_KEY, ["contain", "cover", "fill"], "contain");
let _onObjectFitChange: ((v: "contain" | "cover" | "fill") => void) | null = null;
let _setBlackScreen: ((v: boolean) => void) | null = null;
let _transition = readOption(TRANSITION_KEY, ["fade", "none"], "fade");
let _mode = readOption(MODE_KEY, ["default", "shuffle"], "default");
let _onTransitionChange: ((v: "fade" | "none") => void) | null = null;
// Audio defaults ON (Steam Deck behavior); explicit Off is respected.
let _audioEnabled: boolean = localStorage.getItem(AUDIO_KEY) !== "false";
let _onAudioChange: ((v: boolean) => void) | null = null;

async function callBackend(method: string, params: any = {}) {
    try {
        let result = await Millennium.callServerMethod(method, params);
        if (typeof result === "string") {
            try { result = JSON.parse(result); } catch {}
        }
        return result;
    } catch {
        return null;
    }
}

// Best-effort: mirror important errors to the backend log. Never throws.
function logToBackend(message: string) {
    try {
        const p = callBackend("log_message", { message: "[frontend] " + message });
        if (p && (p as any).catch) (p as Promise<void>).catch(() => {});
    } catch {}
}

let _cachedMovies: any[] | null = null;
let _moviesPromise: Promise<any[]> | null = null;

async function loadMovies(force = false) {
    if (_cachedMovies && !force) return _cachedMovies;
    // Startup fires tryStartupPlayback + Panel concurrently; share one
    // in-flight request instead of paying the IPC twice.
    if (_moviesPromise && !force) return _moviesPromise;
    if (force) {
        _cachedMovies = null;
        _moviesPromise = null;
        // Ask backend to rescan (falls back to cached list on older backends)
        const refreshed = await callBackend("refresh_movies");
        if (Array.isArray(refreshed)) {
            _cachedMovies = refreshed;
            return _cachedMovies;
        }
    }
    _moviesPromise = (async () => {
        const result = await callBackend("get_movies");
        _cachedMovies = Array.isArray(result) ? result : [];
        return _cachedMovies;
    })();
    try {
        return await _moviesPromise;
    } finally {
        _moviesPromise = null;
    }
}

function formatSize(bytes: number): string {
    if (bytes < 1024) return bytes + " B";
    if (bytes < 1048576) return (bytes / 1024).toFixed(1) + " KB";
    if (bytes < 1073741824) return (bytes / 1048576).toFixed(1) + " MB";
    return (bytes / 1073741824).toFixed(1) + " GB";
}

// Starts muted for stock-policy compatibility; unmutes opportunistically
// after decode. Falls back to muted silently where autoplay blocks it.
function tryUnmute(video: HTMLVideoElement | null) {
    if (!video) return;
    try {
        video.muted = false;
        const p = video.play();
        if (p && (p as any).catch) (p as Promise<void>).catch(() => {
            video.muted = true;
        });
    } catch {
        video.muted = true;
    }
}

const overlayStyle: React.CSSProperties = {
    position: "fixed",
    inset: "0",
    width: "100vw",
    height: "100vh",
    background: "black",
    zIndex: "2147483647",
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    cursor: "pointer",
};

function StartupMovieOverlay() {
    const [videoUrl, setVideoUrl] = React.useState<string | null>(null);
    const [visible, setVisible] = React.useState(true);
    const [blackScreen, setBlackScreen] = React.useState(true);
    const [videoReady, setVideoReady] = React.useState(false);
    const [objectFit, setObjectFit] = React.useState(_objectFit);
    const [transition, setTransition] = React.useState(_transition);
    const [audioEnabled, setAudioEnabled] = React.useState(_audioEnabled);
    const videoRef = React.useRef<HTMLVideoElement>(null);
    const fadingRef = React.useRef(false);
    // Bumped for every new playback so a pending dismiss timeout (the fade)
    // can't tear down a movie that started in the meantime.
    const generationRef = React.useRef(0);
    const dismissTimerRef = React.useRef<ReturnType<typeof setTimeout> | null>(null);

    const cancelDismissTimer = React.useCallback(() => {
        if (dismissTimerRef.current) {
            clearTimeout(dismissTimerRef.current);
            dismissTimerRef.current = null;
        }
    }, []);

    const beginPlayback = React.useCallback((url: string) => {
        generationRef.current += 1;
        cancelDismissTimer();
        hideSteamUI();
        fadingRef.current = false;
        setVisible(true);
        setVideoReady(false);
        setVideoUrl(url);
    }, [cancelDismissTimer]);

    React.useEffect(() => {
        _overlayPlay = beginPlayback;
        _setBlackScreen = setBlackScreen;
        _onObjectFitChange = setObjectFit;
        _onTransitionChange = setTransition;
        _onAudioChange = setAudioEnabled;

        if (_pendingNoMovies) {
            setBlackScreen(false);
            showSteamUI();
            _pendingNoMovies = false;
        }
        if (_pendingPlayUrl) {
            beginPlayback(_pendingPlayUrl);
            _pendingPlayUrl = null;
        }

        return () => {
            cancelDismissTimer();
            _overlayPlay = null;
            _setBlackScreen = null;
            _onObjectFitChange = null;
            _onTransitionChange = null;
            _onAudioChange = null;
        };
    }, [beginPlayback, cancelDismissTimer]);

    const handleVideoReady = React.useCallback(() => {
        setVideoReady(true);
        if (_audioEnabled) tryUnmute(videoRef.current);
    }, []);

    // Hybrid: handle audio toggle while video is playing
    React.useEffect(() => {
        if (!videoRef.current || !videoUrl) return;
        if (!audioEnabled) {
            videoRef.current.muted = true;
        } else if (videoReady) {
            tryUnmute(videoRef.current);
        }
    }, [audioEnabled, videoReady, videoUrl]);

    const isFade = transition === "fade";
    const dismissTimeout = isFade ? 400 : 0;

    const dismiss = React.useCallback(() => {
        if (fadingRef.current) return;
        fadingRef.current = true;
        const gen = generationRef.current;
        setVisible(false);
        setBlackScreen(false);
        // Reveal Steam immediately so the fade cross-fades to the real UI
        // instead of fading to black and popping the UI in afterwards.
        showSteamUI();
        cancelDismissTimer();
        dismissTimerRef.current = setTimeout(() => {
            dismissTimerRef.current = null;
            // A new preview/startup began during the fade: leave its video
            // alone.
            if (gen !== generationRef.current) return;
            if (videoRef.current) {
                videoRef.current.pause();
                videoRef.current.removeAttribute("src");
                videoRef.current.load();
            }
            setVideoUrl(null);
            setVideoReady(false);
            fadingRef.current = false;
        }, dismissTimeout);
    }, [dismissTimeout, cancelDismissTimer]);

    // Unmount entirely when idle (no video and no black screen) so the
    // fullscreen layer can't intercept or disturb Steam/Millennium
    // context menus, hover states, or hit-testing after dismissal.
    if (!videoUrl && !blackScreen) {
        return null;
    }

    return (
        <div
        id={OVERLAY_ID}
        onClick={dismiss}
        style={{
            ...overlayStyle,
            opacity: ((videoUrl && visible) || (blackScreen && visible)) ? 1 : 0,
            pointerEvents: ((videoUrl && visible) || (blackScreen && visible)) ? "auto" : "none",
            transition: transition === "fade" ? "opacity 0.4s ease" : "none",
        }}
        >
        {videoUrl && (
        <video
        ref={videoRef}
        src={videoUrl}
        autoPlay
        muted
        playsInline
        preload="auto"
        style={{ width: "100%", height: "100%", objectFit, opacity: videoReady ? 1 : 0, transition: transition === "fade" ? "opacity 0.5s ease" : "none" }}
        onEnded={dismiss}
        onError={dismiss}
        onLoadedData={handleVideoReady}
        onCanPlay={handleVideoReady}
        />
        )}
        </div>
    );
}

routerHook.addGlobalComponent(
    OVERLAY_ID,
    StartupMovieOverlay,
    EUIMode.Desktop
);

function playMovie(url: string) {
    if (_overlayPlay) _overlayPlay(url);
    else _pendingPlayUrl = url;
}

// Windows serves embedded bytes (no movie.url in the list): fetch the
// selected file on demand and hand <video> a Blob URL (cheaper than a
// giant data: URL). Linux URLs come straight from FTP.
// Mirrors SINGLE_SHOT_MAX_BYTES / CHUNK_RAW_BYTES in backend/main.lua.
const SINGLE_SHOT_MAX_BYTES = 5 * 1024 * 1024;
const CHUNK_RAW_BYTES = 3 * 1024 * 1024;
const TOTAL_MAX_BYTES = 64 * 1024 * 1024;

const BLOB_VIDEO_MIME: Record<string, string> = {
    webm: "video/webm",
    mp4: "video/mp4",
    m4v: "video/mp4",
    mov: "video/quicktime",
    mkv: "video/x-matroska",
    ogv: "video/ogg",
    ogg: "video/ogg",
};

function mimeForFile(name: string): string {
    const ext = name.split(".").pop()?.toLowerCase() || "";
    return BLOB_VIDEO_MIME[ext] || "video/webm";
}

function b64ToBytes(b64: string): Uint8Array {
    const bin = atob(b64);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
}

// One live Blob URL at a time; revoked on replace so repeated
// previews/startups don't leak object URLs.
let _blobUrl: string | null = null;
function toBlobUrl(parts: Uint8Array[], mime: string): string {
    if (_blobUrl) {
        try { URL.revokeObjectURL(_blobUrl); } catch {}
        _blobUrl = null;
    }
    _blobUrl = URL.createObjectURL(new Blob(parts as BlobPart[], { type: mime }));
    return _blobUrl;
}

async function resolvePlayUrl(movie: any): Promise<string | null> {
    if (movie?.url) return movie.url;
    if (!movie?.name) return null;
    const mime = mimeForFile(movie.name);
    const size = typeof movie.size === "number" ? movie.size : 0;
    if (size > TOTAL_MAX_BYTES) {
        const msg = `refusing '${movie.name}' (${formatSize(size)} > 64 MB cap)`;
        console.warn("[StartupMovies] " + msg);
        logToBackend(msg);
        return null;
    }
    try {
        // Fast path: small files in one IPC roundtrip.
        if (!size || size <= SINGLE_SHOT_MAX_BYTES) {
            const d: any = await callBackend("get_movie_data", { name: movie.name });
            if (typeof d === "string" && d.startsWith("data:")) {
                return toBlobUrl([b64ToBytes(d.slice(d.indexOf(",") + 1))], mime);
            }
            if (size && size <= SINGLE_SHOT_MAX_BYTES) return null;
            // Unknown size with failed single-shot: fall through to chunks.
        }
        // Chunked path: sequential slices, each far under the IPC
        // return cap. Array args keep positional order on every backend.
        const parts: Uint8Array[] = [];
        let offset = 0;
        let total = 0;
        while (true) {
            const len = size ? Math.min(CHUNK_RAW_BYTES, size - offset) : CHUNK_RAW_BYTES;
            if (len <= 0) break;
            const c: any = await callBackend("get_movie_chunk", [movie.name, offset, len] as any);
            if (typeof c !== "string" || !c) {
                // The backend returns nil past EOF. With an unknown size we
                // request a full slice even at EOF, so a miss after bytes
                // were read means "done", not "failed" — otherwise a file
                // that is an exact multiple of CHUNK_RAW_BYTES would be
                // discarded in full.
                if (offset > 0) break;
                return null;
            }
            const bytes = b64ToBytes(c);
            // Guard the unknown-size case (size === 0 skips the cap check
            // above): never buffer past the same 64 MB ceiling the backend
            // enforces, no matter what the list claimed.
            total += bytes.length;
            if (total > TOTAL_MAX_BYTES) {
                const msg = `refusing '${movie.name}' (> 64 MB cap during chunked read)`;
                console.warn("[StartupMovies] " + msg);
                logToBackend(msg);
                return null;
            }
            parts.push(bytes);
            offset += bytes.length;
            if (bytes.length < len) break; // short read = EOF
        }
        if (!parts.length) return null;
        return toBlobUrl(parts, mime);
    } catch (e) {
        logToBackend("resolvePlayUrl failed: " + String((e as any)?.message || e));
        return null;
    }
}

async function tryStartupPlayback() {
    const movies = await loadMovies();
    if (!movies.length) {
        if (_setBlackScreen) {
            _setBlackScreen(false);
        } else {
            _pendingNoMovies = true;
        }
        showSteamUI();
        return;
    }

    let movie: any;
    if (_mode === "shuffle") {
        movie = movies[Math.floor(Math.random() * movies.length)];
    } else {
        const saved = localStorage.getItem(MOVIE_KEY);
        movie = saved ? movies.find((m: any) => m.name === saved) : movies[0];
        if (!movie && movies.length) {
            console.warn("[StartupMovies] Saved movie '" + saved + "' not found - falling back to " + movies[0].name);
            movie = movies[0];
        }
    }
    const url = movie ? await resolvePlayUrl(movie) : null;
    if (url) {
        playMovie(url);
        return;
    }
    if (_setBlackScreen) _setBlackScreen(false);
    else _pendingNoMovies = true;
    showSteamUI();
}

tryStartupPlayback().catch((e) => {
    const msg = "startup playback failed: " + String(e?.message || e);
    console.error("[StartupMovies] " + msg);
    logToBackend(msg);
    // The pre-hide is already applied at module scope; make sure a failed
    // startup doesn't leave Steam's UI invisible.
    showSteamUI();
});

function Panel() {
    const [movies, setMovies] = React.useState<any[]>([]);
    const [selected, setSelected] = React.useState(localStorage.getItem(MOVIE_KEY) || "");
    const [objectFit, setObjectFit] = React.useState(_objectFit);
    const [transition, setTransition] = React.useState(_transition);
    const [mode, setMode] = React.useState(_mode);
    const [audioEnabled, setAudioEnabled] = React.useState(_audioEnabled);
    const [status, setStatus] = React.useState<any>(null);
    const [refreshing, setRefreshing] = React.useState(false);

    React.useEffect(() => {
        loadMovies().then(setMovies);
        callBackend("get_status").then(setStatus);
    }, []);

    // Pin selection to a valid movie once the list loads. Without this the
    // Dropdown can render with a stale/empty value while playback falls back
    // to movies[0], making it look like "changing movies does nothing".
    React.useEffect(() => {
        if (movies.length && (!selected || !movies.find((m: any) => m.name === selected))) {
            const first = movies[0].name;
            setSelected(first);
            localStorage.setItem(MOVIE_KEY, first);
        }
    }, [movies, selected]);

    const handleMovie = (v: { data: string }) => {
        setSelected(v.data);
        localStorage.setItem(MOVIE_KEY, v.data);
    };

    const handleObjectFit = (v: { data: string }) => {
        const val = v.data as "contain" | "cover" | "fill";
        setObjectFit(val);
        _objectFit = val;
        localStorage.setItem(OBJECT_FIT_KEY, val);
        _onObjectFitChange?.(val);
    };

    const handleTransition = (v: { data: string }) => {
        const val = v.data as "fade" | "none";
        setTransition(val);
        _transition = val;
        localStorage.setItem(TRANSITION_KEY, val);
        _onTransitionChange?.(val);
    };

    const handleMode = (v: { data: string }) => {
        const val = v.data as "default" | "shuffle";
        setMode(val);
        _mode = val;
        localStorage.setItem(MODE_KEY, val);
    };

    const handleAudio = (v: { data: string }) => {
        const val = v.data === "true";
        setAudioEnabled(val);
        _audioEnabled = val;
        localStorage.setItem(AUDIO_KEY, String(val));
        _onAudioChange?.(val);
    };

    const selectedMovie = movies.find((m: any) => m.name === selected);
    const [thumbData, setThumbData] = React.useState<string | null>(null);
    const [thumbPending, setThumbPending] = React.useState(false);
    // Backend generates missing thumbnails asynchronously (ffmpeg runs in
    // the background during the movie scan), so the list may not carry one
    // yet. Attempts per movie name; survives rescan-triggered re-renders.
    const thumbAttempts = React.useRef<Record<string, number>>({});

    // Linux thumbs arrive as URLs in the list; Windows thumbs resolve on
    // demand as embedded data (the list only carries has_thumb).
    React.useEffect(() => {
        let cancelled = false;
        let timer: ReturnType<typeof setTimeout> | null = null;
        setThumbData(null);
        setThumbPending(false);
        if (selectedMovie?.thumb) {
            setThumbData(selectedMovie.thumb);
        } else if (selectedMovie?.has_thumb) {
            setThumbPending(true);
            callBackend("get_thumb_data", { name: selectedMovie.name }).then((d: any) => {
                if (cancelled) return;
                if (typeof d === "string" && d.startsWith("data:")) setThumbData(d);
                setThumbPending(false);
            });
        } else if (selectedMovie && status?.has_ffmpeg) {
            const seen = thumbAttempts.current[selectedMovie.name] ?? 0;
            if (seen < 4) {
                setThumbPending(true);
                timer = setTimeout(async () => {
                    thumbAttempts.current[selectedMovie.name] = seen + 1;
                    if (!cancelled) setMovies(await loadMovies(true));
                }, 2000);
            }
        }
        return () => { cancelled = true; if (timer) clearTimeout(timer); };
    }, [selected, movies, status]);
    const thumbUrl = thumbData;
    let thumbNote = "No thumbnail";
    if (!status) thumbNote = "Loading…";
    else if (!status.has_ffmpeg) thumbNote = "No thumbnail — install ffmpeg";
    else if (thumbPending) thumbNote = "Generating thumbnail…";

    const previewSelected = async () => {
        const m = movies.find((mm: any) => mm.name === selected) || movies[0];
        const url = m ? await resolvePlayUrl(m) : null;
        if (url) playMovie(url);
    };

    const handleRefresh = async () => {
        setRefreshing(true);
        try {
            thumbAttempts.current = {};
            setMovies(await loadMovies(true));
            setStatus(await callBackend("get_status"));
        } finally {
            setRefreshing(false);
        }
    };

    const warnings: string[] = [];
    // Static note: Startup Location can't be auto-detected (modern Steam no
    // longer stores it in config.vdf), but Library is still required so the
    // Store doesn't render centered over the movie.
    const startupRequirement = {
        text: "Startup Location must be Library (Steam → Settings → Interface)",
        color: "#7eb0ff",
    };
    // The only reachable warning is the ffmpeg one (has_ffmpeg false).
    if (status && !status.has_ffmpeg) warnings.push("ffmpeg not found - thumbnails disabled");

    return (
        <>
        {warnings.length > 0 && (
            <PanelSection title="Status">
                <PanelSectionRow>
                    <div style={{ color: "#ff6b6b", fontSize: "12px", lineHeight: "1.5" }}>
                        {warnings.map((w, i) => <div key={i}>{w}</div>)}
                    </div>
                </PanelSectionRow>
            </PanelSection>
        )}
        <PanelSection title="Requirement">
            <PanelSectionRow>
                <div style={{ color: startupRequirement.color, fontSize: "12px", lineHeight: "1.5" }}>{startupRequirement.text}</div>
            </PanelSectionRow>
        </PanelSection>

        <PanelSection title="Movie">
            {movies.length > 0 ? (
            <PanelSectionRow>
                <Dropdown
                    rgOptions={movies.map(m => ({
                        label: `${m.name.replace(/\.[^.]+$/, "")} (${formatSize(m.size)})`,
                        data: m.name
                    }))}
                    selectedOption={selected}
                    onChange={handleMovie}
                />
            </PanelSectionRow>
            ) : (
            <PanelSectionRow>
                <div style={{ color: "#888", fontSize: "12px" }}>
                    No movies found. Place video files (.webm, .mp4, .mkv, .mov, …) in the plugin's movies/ folder.
                </div>
            </PanelSectionRow>
            )}

            {/* Thumbnail frame always renders while a movie is selected so the
                layout never jumps; status text fills in when no image yet. */}
            {movies.length > 0 && (
                <PanelSectionRow>
                    <div style={{ width: "100%", aspectRatio: "16 / 9", borderRadius: "4px", background: "#000", display: "flex", alignItems: "center", justifyContent: "center" }}>
                        {thumbUrl ? (
                            <img
                                src={thumbUrl}
                                style={{
                                    width: "100%",
                                    height: "100%",
                                    objectFit: "contain",
                                    borderRadius: "4px",
                                    display: "block"
                                }}
                            />
                        ) : (
                            <div style={{ color: "#888", fontSize: "12px", padding: "0 12px", textAlign: "center" }}>
                                {thumbNote}
                            </div>
                        )}
                    </div>
                </PanelSectionRow>
            )}

            {movies.length > 0 && (
            <PanelSectionRow>
                <div style={{ display: "flex", gap: "8px", width: "100%" }}>
                    <div style={{ flex: 1 }}>
                        <DialogButton onClick={previewSelected} style={{ width: "100%", borderRadius: "4px" }}>
                            Preview
                        </DialogButton>
                    </div>
                    <div style={{ flex: 1 }}>
                        <DialogButton onClick={handleRefresh} disabled={refreshing} style={{ width: "100%", borderRadius: "4px" }}>
                            {refreshing ? "Refreshing..." : "Refresh"}
                        </DialogButton>
                    </div>
                </div>
            </PanelSectionRow>
            )}
        </PanelSection>

        <PanelSection title="Video Fit">
            <PanelSectionRow>
                <Dropdown
                    rgOptions={[
                        { label: "Contain (letterbox)", data: "contain" },
                        { label: "Cover (crop)", data: "cover" },
                        { label: "Fill (stretch)", data: "fill" },
                    ]}
                    selectedOption={objectFit}
                    onChange={handleObjectFit}
                />
            </PanelSectionRow>
        </PanelSection>

        <PanelSection title="Transition">
            <PanelSectionRow>
                <Dropdown
                    rgOptions={[
                        { label: "Fade", data: "fade" },
                        { label: "None", data: "none" },
                    ]}
                    selectedOption={transition}
                    onChange={handleTransition}
                />
            </PanelSectionRow>
        </PanelSection>

        <PanelSection title="Playback Mode">
            <PanelSectionRow>
                <Dropdown
                    rgOptions={[
                        { label: "Static", data: "default" },
                        { label: "Shuffle", data: "shuffle" },
                    ]}
                    selectedOption={mode}
                    onChange={handleMode}
                />
            </PanelSectionRow>
        </PanelSection>

        <PanelSection title="Audio">
            <PanelSectionRow>
                <Dropdown
                    rgOptions={[
                        { label: "Off", data: "false" },
                        { label: "On", data: "true" },
                    ]}
                    selectedOption={String(audioEnabled)}
                    onChange={handleAudio}
                />
            </PanelSectionRow>
        </PanelSection>
        </>
    );
}

export default definePlugin(() => ({
    title: "Startup Movies",
    icon: <span>[M]</span>,
    content: <Panel />
}));
