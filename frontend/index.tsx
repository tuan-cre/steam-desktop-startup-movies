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

let _overlayPlay: ((url: string) => void) | null = null;
let _pendingPlayUrl: string | null = null;
let _objectFit: "contain" | "cover" | "fill" = (localStorage.getItem(OBJECT_FIT_KEY) as any) || "contain";
let _onObjectFitChange: ((v: "contain" | "cover" | "fill") => void) | null = null;
let _firstLoad = !sessionStorage.getItem(PLAYED_KEY);
let _setBlackScreen: ((v: boolean) => void) | null = null;

async function callBackend(method: string) {
    try {
        let result = await Millennium.callServerMethod(method, {});
        if (typeof result === "string") {
            try { result = JSON.parse(result); } catch {}
        }
        return result;
    } catch {
        return null;
    }
}

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
    const [blackScreen, setBlackScreen] = React.useState(_firstLoad);
    const [objectFit, setObjectFit] = React.useState(_objectFit);
    const videoRef = React.useRef<HTMLVideoElement>(null);
    const fadingRef = React.useRef(false);

    React.useEffect(() => {
        _overlayPlay = (url: string) => {
            setVisible(true);
            fadingRef.current = false;
            setVideoUrl(url);
        };
        _setBlackScreen = setBlackScreen;
        _onObjectFitChange = setObjectFit;

        if (_pendingPlayUrl) {
            setVisible(true);
            fadingRef.current = false;
            setVideoUrl(_pendingPlayUrl);
            _pendingPlayUrl = null;
        }

        return () => {
            _overlayPlay = null;
            _setBlackScreen = null;
            _onObjectFitChange = null;
        };
    }, []);

    const dismiss = React.useCallback(() => {
        if (fadingRef.current) return;
        fadingRef.current = true;
        setVisible(false);
        setTimeout(() => {
            if (videoRef.current) {
                videoRef.current.pause();
                videoRef.current.removeAttribute("src");
                videoRef.current.load();
            }
            setVideoUrl(null);
            fadingRef.current = false;
        }, 400);
    }, []);

    return (
        <div
        id={OVERLAY_ID}
        style={{
            ...overlayStyle,
            opacity: ((videoUrl && visible) || (blackScreen && visible)) ? 1 : 0,
            pointerEvents: ((videoUrl && visible) || (blackScreen && visible)) ? "auto" : "none",
        }}
        >
        {videoUrl && (
        <video
        ref={videoRef}
        src={videoUrl}
        autoPlay
        muted
        playsInline
        style={{ width: "100%", height: "100%", objectFit }}
        onEnded={dismiss}
        onError={dismiss}
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
    if (sessionStorage.getItem(PLAYED_KEY)) return;

    const movies = await loadMovies();
    if (!movies.length) {
        _setBlackScreen?.(false);
        return;
    }

    sessionStorage.setItem(PLAYED_KEY, "1");

    const saved = localStorage.getItem(MOVIE_KEY);
    const movie = saved ? movies.find((m: any) => m.name === saved) : movies[0];
    if (movie?.url) {
        playMovie(movie.url);
    } else {
        _setBlackScreen?.(false);
    }
}

tryStartupPlayback();

function Panel() {
    const [movies, setMovies] = React.useState<any[]>([]);
    const [selected, setSelected] = React.useState(localStorage.getItem(MOVIE_KEY) || "");
    const [objectFit, setObjectFit] = React.useState(_objectFit);
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

    const selectedMovie = movies.find((m: any) => m.name === selected);
    const thumbUrl = selectedMovie?.thumb || null;

    const warnings: string[] = [];
    if (status) {
        if (!status.has_python) warnings.push("python3 not found - HTTP server unavailable");
        if (!status.has_ffmpeg) warnings.push("ffmpeg not found - thumbnails disabled");
        if (status.has_python && !status.server_running) warnings.push("HTTP server is not running");
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
        </>
    );
}

routerHook.addRoute("/startup-movies", Panel);

export default definePlugin(() => ({
    title: "Startup Movies",
    icon: <span>[M]</span>,
    content: <Panel />
}));
