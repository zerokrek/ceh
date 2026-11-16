begin;
alter table public.ceh_categories add column has_biscuit_diameters boolean not null default false;
update public.ceh_categories c set has_biscuit_diameters=true
where lower(trim(c.name))='бисквиты' or exists (
  select 1 from public.ceh_products p where p.category_id=c.id and p.biscuit_parent_id is not null
);
create or replace function public.ceh_seed_biscuit_diameters(parent_id integer)
returns void language sql set search_path = '' as $
  with variants as (
    insert into public.ceh_products(category_id,name,biscuit_parent_id,biscuit_diameter)
    select p.category_id,left(p.name,88) || ' · Ø' || d.size || ' см',p.id,d.size
    from public.ceh_products p join public.ceh_categories c on c.id=p.category_id
    cross join (values (12),(14),(16),(18),(20),(22),(24),(26)) as d(size)
    where p.id=parent_id and p.biscuit_parent_id is null
      and p.archived_at is null and c.archived_at is null and (c.has_biscuit_diameters or lower(trim(c.name))='бисквиты')
    on conflict (biscuit_parent_id,biscuit_diameter) do nothing
    returning id
  )
  insert into public.ceh_stock(product_id,warehouse_id,quantity)
  select variants.id,w.id,0 from variants cross join public.ceh_warehouses w;
$;
create function public.ceh_rename_catalog_entry(entry_category integer, entry_product integer, new_name text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.ceh_profiles where id=auth.uid() and role='admin') then
    raise exception 'Insufficient permissions' using errcode='42501';
  end if;
  new_name := trim(new_name);
  if new_name is null or length(new_name) not between 1 and 100 then
    raise exception 'Invalid name' using errcode='22023';
  end if;
  if entry_product is null then
    update public.ceh_categories set name=new_name, has_biscuit_diameters=has_biscuit_diameters or lower(trim(name))='бисквиты' where id=entry_category and archived_at is null;
  else
    update public.ceh_products p set name=new_name
      from public.ceh_categories c where p.id=entry_product and p.category_id=c.id and c.id=entry_category
      and c.archived_at is null and p.archived_at is null and p.biscuit_parent_id is null;
    if found then
      update public.ceh_products p set name=left(new_name,88) || ' · Ø' || p.biscuit_diameter || ' см'
        where p.biscuit_parent_id=entry_product;
      return;
    end if;
  end if;
  if not found then raise exception 'Entry not found' using errcode='P0002'; end if;
end;
$$;
revoke all on function public.ceh_rename_catalog_entry(integer,integer,text) from public, anon, authenticated;
grant execute on function public.ceh_rename_catalog_entry(integer,integer,text) to authenticated;
commit;
