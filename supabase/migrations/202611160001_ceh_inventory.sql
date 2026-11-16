begin;

create table public.ceh_profiles (
  id uuid primary key references auth.users(id),
  login text not null unique check (login in ('admin','konditer1','konditer2','konditer3','konditer4')),
  display_name text not null,
  role text not null check (role in ('admin','confectioner')),
  check ((login = 'admin') = (role = 'admin'))
);
create table public.ceh_categories (
  id integer generated always as identity primary key,
  name text not null unique check (length(trim(name)) between 1 and 100)
);
create table public.ceh_products (
  id integer generated always as identity primary key,
  category_id integer not null references public.ceh_categories(id),
  name text not null check (length(trim(name)) between 1 and 100),
  unique (category_id,name)
);
create table public.ceh_warehouses (
  id integer primary key,
  name text not null unique
);
create table public.ceh_stock (
  product_id integer references public.ceh_products(id),
  warehouse_id integer references public.ceh_warehouses(id),
  quantity integer not null default 0 check (quantity >= 0),
  primary key (product_id,warehouse_id)
);
create table public.ceh_stock_log (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.ceh_profiles(id),
  product_id integer not null,
  warehouse_id integer not null,
  quantity_before integer not null,
  quantity_after integer not null,
  created_at timestamptz not null default now(),
  foreign key (product_id,warehouse_id) references public.ceh_stock(product_id,warehouse_id)
);

alter table public.ceh_profiles enable row level security;
alter table public.ceh_categories enable row level security;
alter table public.ceh_products enable row level security;
alter table public.ceh_warehouses enable row level security;
alter table public.ceh_stock enable row level security;
alter table public.ceh_stock_log enable row level security;

revoke all on public.ceh_profiles, public.ceh_categories, public.ceh_products,
  public.ceh_warehouses, public.ceh_stock, public.ceh_stock_log from anon, authenticated;
grant select on public.ceh_profiles, public.ceh_categories, public.ceh_products,
  public.ceh_warehouses, public.ceh_stock, public.ceh_stock_log to authenticated;

create policy ceh_own_profile on public.ceh_profiles for select to authenticated using (id = (select auth.uid()));
create policy ceh_member_categories on public.ceh_categories for select to authenticated using (exists (select 1 from public.ceh_profiles));
create policy ceh_member_products on public.ceh_products for select to authenticated using (exists (select 1 from public.ceh_profiles));
create policy ceh_member_warehouses on public.ceh_warehouses for select to authenticated using (exists (select 1 from public.ceh_profiles));
create policy ceh_member_stock on public.ceh_stock for select to authenticated using (exists (select 1 from public.ceh_profiles));
create policy ceh_admin_log on public.ceh_stock_log for select to authenticated using (exists (select 1 from public.ceh_profiles where role = 'admin'));

create function public.ceh_save_stock(changes jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := auth.uid();
  change record;
  previous integer;
begin
  if not exists (select 1 from public.ceh_profiles where id = actor and role = 'confectioner') then
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

revoke all on function public.ceh_save_stock(jsonb) from public, anon, authenticated;
grant execute on function public.ceh_save_stock(jsonb) to authenticated;

insert into public.ceh_warehouses values (1,'Склад 1'),(2,'Склад 2');
insert into public.ceh_categories(name) values ('Муссы'),('Бисквиты'),('Крошка'),('Капы'),('Нарезка'),('Корпусные');
insert into public.ceh_products(category_id,name)
  select id, product.name from public.ceh_categories
  cross join (values ('Сердечко'),('Мусс-бомбочка')) as product(name)
  where ceh_categories.name = 'Муссы';
insert into public.ceh_stock(product_id,warehouse_id,quantity)
  select p.id, w.id, case p.name
    when 'Сердечко' then case w.id when 1 then 10 else 5 end
    else case w.id when 1 then 17 else 4 end
  end
  from public.ceh_products p cross join public.ceh_warehouses w;

commit;
