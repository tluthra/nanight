CREATE TABLE daily_usage (
    day TEXT NOT NULL,
    installation_id TEXT NOT NULL,
    app_version TEXT NOT NULL,
    macos_version TEXT NOT NULL,
    PRIMARY KEY (day, installation_id)
) WITHOUT ROWID;

-- Only aggregate daily counts survive the 90-day retention window.
CREATE TABLE daily_totals (
    day TEXT PRIMARY KEY NOT NULL,
    installations INTEGER NOT NULL
) WITHOUT ROWID;
