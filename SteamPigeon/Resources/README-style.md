`satellite_style.json` is a **verbatim copy** of
`rocket-flight-manager/app/src/main/assets/satellite_style.json`.

ADR-0014 requires both platforms to render from literally the same MapLibre style
JSON and the same tile provider — MapLibre keeps one offline database per app and
serves any tile whose URL matches, so a provider mismatch silently yields a blank
offline map. Two copies of a file that must not differ is the same hazard the wire
format has; if you change one, change both in the same session.

The tile source is Esri World Imagery and is **evaluation-only**. Issue #26 is an open
release blocker on BOTH platforms: no wired provider permits permanent offline
caching. Do not ship against this URL.
