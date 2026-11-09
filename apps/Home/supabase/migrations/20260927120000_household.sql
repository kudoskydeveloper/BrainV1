-- Household data for the wall panel: chores, shopping, automations, shared settings.
-- Devices (lights, AC, lock, sensors) live in Home Assistant, not here.
--
-- Sync model: the tablet keeps a local copy and syncs both ways. Every synced row
-- has a server-set updated_at (clients pull "changed since") and soft deletes
-- (deleted = true) so removals propagate. Last write wins.

-- ─── Households & members ────────────────────────────────────────────────

create table public.households (
    id          uuid primary key default gen_random_uuid(),
    name        text not null default 'Home',
    created_at  timestamptz not null default now()
);

create table public.household_members (
    household_id  uuid not null references public.households (id) on delete cascade,
    user_id       uuid not null references auth.users (id) on delete cascade,
    display_name  text not null,
    created_at    timestamptz not null default now(),
    primary key (household_id, user_id)
);

create index household_members_user_idx on public.household_members (user_id);

-- Is the signed-in user a member of this household? SECURITY DEFINER so policies
-- can call it without recursing into household_members' own policy.
create or replace function public.is_member(hh uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
    select exists (select 1 from household_members where household_id = hh and user_id = auth.uid())
$$;

-- First sign-in: join the user's household, or create one and join it.
create or replace function public.join_or_create_household(member_name text)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
    hh uuid;
begin
    if auth.uid() is null then
        raise exception 'not signed in';
    end if;
    select household_id into hh from household_members where user_id = auth.uid() order by created_at limit 1;
    if hh is not null then
        return hh;
    end if;
    insert into households (name) values ('Home') returning id into hh;
    insert into household_members (household_id, user_id, display_name) values (hh, auth.uid(), member_name);
    return hh;
end
$$;

revoke all on function public.join_or_create_household(text) from public, anon;
grant execute on function public.join_or_create_household(text) to authenticated;

-- Keeps the free-tier project from pausing: the tablet calls this every 12 hours.
create or replace function public.heartbeat()
returns timestamptz
language sql stable
as $$ select now() $$;

grant execute on function public.heartbeat() to anon, authenticated;

-- ─── Synced tables ───────────────────────────────────────────────────────

create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
    new.updated_at := now();
    return new;
end
$$;

create table public.tasks (
    household_id  uuid not null references public.households (id) on delete cascade,
    id            text not null,
    title         text not null,
    who           text not null default 'Anyone',     -- Ján, Jana, Anyone or "Take turns"
    part          text not null default 'Anytime',    -- Morning, Afternoon, Evening, Anytime
    repeat        jsonb not null,                     -- see Repeat in the app (once, daily, weekly, flexible, window)
    updated_at    timestamptz not null default now(),
    deleted       boolean not null default false,
    primary key (household_id, id)
);

-- One row per ticked-off occurrence; period = the day, or the first day of the week/month for flexible chores.
create table public.task_completions (
    household_id  uuid not null references public.households (id) on delete cascade,
    task_id       text not null,
    period        date not null,
    done          boolean not null default true,      -- false = un-ticked (tombstone)
    done_by       text,
    updated_at    timestamptz not null default now(),
    primary key (household_id, task_id, period)
);

create table public.shopping_items (
    household_id  uuid not null references public.households (id) on delete cascade,
    id            text not null,
    name          text not null,
    done          boolean not null default false,
    updated_at    timestamptz not null default now(),
    deleted       boolean not null default false,
    primary key (household_id, id)
);

create table public.automations (
    household_id  uuid not null references public.households (id) on delete cascade,
    id            text not null,
    name          text not null,
    enabled       boolean not null default true,
    trigger       jsonb not null,
    action        jsonb not null,
    updated_at    timestamptz not null default now(),
    deleted       boolean not null default false,
    primary key (household_id, id)
);

-- Settings the whole household shares (calendars, assistant name, PIN hash…); device-only ones stay on the device.
create table public.household_settings (
    household_id  uuid primary key references public.households (id) on delete cascade,
    data          jsonb not null default '{}'::jsonb,
    updated_at    timestamptz not null default now()
);

do $$
declare
    t text;
begin
    foreach t in array array['tasks', 'task_completions', 'shopping_items', 'automations', 'household_settings'] loop
        execute format('create trigger touch_%1$s before insert or update on public.%1$I for each row execute function public.touch_updated_at()', t);
        execute format('create index %1$s_changed_idx on public.%1$I (household_id, updated_at)', t);
    end loop;
end
$$;

-- ─── Row-level security: members only ────────────────────────────────────

alter table public.households          enable row level security;
alter table public.household_members   enable row level security;
alter table public.tasks               enable row level security;
alter table public.task_completions    enable row level security;
alter table public.shopping_items      enable row level security;
alter table public.automations         enable row level security;
alter table public.household_settings  enable row level security;

create policy "members read their household" on public.households
    for select to authenticated using (public.is_member(id));

create policy "members see each other" on public.household_members
    for select to authenticated using (public.is_member(household_id));

do $$
declare
    t text;
begin
    foreach t in array array['tasks', 'task_completions', 'shopping_items', 'automations', 'household_settings'] loop
        execute format(
            'create policy "members manage %1$s" on public.%1$I for all to authenticated
                 using (public.is_member(household_id)) with check (public.is_member(household_id))', t);
    end loop;
end
$$;

-- ─── Live updates (for phones later) ─────────────────────────────────────

alter publication supabase_realtime add table
    public.tasks, public.task_completions, public.shopping_items, public.automations, public.household_settings;
