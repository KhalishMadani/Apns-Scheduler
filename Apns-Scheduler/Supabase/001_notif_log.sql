-- NotifLog: log of notifications handled by the app.
-- Quoted identifier: Postgres folds unquoted names to lowercase, so the
-- mixed-case table name must stay quoted in every hand-written query.

create table if not exists public."NotifLog" (
    uid        uuid        primary key default gen_random_uuid(),
    text       text        not null,
    created_at timestamptz not null default now()
);

create index if not exists notiflog_created_at_idx
    on public."NotifLog" (created_at desc);

alter table public."NotifLog" enable row level security;

-- No auth in the app yet, so requests arrive as the `anon` role.
-- These policies are deliberately open: anyone holding the publishable key
-- (which is extractable from the shipped app) can read and insert rows.
-- Acceptable while this is a dev-stage log with no private data in it.
-- Tighten before shipping - see the note at the bottom of this file.
-- `authenticated` is included so these keep working once sign-in exists.

drop policy if exists "NotifLog readable" on public."NotifLog";
create policy "NotifLog readable"
    on public."NotifLog" for select
    to anon, authenticated
    using (true);

drop policy if exists "NotifLog insertable" on public."NotifLog";
create policy "NotifLog insertable"
    on public."NotifLog" for insert
    to anon, authenticated
    with check (true);

-- Deliberately no update or delete policy: RLS denies anything not granted,
-- so rows can be added and read but not altered or removed by the client.

-- WHEN AUTH IS ADDED, migrate to per-user rows:
--   alter table public."NotifLog"
--       add column user_id uuid references auth.users (id) on delete cascade;
--   -- then replace the policies above with:
--   --   using (auth.uid() = user_id)
--   --   with check (auth.uid() = user_id)
--   -- and drop `anon` from the role lists.
