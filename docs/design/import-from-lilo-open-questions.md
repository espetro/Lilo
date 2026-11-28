# Import from existing Lilo: open questions for the owner

1. Settings: carry over wholesale, or a curated allowlist of keys? Blind copy may import flags the beta does not know.
2. Cookies and website data: the WebKit store is keyed by bundle id, copying it into the beta is undocumented. Acceptable to be logged out in the beta, or do you want cookie parity (prod closed during the copy)?
3. Direction: should the release Lilo also offer "Import from Lilo Beta", or stay one-way (beta reads prod)?
4. History: full copy (can be hundreds of thousands of visits) or capped to a recent window?
5. Multiple prod profiles: import all, or pick one at scan time?
6. Re-import: `BrowserImporter` dedupes re-runs today; is an explicit "reset beta data and re-import" action wanted?
7. Extensions: re-install by id from the Web Store (current pipeline behavior), or also carry over per-extension settings from `extensionSettings`?
