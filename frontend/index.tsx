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
const STORAGE_KEY = "startup-movies-selected";
const PLAYED_KEY = "startup-movies-played-this-session";

let _overlayPlay: ((url: string) => void) | null = null;
let _pendingPlayUrl: string | null = null;

async function backendLog(...msg: any[]) {
    try {
        const str = msg.map(m => typeof m === "object" ? JSON.stringify(m) : String(m)).join(" ");
        await Millennium.callServerMethod("log_message", {
            message: `[FRONTEND] ${str}`
        });
    } catch {}
}

async function callBackend(method: string, ...args: any[]) {
    try {
        const kwargs = args.length ? {0: args[0], 1: args[1], 2: args[2]} : {};
        let result = await Millennium.callServerMethod(method, kwargs);
        if (typeof result === "string") {
            try { result = JSON.parse(result); } catch {}
        }
        return result;
    } catch {
        return null;
    }
}

async function loadMovies() {
    const result = await callBackend("get_movies");
    return Array.isArray(result) ? result : [];
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
};

function StartupMovieOverlay() {
    const [videoUrl, setVideoUrl] = React.useState<string | null>(null);
    const videoRef = React.useRef<HTMLVideoElement>(null);

    React.useEffect(() => {
        _overlayPlay = (url: string) => setVideoUrl(url);

        if (_pendingPlayUrl) {
            setVideoUrl(_pendingPlayUrl);
            _pendingPlayUrl = null;
        }

        return () => {
            _overlayPlay = null;
        };
    }, []);

    React.useEffect(() => {
        if (!videoUrl) return;
        const root = document.getElementById(OVERLAY_ID);
        if (root) root.style.display = "flex";
    }, [videoUrl]);

    const dismiss = React.useCallback(() => {
        if (videoRef.current) {
            videoRef.current.pause();
            videoRef.current.removeAttribute("src");
            videoRef.current.load();
        }
        setVideoUrl(null);

        const root = document.getElementById(OVERLAY_ID);
        if (root) root.style.display = "none";
    }, []);

    if (!videoUrl) return null;

    return (
        <div id={OVERLAY_ID} style={overlayStyle}>
        <video
        ref={videoRef}
        src={videoUrl}
        autoPlay
        muted
        playsInline
        style={{ width: "100%", height: "100%", objectFit: "contain" }}
        onEnded={dismiss}
        onError={dismiss}
        />
        </div>
    );
}

routerHook.addGlobalComponent(
    OVERLAY_ID,
    StartupMovieOverlay,
    EUIMode.Desktop
);

async function playMovie(name: string) {
    const url = await callBackend("get_movie_url", name);
    if (!url) return;

    if (_overlayPlay) _overlayPlay(url);
    else _pendingPlayUrl = url;
}

async function tryStartupPlayback() {
    if (sessionStorage.getItem(PLAYED_KEY)) return;

    const movies = await loadMovies();
    if (!movies.length) return;

    sessionStorage.setItem(PLAYED_KEY, "1");

    setTimeout(() => {
        playMovie(movies[0].name);
    }, 500);
}

if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", () => {
        setTimeout(tryStartupPlayback, 1500);
    });
} else {
    setTimeout(tryStartupPlayback, 1500);
}

function Panel() {
    const [movies, setMovies] = React.useState<any[]>([]);
    const [selected, setSelected] = React.useState("");

    React.useEffect(() => {
        loadMovies().then(setMovies);
    }, []);

    return (
        <PanelSection title="Startup Movies">
        <PanelSectionRow>
        <Dropdown
        rgOptions={movies.map(m => ({ label: m.name, data: m.name }))}
        selectedOption={selected}
        onChange={(v) => setSelected(v.data)}
        />
        </PanelSectionRow>

        <PanelSectionRow>
        <span onClick={() => selected && playMovie(selected)}>
        Preview
        </span>
        </PanelSectionRow>
        </PanelSection>
    );
}

routerHook.addRoute("/startup-movies", Panel);

export default definePlugin(() => ({
    title: "Startup Movies",
    icon: <span>[M]</span>,
    content: <Panel />
}));
