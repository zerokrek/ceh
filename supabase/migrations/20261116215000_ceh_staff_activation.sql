begin;

create or replace function public.ceh_activate_staff_after_password_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  staff_login text := old.raw_app_meta_data ->> 'ceh_login';
begin
  if (old.raw_app_meta_data ->> 'ceh_pending_activation') is distinct from 'true'
    or new.encrypted_password is null
    or new.encrypted_password is not distinct from old.encrypted_password then
    return new;
  end if;

  if staff_login is null or staff_login !~ '^konditer[1-4]$'
    or old.email is distinct from staff_login || '@ceh.invalid'
    or new.email is distinct from old.email then
    raise exception 'Некорректная учётная запись кондитера';
  end if;

  insert into public.ceh_profiles (id, login, display_name, role)
  values (new.id, staff_login, 'Кондитер ' || right(staff_login, 1), 'confectioner');

  new.raw_app_meta_data := coalesce(new.raw_app_meta_data, '{}'::jsonb)
    || '{"ceh_pending_activation":false}'::jsonb;
  return new;
end;
$$;

revoke all on function public.ceh_activate_staff_after_password_change() from public, anon, authenticated;

drop trigger if exists ceh_activate_staff_after_password_change on auth.users;
create trigger ceh_activate_staff_after_password_change
before update of encrypted_password on auth.users
for each row execute function public.ceh_activate_staff_after_password_change();

commit;
