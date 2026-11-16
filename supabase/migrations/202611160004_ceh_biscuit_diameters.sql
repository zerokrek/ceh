begin;
alter table public.ceh_products add column biscuit_parent_id integer references public.ceh_products(id);
alter table public.ceh_products add column biscuit_diameter integer;
alter table public.ceh_products add constraint ceh_biscuit_variant check (
  (biscuit_parent_id is null and biscuit_diameter is null)
  or (biscuit_parent_id is not null and biscuit_diameter is not null and biscuit_diameter in (12,14,16,18,20,22,24,26))
);
alter table public.ceh_products add unique (biscuit_parent_id,biscuit_diameter);

create function public.ceh_seed_biscuit_diameters(parent_id integer)
returns void language sql set search_path = '' as $$
  with variants as (
    insert into public.ceh_products(category_id,name,biscuit_parent_id,biscuit_diameter)
    select p.category_id,p.name || ' · Ø' || d.size || ' см',p.id,d.size
    from public.ceh_products p join public.ceh_categories c on c.id=p.category_id
    cross join (values (12),(14),(16),(18),(20),(22),(24),(26)) as d(size)
    where p.id=parent_id and p.biscuit_parent_id is null
      and p.archived_at is null and c.archived_at is null and lower(trim(c.name))='бисквиты'
    on conflict (biscuit_parent_id,biscuit_diameter) do nothing
    returning id
  )
  insert into public.ceh_stock(product_id,warehouse_id,quantity)
  select variants.id,w.id,0 from variants cross join public.ceh_warehouses w;
$$;
revoke all on function public.ceh_seed_biscuit_diameters(integer) from public, anon, authenticated;

create function public.ceh_on_biscuit_product()
returns trigger language plpgsql set search_path = '' as $$
begin
  perform public.ceh_seed_biscuit_diameters(new.id);
  return new;
end;
$$;
revoke all on function public.ceh_on_biscuit_product() from public, anon, authenticated;
create trigger ceh_seed_biscuit_variants after insert on public.ceh_products
for each row when (new.biscuit_parent_id is null)
execute function public.ceh_on_biscuit_product();

select public.ceh_seed_biscuit_diameters(id)
from public.ceh_products where biscuit_parent_id is null;

create or replace function public.ceh_archive_catalog_entry(category_id integer, product_id integer)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.ceh_profiles where id = auth.uid() and role = 'admin') then
    raise exception 'Insufficient permissions' using errcode = '42501';
  end if;
  if product_id is null then
    update public.ceh_categories c set archived_at = now()
      where c.id = ceh_archive_catalog_entry.category_id and c.archived_at is null;
  end if;
  update public.ceh_products p set archived_at = now()
    where p.category_id = ceh_archive_catalog_entry.category_id and p.archived_at is null
      and (product_id is null or p.id = product_id or p.biscuit_parent_id = product_id);
end;
$$;
commit;
