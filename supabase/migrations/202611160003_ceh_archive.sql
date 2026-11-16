begin;
alter table public.ceh_categories add column if not exists archived_at timestamptz;
alter table public.ceh_products add column if not exists archived_at timestamptz;

create or replace function public.ceh_archive_catalog_entry(category_id integer, product_id integer)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.ceh_profiles where id = auth.uid() and role = 'admin') then
    raise exception 'Insufficient permissions' using errcode = '42501';
  end if;
  if product_id is null then
    update public.ceh_categories set archived_at = now() where id = category_id and archived_at is null;
    update public.ceh_products p set archived_at = now()
      where p.category_id = ceh_archive_catalog_entry.category_id and p.archived_at is null;
  else
    update public.ceh_products p set archived_at = now()
      where p.id = product_id and p.category_id = ceh_archive_catalog_entry.category_id and p.archived_at is null;
  end if;
end;
$$;
revoke all on function public.ceh_archive_catalog_entry(integer,integer) from public, anon, authenticated;
grant execute on function public.ceh_archive_catalog_entry(integer,integer) to authenticated;
create or replace function public.ceh_save_stock(changes jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := auth.uid();
  change record;
  previous integer;
begin
  if not exists (select 1 from public.ceh_profiles where id = actor and role in ('admin','confectioner')) then
    raise exception 'Insufficient permissions' using errcode = '42501';
  end if;
  if changes is null or jsonb_typeof(changes) <> 'array' then
    raise exception 'Invalid change list' using errcode = '22023';
  end if;
  if jsonb_array_length(changes) not between 1 and 500 then
    raise exception 'Invalid change count' using errcode = '22023';
  end if;
  for change in
    select * from jsonb_to_recordset(changes)
      as row_change(product_id integer, warehouse_id integer, expected integer, quantity integer)
      order by product_id, warehouse_id
  loop
    if change.expected is null or change.quantity is null or change.quantity < 0 then
      raise exception 'Invalid quantity' using errcode = '22023';
    end if;
    perform 1 from public.ceh_products p join public.ceh_categories c on c.id=p.category_id
      where p.id=change.product_id and p.archived_at is null and c.archived_at is null for share of c,p;
    if not found then raise exception 'Archived entry' using errcode = '40001'; end if;
    select s.quantity into previous from public.ceh_stock s
      where s.product_id = change.product_id and s.warehouse_id = change.warehouse_id
      for update;
    if not found or previous <> change.expected then
      raise exception 'Stock has changed; reload balances' using errcode = '40001';
    end if;
    if previous <> change.quantity then
      update public.ceh_stock s set quantity = change.quantity
        where s.product_id = change.product_id and s.warehouse_id = change.warehouse_id;
      insert into public.ceh_stock_log(user_id,product_id,warehouse_id,quantity_before,quantity_after)
        values (actor,change.product_id,change.warehouse_id,previous,change.quantity);
    end if;
  end loop;
end;
$$;


commit;
