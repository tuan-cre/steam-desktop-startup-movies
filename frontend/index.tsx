import { definePlugin, routerHook, PanelSection, PanelSectionRow, Dropdown, Millennium, EUIMode } from "@steambrew/client";
import React from "react";

const OVERLAY_COMPONENT_ID = "StartupMovieOverlay";
const STORAGE_KEY = "startup-movies-selected";
const PLAYED_KEY = "startup-movies-played-this-session";

let _pendingPlayUrl: string | null = null;
let _overlayPlay: ((url: string) => void) | null = null;

async function backendLog(...msg: any[]) {
    try {
        const str = msg.map((m: any) => typeof m === 'object' ? JSON.stringify(m) : String(m)).join(" ");
        await Millennium.callServerMethod("log_message", { message: `[FRONTEND] ${str}` });
    } catch {}
}

async function callBackend(method: string, ...args: any[]): Promise<any> {
    await backendLog(`callBackend(${method})`);
    try {
        const kwargs = args.length > 0 ? { 0: args[0], 1: args[1], 2: args[2] } : {};
        let result = await Millennium.callServerMethod(method, kwargs);
        if (typeof result === "string") {
            try { result = JSON.parse(result); } catch {}
        }
        return result;
    } catch (e: any) {
        await backendLog(`callBackend(${method}) ERROR:`, e?.message || String(e));
        return null;
    }
}

async function loadMovies(): Promise<{ name: string; size: number }[]> {
    const result = await callBackend("get_movies");
    if (!result || !Array.isArray(result)) return [];
    return result;
}

function StartupMovieOverlay() {
    const [videoUrl, setVideoUrl] = React.useState<string | null>(null);
    const videoRef = React.useRef<HTMLVideoElement>(null);

    React.useEffect(() => {
        _overlayPlay = (url: string) => {
            setVideoUrl(url);
        };
        if (_pendingPlayUrl) {
            setVideoUrl(_pendingPlayUrl);
            _pendingPlayUrl = null;
        }
        return () => { _overlayPlay = null; };
    }, []);

    const dismiss = React.useCallback(() => {
        backendLog("dismissed");
        if (videoRef.current) {
            videoRef.current.pause();
            videoRef.current.removeAttribute("src");
            try { videoRef.current.load(); } catch {}
        }
        setVideoUrl(null);
    }, []);

    if (!videoUrl) return null;

    return (
        <div
            style={{
                position: "fixed",
                top: 0, left: 0,
                width: "100vw",
                height: "100vh",
                background: "#000",
                zIndex: 2147483647,
                display: "flex",
                alignItems: "center",
                justifyContent: "center",
                cursor: "pointer",
            }}
            onClick={dismiss}>
            <video
                ref={videoRef}
                src={videoUrl}
                muted
                autoPlay
                playsInline
                style={{
                    width: "100%",
                    height: "100%",
                    objectFit: "contain",
                }}
                onEnded={() => { backendLog("ended"); dismiss(); }}
                onError={() => { backendLog("video error"); dismiss(); }}
            />
        </div>
    );
}

routerHook.addGlobalComponent(OVERLAY_COMPONENT_ID, StartupMovieOverlay, EUIMode.Desktop);

async function playMovie(name: string): Promise<void> {
    await backendLog(`playMovie(${name})`);

    const url = await callBackend("get_movie_url", name);
    if (!url || typeof url !== "string") {
        await backendLog("get_movie_url returned nil");
        return;
    }
    await backendLog("using URL:", url);

    if (_overlayPlay) {
        _overlayPlay(url);
    } else {
        _pendingPlayUrl = url;
        setTimeout(() => {
            if (_pendingPlayUrl === url) {
                _pendingPlayUrl = null;
                backendLog("overlay unavailable, giving up");
            }
        }, 5000);
    }
}

async function tryStartupPlayback(): Promise<void> {
    await backendLog("tryStartupPlayback");
    if (sessionStorage.getItem(PLAYED_KEY)) {
        await backendLog("already played");
        return;
    }
    const movieList = await loadMovies();
    if (movieList.length === 0) {
        await backendLog("no movies");
        return;
    }

    const saved = localStorage.getItem(STORAGE_KEY);
    const selected = saved && movieList.some((m) => m.name === saved)
        ? saved : movieList[0].name;
    await backendLog("selected:", selected);

    sessionStorage.setItem(PLAYED_KEY, "1");
    setTimeout(() => {
        playMovie(selected).catch((e) => { backendLog("playMovie error:", e?.message); });
    }, 500);
}

function StartupMoviesPanel() {
    const [movieList, setMovieList] = React.useState<{ name: string; size: number }[]>([]);
    const [selected, setSelected] = React.useState(localStorage.getItem(STORAGE_KEY) || "");

    React.useEffect(() => {
        loadMovies().then((movies) => {
            setMovieList(movies);
            if (!selected && movies.length > 0) {
                const first = movies[0].name;
                setSelected(first);
                localStorage.setItem(STORAGE_KEY, first);
            }
        });
    }, []);

    if (movieList.length === 0) {
        return (
            <PanelSection title="Startup Movies">
                <PanelSectionRow>
                    <div style={{ color: "#999", padding: "8px" }}>
                        No .webm files found. Place them in Steam → config → uioverrides → movies/
                    </div>
                </PanelSectionRow>
            </PanelSection>
        );
    }

    const options = movieList.map((m) => ({ label: m.name, data: m.name }));

    return (
        <PanelSection title="Startup Movies">
            <PanelSectionRow>
                <Dropdown
                    rgOptions={options}
                    selectedOption={selected}
                    onChange={(opt) => {
                        const name = opt.data as string;
                        setSelected(name);
                        localStorage.setItem(STORAGE_KEY, name);
                    }}
                />
            </PanelSectionRow>
            <PanelSectionRow>
                <span
                    style={{ cursor: "pointer", color: "#67c1f5", padding: "8px", display: "inline-block" }}
                    onClick={() => { if (selected) playMovie(selected); }}
                >
                    Preview Movie
                </span>
            </PanelSectionRow>
            <PanelSectionRow>
                <div style={{ color: "#999", fontSize: "12px", padding: "8px" }}>
                    Selected movie plays once per Steam session on launch.
                </div>
            </PanelSectionRow>
        </PanelSection>
    );
}

routerHook.addRoute("/startup-movies", StartupMoviesPanel);

backendLog("Plugin module loaded, readyState: " + document.readyState);

if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", () => {
        backendLog("DOMContentLoaded, scheduling in 2s");
        setTimeout(tryStartupPlayback, 2000);
    });
} else {
    backendLog("DOM ready, scheduling in 2s");
    setTimeout(tryStartupPlayback, 2000);
}

export default definePlugin(() => {
    backendLog("definePlugin factory called");
    return {
        title: "Startup Movies",
        icon: <span>[M]</span>,
        content: <StartupMoviesPanel />,
    };
});
