# Apns-Scheduler

iOS app that queues push notifications for later delivery. The app writes a row
to Supabase; a `pg_cron` job moves due rows into `NotifLog`; a trigger on that
table calls a Supabase Edge Function, which signs an APNs JWT and delivers to
every registered device.

```
iOS app ──insert──> scheduled_push ──pg_cron──> NotifLog ──trigger──> send-push ──> APNs
   └────────────── register_device() ────────> devices ──────────────────┘
```

## Requirements

- Xcode 15+, iOS 17+ device (push does not work in the Simulator)
- Apple Developer account with the Push Notifications capability
- An APNs auth key (`.p8`) from Apple Developer > Keys
- A Supabase project, plus the [Supabase CLI](https://supabase.com/docs/guides/cli)

## 1. App configuration

`Secrets.xcconfig` is gitignored. Copy the example and fill it in:

```bash
cp Apns-Scheduler/Secrets.xcconfig.example Apns-Scheduler/Secrets.xcconfig
```

```
SUPABASE_URL = https:/$()/<your-project-ref>.supabase.co
SUPABASE_ANON_KEY = sb_publishable_...
```

The `$()` in the URL is required — xcconfig treats `//` as a comment, and the
empty variable reference breaks up the sequence without changing the value.

Both keys flow through `Info.plist` into `SupabaseConfig.fromInfoPlist()`.

In Xcode, set **Signing & Capabilities > Team** to your own team (the checked-in
`DEVELOPMENT_TEAM` is intentionally blank) and change
`PRODUCT_BUNDLE_IDENTIFIER` to a bundle ID you own.

## 2. Database

Run the migrations in order against your project — SQL Editor, or `psql`:

| File | Creates |
| --- | --- |
| `Apns-Scheduler/Supabase/001_notif_log.sql` | `NotifLog` table + RLS |
| `Apns-Scheduler/Supabase/002_devices.sql` | `devices` table + `register_device()` RPC |
| `Apns-Scheduler/Supabase/003_push_webhook.sql` | `pg_net` trigger calling `send-push` |
| `Apns-Scheduler/Supabase/004_scheduled_push.sql` | `scheduled_push` table + `pg_cron` dispatcher |

Before running `003`, edit two placeholders in it:

- `<your-project-ref>` in the function URL
- `REPLACE_WITH_YOUR_WEBHOOK_SECRET` — any long random string; it must match the
  `WEBHOOK_SECRET` set in step 3. Generate one with `openssl rand -hex 32`.

`003` and `004` need the `pg_net` and `pg_cron` extensions, which the migrations
create but which must be available on your plan.

## 3. Edge Function

```bash
supabase functions deploy send-push --no-verify-jwt
```

`--no-verify-jwt` is deliberate: the trigger authenticates with the
`x-webhook-secret` header, not a Supabase JWT.

Set these secrets on the project:

| Variable | Value |
| --- | --- |
| `APNS_KEY_ID` | Key ID of your `.p8`, from Apple Developer > Keys |
| `APNS_TEAM_ID` | Your 10-character Apple Team ID |
| `APNS_BUNDLE_ID` | Must match `PRODUCT_BUNDLE_IDENTIFIER` |
| `APNS_P8` | Full contents of the `.p8` file, newlines included |
| `APNS_ENVIRONMENT` | `development` or `production` |
| `WEBHOOK_SECRET` | The same string used in `003` |

```bash
supabase secrets set --env-file supabase/functions/send-push/.env
```

`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are injected automatically.

`APNS_ENVIRONMENT` must match the app's `aps-environment` entitlement. APNs uses
separate token namespaces for sandbox and production, and a token minted in one
is rejected by the other. A debug build is `development`; TestFlight and the App
Store are `production`.

## 4. Run

Build to a physical device and grant notification permission. The app registers
its APNs token through `register_device()`, then you can queue a push. Check
delivery with `supabase functions logs send-push`.

## Security notes

The publishable (anon) key ships inside the app and is extractable, so RLS is
the only boundary that matters:

- `devices` has **no** anon policies. Registration goes through the
  `security definer` `register_device()` RPC, which writes without granting read
   — device tokens are never exposed to the client.
- `NotifLog` and `scheduled_push` allow anon `select` and `insert`, and no
  `update` or `delete`. This is a dev-stage stance with no auth in the app yet:
  anyone with the key can read the log and queue a push. Add auth and scope the
  policies to `auth.uid()` before shipping this to real users.
- `scheduled_at` is bounded to 30 days out so a caller cannot queue far-future
  rows.
- The `send-push` function URL is public. `WEBHOOK_SECRET` is what stops anyone
  who finds it from firing arbitrary pushes.
