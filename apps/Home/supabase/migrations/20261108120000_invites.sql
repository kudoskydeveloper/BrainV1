-- Joining a household with a code: the first person creates the household, the others join it with its invite code
-- (shown in the app under Domácnosť) instead of getting a household of their own.

alter table public.households add column invite_code text;
update public.households set invite_code = upper(substr(md5(gen_random_uuid()::text), 1, 6)) where invite_code is null;
alter table public.households
    alter column invite_code set default upper(substr(md5(gen_random_uuid()::text), 1, 6)),
    alter column invite_code set not null,
    add constraint households_invite_code_key unique (invite_code);

-- The signed-in user's household with its members, or null when they aren't in one yet.
create or replace function public.my_household()
returns jsonb
language sql stable security definer set search_path = public
as $$
    select jsonb_build_object(
        'id', h.id, 'name', h.name, 'invite_code', h.invite_code,
        'members', (select jsonb_agg(jsonb_build_object('user_id', m2.user_id, 'name', m2.display_name) order by m2.created_at)
                    from household_members m2 where m2.household_id = h.id))
    from household_members m join households h on h.id = m.household_id
    where m.user_id = auth.uid()
    order by m.created_at
    limit 1
$$;

-- Join the household with this invite code (case and spaces don't matter). Joining again only renames you.
create or replace function public.join_household(code text, member_name text)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
    hh uuid;
begin
    if auth.uid() is null then
        raise exception 'not signed in';
    end if;
    select id into hh from households where invite_code = upper(replace(trim(code), ' ', ''));
    if hh is null then
        raise exception 'invalid invite code';
    end if;
    insert into household_members (household_id, user_id, display_name) values (hh, auth.uid(), member_name)
        on conflict (household_id, user_id) do update set display_name = excluded.display_name;
    return hh;
end
$$;

-- Members may rename the household.
create policy "members rename their household" on public.households
    for update to authenticated using (public.is_member(id)) with check (public.is_member(id));

revoke all on function public.my_household() from public, anon;
revoke all on function public.join_household(text, text) from public, anon;
grant execute on function public.my_household() to authenticated;
grant execute on function public.join_household(text, text) to authenticated;
