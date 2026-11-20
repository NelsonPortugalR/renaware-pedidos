-- Migración «crm_autocompras» (20261103022250), copiada del historial de Supabase el 20/11/2026. Ya está aplicada.

-- Autocompras: el asesor se compra a sí mismo. El back office lo muestra como cliente y pone
-- de vendedor a su reclutador (o, en pedidos de oficina, pone de cliente los datos de la oficina).
-- Se detectan porque el precio tiene decimales (precio de asesor); los pedidos regulares son exactos.
alter table public.crm_pedidos
  add column if not exists autocompra boolean not null default false,
  add column if not exists vendedor_bo text,
  add column if not exists id_vendedor_bo bigint,
  add column if not exists cliente_bo text,
  add column if not exists celular_bo text;

create or replace function public.crm_nz(t text) returns text language sql immutable as $$
  select regexp_replace(lower(translate(btrim(coalesce(t, '')), 'ÁÉÍÓÚÜÑáéíóúüñ', 'AEIOUUNaeiouun')), '\s+', ' ', 'g') $$;

create or replace function public.crm_cel9(t text) returns text language sql immutable as $$
  select right(regexp_replace(coalesce(t, ''), '\D', '', 'g'), 9) $$;

-- precio con decimales: montos de los productos (o, si no hay, total sin intereses ni gastos)
create or replace function public.crm_es_autocompra(p_productos text, p_total numeric, p_interes numeric, p_expenses numeric)
returns boolean language sql immutable as $$
  select coalesce(
    (select bool_or(a <> trunc(a)) from (select replace(m[1], ',', '')::numeric a
        from regexp_matches(coalesce(p_productos, ''), '\(x\d+ S/([\d,]+(?:\.\d+)?)\)', 'g') m) s where a > 0),
    (p_total - coalesce(p_interes, 0) - coalesce(p_expenses, 0)) <> trunc(p_total - coalesce(p_interes, 0) - coalesce(p_expenses, 0)),
    false) $$;

-- código del asesor: el que Rena Ware le pone cuando figura como vendedor (el más usado); si no, el del registro del equipo
create or replace function public.crm_codigo_asesor(p_nombre text) returns bigint language sql stable set search_path to 'public' as $$
  select coalesce(
    (select x.id_vendedor from crm_pedidos x where crm_nz(x.vendedor) = crm_nz(p_nombre) and x.vendedor_bo is null and x.id_vendedor is not null
      group by x.id_vendedor order by count(*) desc, x.id_vendedor desc limit 1),
    (select e.codigo_asesor::bigint from eq_personas e where crm_nz(e.nombre) = crm_nz(p_nombre) and e.codigo_asesor ~ '^\d{4,8}$' order by e.activo desc limit 1)) $$;

create or replace function public.tg_crm_autocompra() returns trigger language plpgsql set search_path to 'public' as $$
declare v_cel text; v_rec text; v_comp int;
begin
  new.autocompra := crm_es_autocompra(new.productos, new.total, new.interes, new.expenses);
  if not new.autocompra then return new; end if;
  -- pedido de oficina: sale de cliente la oficina (Nelson) y de vendedor el asesor que compra
  if crm_nz(new.cliente) = 'nelson portugal roman' and crm_nz(new.vendedor) <> crm_nz(new.cliente) then
    new.cliente_bo := coalesce(new.cliente_bo, new.cliente);
    new.cliente := new.vendedor;
  elsif crm_nz(new.vendedor) <> crm_nz(new.cliente) then
    -- autocompra normal: de vendedor sale el reclutador; el vendedor real es el mismo cliente
    new.vendedor_bo := new.vendedor;
    new.id_vendedor_bo := new.id_vendedor;
    new.vendedor := new.cliente;
    new.id_vendedor := crm_codigo_asesor(new.cliente);
  end if;
  -- celular: si el del pedido es de la oficina (compartido por varios clientes) o del reclutador, va el del asesor
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

drop trigger if exists trg_crm_autocompra on public.crm_pedidos;
create trigger trg_crm_autocompra before insert or update on public.crm_pedidos
  for each row execute function public.tg_crm_autocompra();

-- regla visible en la pestaña Reglas
insert into public.crm_reglas (clave, tipo_regla, nombre, aplica_a, cuando, accion, orden) values
('autocompra', 'una_vez', 'Autocompra (ajuste de datos)', 'Pedidos cuyo precio tiene decimales (precio de asesor; los pedidos regulares son exactos)',
 'Al cargar cada pedido, automático', 'El vendedor pasa a ser el mismo cliente (el asesor que se compró), con su código y su celular; lo que mostraba el back office queda guardado. En pedidos de oficina (cliente = Nelson), el cliente pasa a ser el asesor que compró. No genera mensajes.', 5)
on conflict (clave) do nothing;
