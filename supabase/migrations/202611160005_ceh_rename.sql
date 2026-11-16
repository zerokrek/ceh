begin;
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
    update public.ceh_categories set name=new_name where id=entry_category and archived_at is null;
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
