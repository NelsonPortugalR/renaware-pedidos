-- Migración «crm_postventa_gestiones» (20261118015210), copiada del historial de Supabase el 20/11/2026. Ya está aplicada.

-- Historial de gestiones de post venta (llamadas, WhatsApp, visitas) por cliente y repuesto
create table if not exists public.crm_gestiones (
  id bigint generated always as identity primary key,
  cliente_id uuid not null,
  tipo text not null default 'prefiltro',
  n_orden bigint,
  fecha timestamptz not null default now(),
  canal text not null default 'llamada' check (canal in ('llamada_auto','llamada','whatsapp','visita')),
  intento smallint check (intento between 1 and 9),
  resultado text not null check (resultado in ('pidio_visita','no_desea','contesto','colgo','buzon','no_contesta','numero_errado')),
  etapa smallint check (etapa between 1 and 3),
  accion text check (accion in ('enviar_video','coordinar_visita','volver_a_llamar','ninguna')),
  accion_fecha date,
  nota text check (char_length(nota) <= 1500),
  call_id text check (char_length(call_id) <= 120),
  grabacion_url text check (char_length(grabacion_url) <= 500),
  origen text not null default 'portal' check (origen in ('portal','bot','campana')),
  lote text,
  anulado boolean not null default false,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create index if not exists crm_gestiones_cli on public.crm_gestiones (cliente_id, tipo, fecha desc);
alter table public.crm_gestiones enable row level security;
drop policy if exists crm_gestiones_rw on public.crm_gestiones;
create policy crm_gestiones_rw on public.crm_gestiones for all to authenticated
  using ((auth.jwt() ->> 'email') = any (array['CORREO_OFICINA_1','CORREO_OFICINA_2']))
  with check ((auth.jwt() ->> 'email') = any (array['CORREO_OFICINA_1','CORREO_OFICINA_2']));

-- Datos de post venta por cliente (no toca la tabla clientes del registro)
create table if not exists public.crm_cliente_post (
  cliente_id uuid primary key,
  asesor_seguimiento text,
  excluido_hasta date,
  excluido_motivo text check (char_length(excluido_motivo) <= 300),
  referencia text check (char_length(referencia) <= 300),
  actualizado timestamptz not null default now()
);
alter table public.crm_cliente_post enable row level security;
drop policy if exists crm_cliente_post_rw on public.crm_cliente_post;
create policy crm_cliente_post_rw on public.crm_cliente_post for all to authenticated
  using ((auth.jwt() ->> 'email') = any (array['CORREO_OFICINA_1','CORREO_OFICINA_2']))
  with check ((auth.jwt() ->> 'email') = any (array['CORREO_OFICINA_1','CORREO_OFICINA_2']));

-- "Compró por su cuenta": reinicia el ciclo como un cambio, pero no gasta un repuesto del kit
alter table public.crm_seguimiento drop constraint if exists crm_seguimiento_modo_chk;
alter table public.crm_seguimiento add constraint crm_seguimiento_modo_chk
  check (modo = any (array['cambio','whatsapp','aviso','omitido','noaplica','por_su_cuenta']));

-- Corrección manual del cliente de un pedido (ej. cliente comodín); sobrevive a nuevas cargas
alter table public.crm_pedidos
  add column if not exists cliente_corregido boolean not null default false,
  add column if not exists direccion_bo text;

create or replace function public.tg_crm_autocompra() returns trigger language plpgsql set search_path to 'public' as $$
declare v_cel text; v_rec text; v_comp int;
begin
  -- 1) correcciones manuales: si una carga trae de nuevo el dato del back office, se mantiene el corregido
  if tg_op = 'UPDATE' and old.cliente_corregido then
    new.cliente_corregido := true;
    new.cliente_bo := coalesce(new.cliente_bo, old.cliente_bo);
    new.celular_bo := coalesce(new.celular_bo, old.celular_bo);
    new.direccion_bo := coalesce(new.direccion_bo, old.direccion_bo);
    if new.cliente is distinct from old.cliente and crm_nz(new.cliente) = crm_nz(old.cliente_bo) then new.cliente := old.cliente; end if;
    if new.celular is distinct from old.celular and crm_cel9(new.celular) = crm_cel9(old.celular_bo) then new.celular := old.celular; end if;
    if new.direccion is distinct from old.direccion and new.direccion = old.direccion_bo then new.direccion := old.direccion; end if;
  end if;
  -- 2) autocompras
  new.autocompra := crm_es_autocompra(new.productos, new.total, new.interes, new.expenses);
  if not new.autocompra or new.cliente_corregido then return new; end if;
  if crm_nz(new.cliente) = 'nelson portugal roman' and crm_nz(new.vendedor) <> crm_nz(new.cliente) then
    new.cliente_bo := coalesce(new.cliente_bo, new.cliente);
    new.cliente := new.vendedor;
  elsif crm_nz(new.vendedor) <> crm_nz(new.cliente) then
    new.vendedor_bo := new.vendedor;
    new.id_vendedor_bo := new.id_vendedor;
    new.vendedor := new.cliente;
    new.id_vendedor := crm_codigo_asesor(new.cliente);
  end if;
  select e.celular into v_cel from eq_personas e where crm_nz(e.nombre) = crm_nz(new.cliente) and coalesce(e.celular, '') <> '' order by e.activo desc limit 1;
  if v_cel is not null and crm_cel9(v_cel) <> crm_cel9(new.celular) then
    select e.celular into v_rec from eq_personas e where crm_nz(e.nombre) = crm_nz(coalesce(new.vendedor_bo, '')) limit 1;
    select count(distinct crm_nz(x.cliente)) into v_comp from crm_pedidos x where crm_cel9(x.celular) = crm_cel9(new.celular) and crm_cel9(new.celular) <> '';
    if crm_cel9(new.celular) = '' or v_comp >= 3 or (v_rec is not null and crm_cel9(v_rec) = crm_cel9(new.celular)) then
      new.celular_bo := coalesce(new.celular_bo, new.celular);
      new.celular := v_cel;
    end if;
  end if;
  return new;
end $$;

create or replace function public.crm_pedido_corregir_cliente(p_n_orden bigint, p_cliente text, p_celular text, p_direccion text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare r crm_pedidos;
begin
  if coalesce(auth.jwt() ->> 'email', '') not in ('CORREO_OFICINA_1','CORREO_OFICINA_2') then raise exception 'Sin permiso'; end if;
  if nullif(btrim(p_cliente), '') is null then raise exception 'Falta el nombre del cliente'; end if;
  if nullif(btrim(p_celular), '') is not null and crm_cel9(p_celular) !~ '^9\d{8}$' then raise exception 'El celular debe tener 9 dígitos y empezar en 9'; end if;
  update crm_pedidos c set
    cliente_bo = coalesce(c.cliente_bo, c.cliente),
    celular_bo = case when nullif(btrim(p_celular), '') is not null then coalesce(c.celular_bo, c.celular) else c.celular_bo end,
    direccion_bo = case when nullif(btrim(p_direccion), '') is not null then coalesce(c.direccion_bo, c.direccion) else c.direccion_bo end,
    cliente = btrim(p_cliente),
    celular = coalesce(nullif(crm_cel9(p_celular), ''), c.celular),
    direccion = coalesce(nullif(btrim(p_direccion), ''), c.direccion),
    cliente_corregido = true, updated_at = now()
  where c.n_orden = p_n_orden returning * into r;
  if r.n_orden is null then raise exception 'La orden no existe'; end if;
  return jsonb_build_object('n_orden', r.n_orden, 'cliente', r.cliente, 'celular', r.celular, 'direccion', r.direccion, 'cliente_id', r.cliente_id);
end $$;
revoke all on function public.crm_pedido_corregir_cliente(bigint, text, text, text) from public, anon;
grant execute on function public.crm_pedido_corregir_cliente(bigint, text, text, text) to authenticated;

-- Acceso del bot de post venta: clave propia, solo leer pendientes y registrar gestiones
create table if not exists public.crm_bot_claves (
  id bigint generated always as identity primary key,
  nombre text not null,
  hash text not null unique,
  activo boolean not null default true,
  creado_en timestamptz not null default now(),
  ultimo_uso timestamptz
);
alter table public.crm_bot_claves enable row level security;
drop policy if exists crm_bot_claves_ver on public.crm_bot_claves;
create policy crm_bot_claves_ver on public.crm_bot_claves for select to authenticated
  using ((auth.jwt() ->> 'email') = any (array['CORREO_OFICINA_1','CORREO_OFICINA_2']));

create or replace function public.crm_bot_clave_crear(p_nombre text) returns text
language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare v text;
begin
  if coalesce(auth.jwt() ->> 'email', '') not in ('CORREO_OFICINA_1','CORREO_OFICINA_2') then raise exception 'Sin permiso'; end if;
  v := 'rwpv_' || encode(gen_random_bytes(24), 'hex');
  insert into crm_bot_claves (nombre, hash) values (coalesce(nullif(btrim(p_nombre), ''), 'Bot post venta'), encode(digest(v, 'sha256'), 'hex'));
  return v;  -- se muestra una sola vez; solo se guarda el hash
end $$;
create or replace function public.crm_bot_clave_anular(p_id bigint) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  if coalesce(auth.jwt() ->> 'email', '') not in ('CORREO_OFICINA_1','CORREO_OFICINA_2') then raise exception 'Sin permiso'; end if;
  update crm_bot_claves set activo = false where id = p_id;
end $$;
create or replace function public.crm_bot_valida(p_clave text) returns boolean
language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare v_id bigint;
begin
  select id into v_id from crm_bot_claves where activo and hash = encode(digest(coalesce(p_clave, ''), 'sha256'), 'hex');
  if v_id is null then return false; end if;
  update crm_bot_claves set ultimo_uso = now() where id = v_id;
  return true;
end $$;
revoke all on function public.crm_bot_clave_crear(text) from public, anon;
revoke all on function public.crm_bot_clave_anular(bigint) from public, anon;
revoke all on function public.crm_bot_valida(text) from public, anon, authenticated;
grant execute on function public.crm_bot_clave_crear(text) to authenticated;
grant execute on function public.crm_bot_clave_anular(bigint) to authenticated;
