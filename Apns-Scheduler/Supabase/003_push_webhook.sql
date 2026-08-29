-- Fires send-push on every NotifLog insert.
-- This is what the dashboard's "Database Webhooks" UI generates under the
-- hood; writing it directly avoids depending on where that page currently lives.

create extension if not exists pg_net with schema extensions;

create or replace function public.notiflog_push()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    -- Async: pg_net queues the request and returns immediately, so a slow or
    -- failing APNs call never blocks or rolls back the INSERT.
    perform net.http_post(
        url     := 'https://<your-project-ref>.supabase.co/functions/v1/send-push',
        headers := jsonb_build_object(
            'Content-Type',     'application/json',
            'x-webhook-secret', 'REPLACE_WITH_YOUR_WEBHOOK_SECRET'
        ),
        body    := jsonb_build_object('record', to_jsonb(NEW))
    );
    return NEW;
end;
$$;

drop trigger if exists notiflog_push_trigger on public."NotifLog";
create trigger notiflog_push_trigger
    after insert on public."NotifLog"
    for each row
    execute function public.notiflog_push();
