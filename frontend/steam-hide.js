window.__showSteamUI = function() {
    var links = document.querySelectorAll('link[href*="steam-hide.css"]');
    links.forEach(function(l) { l.remove(); });
    var s = document.getElementById('startup-movies-hide');
    if (s) s.remove();
    var p = document.getElementById('millennium-prehide');
    if (p) p.remove();
};
