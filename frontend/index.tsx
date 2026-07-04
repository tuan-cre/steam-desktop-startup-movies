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

let _overlayPlay: ((url: string) => void) | null = null;
let _pendingPlayUrl: string | null = null;

async function frontendLog(...msg: any[]) {
    try {
        const str = msg.map(m => typeof m === "object" ? JSON.stringify(m) : String(m)).join(" ");
        await Millennium.callServerMethod("log_message", { message: str });
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

function playMovie(url: string) {
    if (_overlayPlay) _overlayPlay(url);
    else _pendingPlayUrl = url;
}

async function tryStartupPlayback() {
    if (sessionStorage.getItem(PLAYED_KEY)) return;

    const t0 = performance.now();
    const movies = await loadMovies();
    frontendLog(`Got ${movies.length} movies in ${(performance.now() - t0).toFixed(0)}ms`);

    if (!movies.length) return;

    sessionStorage.setItem(PLAYED_KEY, "1");

    if (movies[0].url) {
        frontendLog(`Playing: ${movies[0].url}`);
        playMovie(movies[0].url);
    }
}

tryStartupPlayback();

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
        rgOptions={movies.filter(m => m.url).map(m => ({ label: m.name, data: m.url }))}
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
