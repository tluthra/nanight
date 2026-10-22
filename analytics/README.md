# Nanight analytics

A Cloudflare Worker and D1 database. No runtime npm dependencies, analytics SDK,
camera data, or connection to Nanit. Only release builds with an explicitly
configured endpoint send requests.

Dashboard: https://nanight-analytics.tanooj-0dc.workers.dev/

## Endpoints

- `POST /v1/ping`: JSON containing only `installation_id` (UUID v4), `app_version`
  (numeric dotted version), and `macos_version` (major version string).
- `GET /`: private dashboard. HTTP Basic username `nanight`, password from the
  `DASHBOARD_PASSWORD` Worker secret. Missing credentials fail closed.

The server assigns the UTC day. A `(day, installation_id)` primary key deduplicates
retries. The client persists the last successful UTC day and last attempt. Only a
2xx response completes the day; failures retry silently after a 15-minute cooldown
that survives restarts. Launch, wake, and network recovery check whether a ping is
due, with a 15-minute timer as a fallback. Successful days suppress further pings.
Missed dates are not backfilled, and no background agent runs while the app is quit.

The dashboard shows unique installations for today, the last 7 UTC dates, and
the last 30 UTC dates. Version breakdowns use each installation's latest report
within that window. It shows up to a year of daily history. Counts are approximate:
offline attempts, opt-outs, resets of local preferences, and multiple Macs affect
the relationship between counts and actual people.

## Develop and verify

```sh
cd analytics
npm ci
npm test
npm run build
npm run migrate:local
```

For a local dashboard, create a gitignored `.dev.vars` file with a local-only
`DASHBOARD_PASSWORD`, then run `npm run dev`. Tests use isolated, temporary D1
databases and synthetic IDs. They never send events to production.

## Deploy

The committed Wrangler configuration identifies the Nanight database. For a new
account, run `npx wrangler login`, create a database with
`npx wrangler d1 create nanight-analytics`, and update `account_id` and `database_id`.

```sh
npm run migrate:remote
npm run deploy
npx wrangler secret put DASHBOARD_PASSWORD
```

Use a unique, strong password from a password manager. The initial deployment's
dashboard credential is stored only in the gitignored `.env.dashboard.local`
file on the setup Mac and in the Cloudflare Worker secret. Keep your own secure
copy. Replace it with `wrangler secret put` when needed. Never put the password
or a Cloudflare API token in Nanight, URLs, committed files, or build settings.

Supply `NANIGHT_ANALYTICS_URL` with the deployed HTTPS `/v1/ping` URL when running
`scripts/build-distributable.sh` or `scripts/release-github.sh` for an official
release. For direct Xcode builds, pass it as an `xcodebuild` build setting.
`Configuration/Info.plist` expands that setting into `NanightAnalyticsURL`.
There is no default endpoint: ordinary builds and forks send nothing unless they
explicitly configure one. Debug builds still never send. The URL remains visible
in configured apps and does not authenticate them. When uploading an existing ZIP
with `BUILD=0`, its endpoint is already fixed by the earlier build.
The app release process is separate from backend deployment.

## Retention and privacy

A daily cron at 03:15 UTC transactionally aggregates expired days and deletes
installation records outside the latest 90 UTC dates. The aggregate table stores
only a date and installation count. D1 recovery backups may retain recently
deleted rows for Cloudflare's applicable Time Travel window.

Worker request logging is disabled, and the code never logs payloads or IDs.
Cloudflare still handles connection metadata. A transient IP hash is used only by
the rate-limit binding (60 requests per minute per location); it is not written
to the database. No cookies or third-party dashboard scripts are used.

The ingestion endpoint is public, as it must be for a distributed desktop app.
Validation, small body limits, and rate limiting reduce abuse, but counts are
not proof of genuine installations. There is no secret embedded in the app.
Cloudflare's free-tier request, read, write, and storage limits still apply.
