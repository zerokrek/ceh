begin;
create table public.ceh_catalog_log (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default clock_timestamp(),
  actor text,
  category_id integer not null,
  product_id integer,
  entry_name text not null,
  archived_at timestamptz not null,
  action text not null check (action in ('archive','restore')),
  restores_id bigint unique references public.ceh_catalog_log(id)
);
alter table public.ceh_catalog_log enable row level security;
revoke all on public.ceh_catalog_log from anon, authenticated;

create function public.ceh_record_catalog_archive()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  parent_id integer;
  position_id integer;
begin
  if tg_table_name = 'ceh_categories' then
    parent_id := new.id;
  else
    parent_id := new.category_id;
    position_id := new.id;
    if exists (select 1 from public.ceh_categories c where c.id=parent_id and c.archived_at is not null) then
      return new;
    end if;
  end if;
  insert into public.ceh_catalog_log(actor,category_id,product_id,entry_name,archived_at,action)
  values ((select p.display_name from public.ceh_profiles p where p.id=auth.uid()),
    parent_id,position_id,new.name,new.archived_at,'archive');
  return new;
end;
$$;
revoke all on function public.ceh_record_catalog_archive() from public, anon, authenticated;
create trigger ceh_log_category_archive after update of archived_at on public.ceh_categories
for each row when (old.archived_at is null and new.archived_at is not null)
execute function public.ceh_record_catalog_archive();
create trigger ceh_log_product_archive after update of archived_at on public.ceh_products
for each row when (old.archived_at is null and new.archived_at is not null)
execute function public.ceh_record_catalog_archive();

create function public.ceh_catalog_history()
returns table(id bigint, created_at timestamptz, actor text, entry_name text, action text, is_category boolean, can_restore boolean)
language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.ceh_profiles p where p.id=auth.uid() and p.role='admin') then
    raise exception 'Insufficient permissions' using errcode='42501';
  end if;
  return query select l.id,l.created_at,l.actor,l.entry_name,l.action,l.product_id is null,
    l.action='archive' and not exists(select 1 from public.ceh_catalog_log r where r.restores_id=l.id)
    and case when l.product_id is null then c.archived_at is not distinct from l.archived_at
      else c.id is not null and c.archived_at is null and p.archived_at is not distinct from l.archived_at end
  from public.ceh_catalog_log l
  left join public.ceh_categories c on c.id=l.category_id
  left join public.ceh_products p on p.id=l.product_id
  order by l.id desc;
end;
$$;

create function public.ceh_restore_catalog_entry(event_id bigint)
returns void language plpgsql security definer set search_path = '' as $$
declare
  entry public.ceh_catalog_log%rowtype;
  parent_archived timestamptz;
begin
  if not exists (select 1 from public.ceh_profiles p where p.id=auth.uid() and p.role='admin') then
    raise exception 'Insufficient permissions' using errcode='42501';
  end if;
  select * into strict entry from public.ceh_catalog_log l where l.id=event_id and l.action='archive';
  select c.archived_at into strict parent_archived from public.ceh_categories c
    where c.id=entry.category_id for update;
  if entry.product_id is null then
    if parent_archived is distinct from entry.archived_at then
      raise exception 'Archive has changed' using errcode='40001';
    end if;
    update public.ceh_categories set archived_at=null where id=entry.category_id;
    update public.ceh_products set archived_at=null
      where category_id=entry.category_id and archived_at=entry.archived_at;
  else
    if parent_archived is not null then
      raise exception 'Restore parent first' using errcode='40001';
    end if;
    update public.ceh_products set archived_at=null where id=entry.product_id
      and category_id=entry.category_id and archived_at=entry.archived_at;
    if not found then raise exception 'Archive has changed' using errcode='40001'; end if;
  end if;
  insert into public.ceh_catalog_log(actor,category_id,product_id,entry_name,archived_at,action,restores_id)
  values ((select p.display_name from public.ceh_profiles p where p.id=auth.uid()),
    entry.category_id,entry.product_id,entry.entry_name,entry.archived_at,'restore',entry.id);
end;
$$;
revoke all on function public.ceh_catalog_history(), public.ceh_restore_catalog_entry(bigint) from public, anon, authenticated;
grant execute on function public.ceh_catalog_history(), public.ceh_restore_catalog_entry(bigint) to authenticated;
commit;
