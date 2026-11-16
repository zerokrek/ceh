begin;

-- The application identifies staff by their administrator-managed profile login.
revoke insert, update, delete, truncate on public.ceh_profiles from public, anon, authenticated;
revoke insert (login, role), update (login, role) on public.ceh_profiles from public, anon, authenticated;
revoke truncate on public.ceh_stock from public, anon, authenticated;

create or replace function public.ceh_enforce_stock_warehouse()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  staff_login text;
  staff_role text;
  allowed_warehouse integer;
begin
  if auth.uid() is null and (
    auth.role() = 'service_role' or
    (auth.role() is null and current_setting('role', true) in ('none', 'postgres'))
  ) then
    if tg_op = 'DELETE' then return old; end if;
    return new;
  end if;

  select p.login, p.role into staff_login, staff_role
  from public.ceh_profiles p where p.id = auth.uid();

  if staff_role is distinct from 'admin' then
    allowed_warehouse := case
      when staff_login in ('konditer1', 'konditer2') then 1
      when staff_login in ('konditer3', 'konditer4') then 2
    end;

    if allowed_warehouse is null then
      raise exception 'Нет доступа к изменению остатков' using errcode = '42501';
    end if;
    if tg_op <> 'INSERT' and old.warehouse_id is distinct from allowed_warehouse then
      raise exception 'Этот склад доступен только для просмотра' using errcode = '42501';
    end if;
    if tg_op <> 'DELETE' and new.warehouse_id is distinct from allowed_warehouse then
      raise exception 'Этот склад доступен только для просмотра' using errcode = '42501';
    end if;
  end if;

  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

revoke all on function public.ceh_enforce_stock_warehouse() from public, anon, authenticated;

drop trigger if exists ceh_enforce_stock_warehouse on public.ceh_stock;
create trigger ceh_enforce_stock_warehouse
before insert or update or delete on public.ceh_stock
for each row execute function public.ceh_enforce_stock_warehouse();

commit;
