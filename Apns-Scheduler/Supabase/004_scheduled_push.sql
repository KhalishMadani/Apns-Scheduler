-- scheduled_push: notifications queued by the app to fire later.
-- The app inserts a row with a future `scheduled_at`. A pg_cron job runs once a
-- minute, moves every due row into "NotifLog", and the existing 003 trigger on
-- that table does the actual APNs delivery. One row = one notification, once.

create table if not exists public.scheduled_push (
    id            uuid        primary key default gen_random_uuid(),
    text          text        not null,
    scheduled_at  timestamptz not null,
    dispatched_at timestamptz,
    created_at    timestamptz not null default now()
);

-- Partial index: the dispatcher only ever scans not-yet-sent rows.
create index if not exists scheduled_push_due_idx
    on public.scheduled_push (scheduled_at)
    where dispatched_at is null;

alter table public.scheduled_push enable row level security;

-- Same open-for-anon stance as "NotifLog" (001): the publishable key ships in
-- the app, so anyone with it can queue a push. Acceptable while dev-stage.
-- The row holds only the text the client itself submitted - no private data.
-- `scheduled_at` is bounded so a caller can't queue something years out.

drop policy if exists "scheduled_push insertable" on public.scheduled_push;
create policy "scheduled_push insertable"
    on public.scheduled_push for insert
    to anon, authenticated
    with check (
        scheduled_at > now()
        and scheduled_at < now() + interval '30 days'
    );

-- Needed so the app's `Prefer: return=representation` insert can read the row back.
drop policy if exists "scheduled_push readable" on public.scheduled_push;
create policy "scheduled_push readable"
    on public.scheduled_push for select
    to anon, authenticated
    using (true);

-- No update/delete policy: RLS denies what isn't granted, so the client can
-- queue and read but not tamper. The dispatcher below runs as table owner and
-- bypasses RLS.

-- Dispatcher ---------------------------------------------------------------

create extension if not exists pg_cron with schema extensions;

-- Every minute: claim all due rows atomically (the UPDATE ... RETURNING is the
-- lock), then hand their text to "NotifLog" so 003's trigger sends them.
-- `dispatched_at is null` means an already-sent row can never match again.
select cron.schedule(
    'dispatch-scheduled-push',
    '* * * * *',
    $$
    with due as (
        update public.scheduled_push
           set dispatched_at = now()
         where dispatched_at is null
           and scheduled_at <= now()
        returning text
    )
    insert into public."NotifLog" (text)
    select text from due;
    $$
);

-- To remove the job later:  select cron.unschedule('dispatch-scheduled-push');
