// Content script: reserved for page-scoped needs of the companion flow. The current tool surface
// (tabs, snapshot, scripting) is served entirely from the service worker, so this stays empty
// until a tool needs per-document work (e.g. DOM watching). It exists so the manifest and the
// bundle layout do not change when that lands.
export {};
