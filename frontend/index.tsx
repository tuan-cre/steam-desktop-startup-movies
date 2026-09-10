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
const OBJECT_FIT_KEY = "startup-movies-object-fit";
const MOVIE_KEY = "startup-movies-selected";
const TRANSITION_KEY = "startup-movies-transition";
const MODE_KEY = "startup-movies-mode";
const AUDIO_KEY = "startup-movies-audio";

let _overlayPlay: ((url: string) => void) | null = null;
let _pendingPlayUrl: string | null = null;
let _pendingNoMovies = false;
let _objectFit: "contain" | "cover" | "fill" = (localStorage.getItem(OBJECT_FIT_KEY) as any) || "contain";
let _onObjectFitChange: ((v: "contain" | "cover" | "fill") => void) | null = null;
let _setBlackScreen: ((v: boolean) => void) | null = null;
let _transition: "fade" | "none" = (localStorage.getItem(TRANSITION_KEY) as any) || "fade";
let _mode: "default" | "shuffle" = (localStorage.getItem(MODE_KEY) as any) || "default";
let _onTransitionChange: ((v: "fade" | "none") => void) | null = null;
let _audioEnabled: boolean = localStorage.getItem(AUDIO_KEY) === "true";
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

async function loadMovies(force = false) {
    if (_cachedMovies && !force) return _cachedMovies;
    if (force) {
        _cachedMovies = null;
        // Ask backend to rescan (falls back to cached list on older backends)
        const refreshed = await callBackend("refresh_movies");
        if (Array.isArray(refreshed)) {
            _cachedMovies = refreshed;
            return _cachedMovies;
        }
    }
    const result = await callBackend("get_movies");
    _cachedMovies = Array.isArray(result) ? result : [];
    return _cachedMovies;
}

function formatSize(bytes: number): string {
    if (bytes < 1024) return bytes + " B";
    if (bytes < 1048576) return (bytes / 1024).toFixed(1) + " KB";
    return (bytes / 1048576).toFixed(1) + " MB";
}

// Try unmuting after decode when the autoplay flag allows it.
// Starts muted for stock-policy compatibility; falls back to muted silently.
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
    transition: "opacity 0.4s ease",
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

    React.useEffect(() => {
        requestAnimationFrame(() => {
            var bo = document.getElementById('millennium-black-overlay');
            if (bo) bo.remove();
            var prehide = document.getElementById('millennium-prehide');
            if (prehide) prehide.remove();
        });

        _overlayPlay = (url: string) => {
            setVisible(true);
            fadingRef.current = false;
            setVideoReady(false);
            setVideoUrl(url);
        };
        _setBlackScreen = setBlackScreen;
        _onObjectFitChange = setObjectFit;
        _onTransitionChange = setTransition;
        _onAudioChange = setAudioEnabled;

        if (_pendingNoMovies) {
            setBlackScreen(false);
            (window as any).__showSteamUI?.();
            _pendingNoMovies = false;
        }
        if (_pendingPlayUrl) {
            setVisible(true);
            fadingRef.current = false;
            setVideoReady(false);
            setVideoUrl(_pendingPlayUrl);
            _pendingPlayUrl = null;
        }

        return () => {
            _overlayPlay = null;
            _setBlackScreen = null;
            _onObjectFitChange = null;
            _onTransitionChange = null;
            _onAudioChange = null;
        };
    }, []);

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
        setVisible(false);
        setBlackScreen(false);
        setTimeout(() => {
            if (videoRef.current) {
                videoRef.current.pause();
                videoRef.current.removeAttribute("src");
                videoRef.current.load();
            }
            setVideoUrl(null);
            setVideoReady(false);
            fadingRef.current = false;
            (window as any).__showSteamUI?.();
        }, dismissTimeout);
    }, [dismissTimeout]);

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

// Windows serves embedded data (no movie.url in the list): fetch the
// selected file's bytes on demand. Linux URLs come straight from FTP.
async function resolvePlayUrl(movie: any): Promise<string | null> {
    if (movie?.url) return movie.url;
    if (movie?.name) {
        const d: any = await callBackend("get_movie_data", { name: movie.name });
        if (typeof d === "string" && d.startsWith("data:")) return d;
    }
    return null;
}

async function tryStartupPlayback() {
    const movies = await loadMovies();
    if (!movies.length) {
        if (_setBlackScreen) {
            _setBlackScreen(false);
        } else {
            _pendingNoMovies = true;
        }
        (window as any).__showSteamUI?.();
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
    if (movie?.url) {
        playMovie(movie.url);
    } else if (movie?.name) {
        const url = await resolvePlayUrl(movie);
        if (url) playMovie(url);
        else {
            if (_setBlackScreen) _setBlackScreen(false);
            else _pendingNoMovies = true;
            (window as any).__showSteamUI?.();
        }
    } else {
        if (_setBlackScreen) _setBlackScreen(false);
        else _pendingNoMovies = true;
        (window as any).__showSteamUI?.();
    }
}

tryStartupPlayback().catch((e) => {
    const msg = "startup playback failed: " + String(e?.message || e);
    console.error("[StartupMovies] " + msg);
    logToBackend(msg);
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

    // Linux thumbs arrive as URLs in the list; Windows thumbs resolve on
    // demand as embedded data (the list only carries has_thumb).
    React.useEffect(() => {
        let cancelled = false;
        setThumbData(null);
        if (selectedMovie?.thumb) {
            setThumbData(selectedMovie.thumb);
        } else if (selectedMovie?.has_thumb) {
            callBackend("get_thumb_data", { name: selectedMovie.name }).then((d: any) => {
                if (!cancelled && typeof d === "string" && d.startsWith("data:")) setThumbData(d);
            });
        }
        return () => { cancelled = true; };
    }, [selected, movies]);
    const thumbUrl = thumbData;

    const previewSelected = async () => {
        const m = movies.find((mm: any) => mm.name === selected) || movies[0];
        const url = m ? await resolvePlayUrl(m) : null;
        if (url) playMovie(url);
    };

    const handleRefresh = async () => {
        setRefreshing(true);
        try {
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

            {thumbUrl && (
                <PanelSectionRow>
                    <div style={{ display: "flex", justifyContent: "center", width: "100%" }}>
                        <img
                            src={thumbUrl}
                            style={{
                                width: "100%",
                                aspectRatio: "16 / 9",
                                objectFit: "contain",
                                borderRadius: "4px",
                                display: "block",
                                background: "#000"
                            }}
                        />
                    </div>
                </PanelSectionRow>
            )}

            {movies.length > 0 && (
            <PanelSectionRow>
                <div style={{ display: "flex", gap: "8px", width: "100%" }}>
                    <div style={{ flex: 1 }}>
                        <DialogButton onClick={previewSelected} style={{ width: "100%" }}>
                            Preview
                        </DialogButton>
                    </div>
                    <div style={{ flex: 1 }}>
                        <DialogButton onClick={handleRefresh} disabled={refreshing} style={{ width: "100%" }}>
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
