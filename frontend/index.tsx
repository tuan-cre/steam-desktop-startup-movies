import {
    definePlugin,
    routerHook,
    PanelSection,
    PanelSectionRow,
    Dropdown,
    Millennium,
    EUIMode
} from "@steambrew/client";

import React from "react";

const OVERLAY_ID = "StartupMovieOverlay";
const PLAYED_KEY = "startup-movies-played-this-session";
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

async function callBackend(method: string, args: any = {}) {
    try {
        let result = await Millennium.callServerMethod(method, args);
        if (typeof result === "string") {
            try { result = JSON.parse(result); } catch {}
        }
        return result;
    } catch {
        return null;
    }
}

async function logToBackend(msg: string) {
    try { await Millennium.callServerMethod("log_message", { message: msg }); } catch {}
}

const videoErrorToString = (v?: HTMLVideoElement) => {
    if (!v) return "no-video";
    let e = "";
    if (v.error) e += " code=" + v.error.code + " msg=" + (v.error.message || "");
    return "net=" + v.networkState + " ready=" + v.readyState + " paused=" + v.paused + " dur=" + (Number.isFinite(v.duration) ? v.duration.toFixed(2) : "NaN") + " w=" + v.videoWidth + "x" + v.videoHeight + e;
};

let _cachedMovies: any[] | null = null;

async function loadMovies() {
    if (_cachedMovies) return _cachedMovies;
    const result = await callBackend("get_movies");
    _cachedMovies = Array.isArray(result) ? result : [];
    return _cachedMovies;
}

function formatSize(bytes: number): string {
    if (bytes < 1024) return bytes + " B";
    if (bytes < 1048576) return (bytes / 1024).toFixed(1) + " KB";
    return (bytes / 1048576).toFixed(1) + " MB";
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
    isolation: "isolate",
    transform: "translateZ(0)",
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
        if (_audioEnabled && videoRef.current) {
            try {
                videoRef.current.muted = false;
                const p = videoRef.current.play();
                if (p && (p as any).catch) (p as Promise<void>).catch(() => {
                    if (videoRef.current) videoRef.current.muted = true;
                });
            } catch {}
        }
    }, []);

    // Hybrid: handle audio toggle while video is playing
    React.useEffect(() => {
        if (!videoRef.current || !videoUrl) return;
        if (!audioEnabled) {
            videoRef.current.muted = true;
        } else if (videoReady) {
            try {
                videoRef.current.muted = false;
                const p = videoRef.current.play();
                if (p && (p as any).catch) (p as Promise<void>).catch(() => {
                    if (videoRef.current) videoRef.current.muted = true;
                });
            } catch {
                if (videoRef.current) videoRef.current.muted = true;
            }
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

    const dbgLog = React.useCallback((what: string) => {
        logToBackend("DBG " + what + " url=" + (videoUrl || "none") + " " + videoErrorToString(videoRef.current || undefined));
    }, [videoUrl]);

    const handleVideoError = React.useCallback(() => {
        const v = videoRef.current;
        logToBackend("DBG video ERROR code=" + (v?.error?.code ?? "none") + " msg=" + (v?.error?.message || "none") + " " + videoErrorToString(v || undefined));
        dismiss();
    }, [dismiss]);

    React.useEffect(() => {
        if (!videoUrl) return;
        logToBackend("DBG playback-begin " + videoUrl);
        const t = window.setInterval(() => {
            const v = videoRef.current;
            if (!v) return;
            logToBackend("DBG state " + videoErrorToString(v));
        }, 3000);
        return () => window.clearInterval(t);
    }, [videoUrl]);

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
        ref={(el) => { videoRef.current = el; if (el) logToBackend("DBG video mount src=" + videoUrl + " " + videoErrorToString(el)); }}
        src={videoUrl}
        autoPlay
        muted
        playsInline
        style={{ width: "100%", height: "100%", objectFit, opacity: videoReady ? 1 : 0, transition: transition === "fade" ? "opacity 0.5s ease" : "none" }}
        onEnded={dismiss}
        onError={handleVideoError}
        onLoadedData={(e) => { dbgLog("loadeddata"); handleVideoReady(); }}
        onCanPlay={(e) => { dbgLog("canplay"); handleVideoReady(); }}
        onPlaying={(e) => { dbgLog("playing"); }}
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

    // Require Library as Startup Location — Store renders as a centered popup
    // that bleeds through the overlay (top/bottom of movie visible, Store in middle).
    try {
        const status = await callBackend("get_status");
        if (status && status.startup_is_library === false) {
            // Skip movie to avoid broken display; expose Steam UI immediately
            if (_setBlackScreen) _setBlackScreen(false);
            else _pendingNoMovies = true;
            (window as any).__showSteamUI?.();
            console.warn("[StartupMovies] Startup Location is '" + status.startup_raw + "' (not Library) — skipping movie to avoid Store overlay. Set Steam > Settings > Interface > Startup Location > Library");
            return;
        }
    } catch {}

    if (!sessionStorage.getItem(PLAYED_KEY)) {
        sessionStorage.setItem(PLAYED_KEY, "1");
    }

    let movie: any;
    if (_mode === "shuffle") {
        movie = movies[Math.floor(Math.random() * movies.length)];
    } else {
        const saved = localStorage.getItem(MOVIE_KEY);
        movie = saved ? movies.find((m: any) => m.name === saved) : movies[0];
    }
    if (movie?.url) {
        logToBackend("DBG chosen-movie name=" + (movie.name || "?") + " url=" + movie.url);
        playMovie(movie.url);
    } else {
        if (_setBlackScreen) _setBlackScreen(false);
        else _pendingNoMovies = true;
        (window as any).__showSteamUI?.();
    }
}

tryStartupPlayback();

function Panel() {
    const [movies, setMovies] = React.useState<any[]>([]);
    const [selected, setSelected] = React.useState(localStorage.getItem(MOVIE_KEY) || "");
    const [objectFit, setObjectFit] = React.useState(_objectFit);
    const [transition, setTransition] = React.useState(_transition);
    const [mode, setMode] = React.useState(_mode);
    const [audioEnabled, setAudioEnabled] = React.useState(_audioEnabled);
    const [status, setStatus] = React.useState<any>(null);

    React.useEffect(() => {
        loadMovies().then(setMovies);
        callBackend("get_status").then(setStatus);
    }, []);

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
    const thumbUrl = selectedMovie?.thumb || null;

    const warnings: string[] = [];
    let hybridInfo: string | null = null;
    let startupRequirement: { text: string; color: string } | null = null;
    if (status) {
        if (!status.ftp_serving) {
            if (!status.has_python) warnings.push("python3 not found - HTTP server unavailable");
            if (status.has_python && !status.server_running) warnings.push("HTTP server is not running");
        }
        if (!status.has_ffmpeg) warnings.push("ffmpeg not found - thumbnails disabled");
        if (status.has_autoplay_patch === false && audioEnabled) {
            hybridInfo = "Stock Millennium detected - audio uses muted-first fallback (no freeze)";
        } else if (status.has_autoplay_patch === true && audioEnabled) {
            hybridInfo = "Patched Millennium detected - native unmuted autoplay enabled";
        }
        if (status.ftp_serving && movies.length > 0) {
            hybridInfo = (hybridInfo ? hybridInfo + " | " : "") + "FTP VFS serving (no python)";
        }
        // Library requirement: Store as startup renders centered and shows through movie
        if (status.startup_is_library === false) {
            startupRequirement = {
                text: `Startup Location is "${status.startup_raw}" — Store will appear centered over the movie (only top/bottom visible). Fix: Steam → Settings → Interface → Startup Location → Library, then restart.`,
                color: "#ff6b6b",
            };
            warnings.push(`Startup Location is "${status.startup_raw}" — must be Library (Steam → Settings → Interface)`);
        } else if (status.startup_is_library === true) {
            startupRequirement = { text: "Startup Location: Library ✓ — movie will cover fullscreen", color: "#59BF40" };
        } else {
            startupRequirement = {
                text: "Requires Steam → Settings → Interface → Startup Location → Library (could not auto-detect — please verify manually)",
                color: "#7eb0ff",
            };
        }
    } else {
        startupRequirement = {
            text: "Requires Steam → Settings → Interface → Startup Location → Library (required so Store doesn't appear centered over the movie)",
            color: "#7eb0ff",
        };
    }

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
        {hybridInfo && (
            <PanelSection title="Compatibility">
                <PanelSectionRow>
                    <div style={{ color: "#7eb0ff", fontSize: "12px", lineHeight: "1.5" }}>{hybridInfo}</div>
                </PanelSectionRow>
            </PanelSection>
        )}
        {startupRequirement && (
            <PanelSection title="Requirement">
                <PanelSectionRow>
                    <div style={{ color: startupRequirement.color, fontSize: "12px", lineHeight: "1.5" }}>{startupRequirement.text}</div>
                </PanelSectionRow>
            </PanelSection>
        )}

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
                    No movies found. Place .webm or .mp4 files in the plugin's movies/ folder.
                </div>
            </PanelSectionRow>
            )}

            {thumbUrl && (
                <PanelSectionRow>
                    <div style={{ display: "flex", justifyContent: "center" }}>
                        <img
                            src={thumbUrl}
                            style={{
                                width: "200px",
                                height: "112px",
                                objectFit: "contain",
                                borderRadius: "4px",
                                display: "block"
                            }}
                        />
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

routerHook.addRoute("/startup-movies", Panel);

export default definePlugin(() => ({
    title: "Startup Movies",
    icon: <span>[M]</span>,
    content: <Panel />
}));
