-- Device tokens for APNs delivery.

create table if not exists public.devices (
    id           uuid        primary key default gen_random_uuid(),
    device_token text        not null unique,
    platform     text        not null default 'ios',
    environment  text        not null default 'development',
    created_at   timestamptz not null default now(),
    updated_at   timestamptz not null default now()
);

alter table public.devices enable row level security;

-- No policies for anon on purpose. Device tokens are a delivery address for
-- every user's push traffic - the anon key ships inside the app, so granting
-- it SELECT here would expose the whole list. Registration goes through the
-- security-definer function below instead, which writes without granting read.

create or replace function public.register_device(
    p_token       text,
    p_environment text default 'development'
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
    v_id uuid;
begin
    if p_token is null or length(trim(p_token)) = 0 then
        raise exception 'device token must not be empty';
    end if;

    insert into public.devices (device_token, environment)
    values (trim(p_token), p_environment)
    on conflict (device_token) do update
        set updated_at  = now(),
            environment = excluded.environment
    returning id into v_id;

    return v_id;
end;
$$;

revoke all on function public.register_device(text, text) from public;
grant execute on function public.register_device(text, text) to anon, authenticated;
