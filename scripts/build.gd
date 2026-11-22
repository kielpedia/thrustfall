extends RefCounted
## Build stamp. The release workflow overwrites these values before exporting;
## a copy run from the editor or a local export shows "dev".

const COMMIT := "dev"
const DATE := ""


## e.g. "v0.8 · build 5f3e27c · 2026-11-22", or "v0.8 · dev build" when run locally.
static func label(version: String) -> String:
	if COMMIT == "dev":
		return "v%s · dev build" % version
	return "v%s · build %s · %s" % [version, COMMIT, DATE]
