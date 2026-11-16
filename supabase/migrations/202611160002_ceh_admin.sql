begin;
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

create or replace function public.ceh_add_catalog_entry(entry_name text, category integer, quantities integer[])
returns integer language plpgsql security definer set search_path = '' as $$
declare
  entry_id integer;
begin
  if not exists (select 1 from public.ceh_profiles where id = auth.uid() and role = 'admin') then
    raise exception 'Insufficient permissions' using errcode = '42501';
  end if;
  if category is null then
    insert into public.ceh_categories(name) values (trim(entry_name)) returning id into entry_id;
  else
    insert into public.ceh_products(category_id,name) values (category,trim(entry_name))
      returning id into entry_id;
    insert into public.ceh_stock(product_id,warehouse_id,quantity)
      values (entry_id,1,quantities[1]),(entry_id,2,quantities[2]);
    insert into public.ceh_stock_log(user_id,product_id,warehouse_id,quantity_before,quantity_after)
      select auth.uid(),product_id,warehouse_id,0,quantity
      from public.ceh_stock where product_id = entry_id and quantity > 0;
  end if;
  return entry_id;
end;
$$;
revoke all on function public.ceh_add_catalog_entry(text,integer,integer[]) from public, anon, authenticated;
grant execute on function public.ceh_add_catalog_entry(text,integer,integer[]) to authenticated;
commit;
