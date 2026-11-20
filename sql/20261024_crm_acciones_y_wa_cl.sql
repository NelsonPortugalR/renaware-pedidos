-- Migración «crm_acciones_y_wa_cl» (20261024185945), copiada del historial de Supabase el 20/11/2026. Ya está aplicada.

-- Seguimiento de clientes: una sola fuente de verdad (crm_acciones) que leen
-- Pedidos (con sesión Supabase) y Bienvenida (con sesión admin, vía wa_cl_*).

alter table public.crm_seguimiento
  add column if not exists modo text not null default 'cambio',
  add column if not exists texto text,
  add column if not exists anulado boolean not null default false,
  add column if not exists cliente_id uuid;
alter table public.crm_seguimiento drop constraint if exists crm_seguimiento_modo_chk;
alter table public.crm_seguimiento add constraint crm_seguimiento_modo_chk
  check (modo in ('cambio', 'whatsapp', 'aviso', 'omitido', 'noaplica'));
alter table public.crm_seguimiento drop constraint if exists crm_seguimiento_tipo_chk;
alter table public.crm_seguimiento add constraint crm_seguimiento_tipo_chk
  check (tipo in ('bienvenida', 'semana1', 'mes1', 'fincuotas', 'prefiltro', 'filtroppal', 'aire'));
create index if not exists crm_seguimiento_orden_idx on public.crm_seguimiento (n_orden, tipo) where not anulado;

alter table public.clientes add column if not exists trato text;
alter table public.clientes drop constraint if exists clientes_trato_chk;
alter table public.clientes add constraint clientes_trato_chk check (trato is null or trato in ('tu', 'usted'));

create or replace function public.crm_fecha(p text) returns date
language sql immutable set search_path = public as $$
  select case when p ~ '^\d{1,2}/\d{1,2}/\d{4}' then to_date(substring(p from '^\d{1,2}/\d{1,2}/\d{4}'), 'FMDD/FMMM/YYYY') end
$$;

create or replace function public.crm_acciones(p_hoy date default null)
returns setof jsonb
language sql stable set search_path = public as $$
with hoy as (select coalesce(p_hoy, public.hoy_lima()) h),
ped as (
  select c.n_orden, c.cliente_id, c.cliente, c.celular, c.ciudad, c.vendedor, c.productos, c.credito_contado, c.cuotas, c.total, c.periodo,
         public.crm_fecha(c.delivery_date) entrega, public.crm_fecha(c.fecha_ordenado) ordenado,
         coalesce(public.crm_fecha(c.delivery_date), public.crm_fecha(c.fecha_ordenado)) base,
         upper(coalesce(c.productos, '')) prod
    from public.crm_pedidos c
   where coalesce(c.estatus, '') ~* 'ENTREGADA'
),
flags as (
  select p.*,
    p.prod ~ '(COOKER|OLLA|CACEROLA|SIGNATURE|PRINCESA|RENAWOK|RENA WOK|SAUCEPAN|SAUCIER|RONDEAU|ASADOR|CONTESSA|PRESSURE)' as f_ollas,
    p.prod ~ '(SARTÉN|SARTEN|SKILLET)' as f_sartenes,
    p.prod ~ '(AQUA NANO|FILTRO DE AGUA|AQUA CHECK NANO 500 UCU|LX-500)' as f_filtro,
    p.prod ~ '(INDUCTION COOKER|COCINA DE INDUCC|IC-450|IC-350|IC-400|SW-3000)' as f_cocina,
    p.prod ~ '(OLLA A PRESI|PRESSURE)' as f_presion,
    p.prod ~ '(PURIFICADOR DE AIRE|AIR PURIFIER|RENA AIR|PURIFICADOR AIRE|AERO ?QUATTRO)' as f_aire,
    exists (select 1 from unnest(string_to_array(p.prod, '|')) it
             where it ~ '(AQUA NANO|AQUA CHECK NANO 500 CTU \(UNID|AQUA CHECK NANO 500 UCU|LX-500)'
               and it !~ '(PREFILTRO|PRE-FILTRO|PRE FILTRO|ELEMENTO DESECHABLE|ELEMENTO AQ HD|ALOJAMIENTO REU)') as sys_agua,
    p.prod ~ '(PURIFICADOR DE AIRE|AIR PURIFIER|RENA AIR|PURIFICADOR AIRE|AERO ?QUATTRO)' as sys_aire,
    p.prod ~ '(PREFILTRO|PRE-FILTRO|PRE FILTRO)' as rep_pre,
    p.prod ~ '(ELEMENTO DESECHABLE|ELEMENTO AQ HD|ALOJAMIENTO REU)' as rep_ppal,
    p.prod ~ '(FILTRO HEPA|FILTRO DE AIRE|FILTRO PARA PURIFICADOR|FILTRO AERO)' as rep_aire
  from ped p
),
seg as (
  select s.id, s.n_orden, s.tipo, s.modo, s.texto, s.nota, s.created_at, public.crm_fecha(s.fecha_gestion) f,
         coalesce(s.cliente_id, c.cliente_id) cliente_id
    from public.crm_seguimiento s left join public.crm_pedidos c on c.n_orden = s.n_orden
   where not s.anulado
),
uno as (
  select f.n_orden, 'bienvenida'::text tipo, f.base vence from flags f where f.base is not null
  union all select f.n_orden, 'semana1', f.base + 7 from flags f where f.base is not null and f.f_ollas
  union all select f.n_orden, 'mes1', f.base + 30 from flags f where f.base is not null and f.f_ollas
  union all select f.n_orden, 'fincuotas', (f.ordenado + make_interval(months => f.cuotas - 1))::date
              from flags f where f.ordenado is not null and f.credito_contado ilike 'cr%' and coalesce(f.cuotas, 0) > 0
),
uno_est as (
  select f.*, u.tipo, u.vence,
         (select jsonb_agg(jsonb_build_object('id', s.id, 'modo', s.modo, 'fecha', s.f, 'texto', s.texto, 'n_orden', s.n_orden) order by s.f, s.created_at)
            from seg s where s.n_orden = u.n_orden and s.tipo = u.tipo) gest,
         (select max(s.f) from seg s where s.n_orden = u.n_orden and s.tipo = u.tipo and s.modo in ('whatsapp', 'aviso')) hecho_el,
         (select max(s.f) from seg s where s.n_orden = u.n_orden and s.tipo = u.tipo and s.modo = 'omitido') omitido_el,
         (select max(s.f) from seg s where s.n_orden = u.n_orden and s.tipo = u.tipo and s.modo = 'noaplica') noaplica_el
    from uno u join flags f on f.n_orden = u.n_orden
),
uno_json as (
  select jsonb_build_object(
    'clave', u.n_orden || '::' || u.tipo, 'clase', 'uno', 'tipo', u.tipo,
    'cliente_id', u.cliente_id, 'cliente', u.cliente, 'celular', u.celular, 'ciudad', u.ciudad, 'vendedor', u.vendedor,
    'n_orden', u.n_orden, 'ordenes', jsonb_build_array(u.n_orden), 'productos', u.productos, 'periodo', u.periodo,
    'flags', jsonb_build_object('ollas', u.f_ollas, 'sartenes', u.f_sartenes, 'filtro', u.f_filtro, 'cocina', u.f_cocina, 'presion', u.f_presion, 'aire', u.f_aire),
    'entrega', u.entrega, 'ordenado', u.ordenado, 'base', u.base, 'vence', u.vence, 'dias', (u.vence - h.h),
    'cuotas', u.cuotas, 'credito', (u.credito_contado ilike 'cr%'), 'total', u.total,
    'estado', case when u.hecho_el is not null then 'hecho'
                   when u.omitido_el is not null or u.noaplica_el is not null then 'omitido'
                   when u.vence - h.h < -45 then 'caducado'
                   when u.vence < h.h then 'vencido'
                   when u.vence - h.h <= 30 then 'proximo'
                   else 'pendiente' end,
    'hecho_el', u.hecho_el, 'gestiones', coalesce(u.gest, '[]'::jsonb)) j
  from uno_est u, hoy h
),
kinds as (select * from (values ('prefiltro', 12), ('filtroppal', 48), ('aire', 18)) k(tipo, intervalo)),
cic_ord as (
  select k.tipo, k.intervalo, f.cliente_id, f.n_orden, f.base, f.cliente, f.celular, f.ciudad, f.vendedor, f.productos, f.prod,
         case k.tipo when 'aire' then f.sys_aire else f.sys_agua end es_sys,
         case k.tipo when 'prefiltro' then f.rep_pre when 'filtroppal' then f.rep_ppal else f.rep_aire end es_rep
    from flags f cross join kinds k
   where f.base is not null and f.cliente_id is not null
     and (case k.tipo when 'aire' then f.sys_aire or f.rep_aire else f.sys_agua or f.rep_pre or f.rep_ppal end)
),
cic as (
  select o.tipo, o.intervalo, o.cliente_id,
         max(o.base) filter (where o.es_sys) sys_date,
         max(o.base) filter (where o.es_rep) rep_date,
         count(*) filter (where o.es_rep) reps,
         array_agg(o.n_orden order by o.base desc, o.n_orden desc) ordenes,
         (array_agg(o.n_orden order by o.es_sys desc, o.base desc, o.n_orden desc))[1] ancla
    from cic_ord o
   group by o.tipo, o.intervalo, o.cliente_id
  having max(o.base) filter (where o.es_sys) is not null or max(o.base) filter (where o.es_rep) is not null
),
cic_est as (
  select c.*, greatest(c.sys_date, c.rep_date) base, a.cliente, a.celular, a.ciudad, a.vendedor, a.productos, a.prod,
         (select jsonb_agg(jsonb_build_object('id', s.id, 'modo', s.modo, 'fecha', s.f, 'texto', s.texto, 'n_orden', s.n_orden) order by s.f, s.created_at)
            from seg s where s.tipo = c.tipo and (s.cliente_id = c.cliente_id or s.n_orden = any (c.ordenes))) gest,
         (select max(s.f) from seg s where s.tipo = c.tipo and s.modo = 'cambio' and (s.cliente_id = c.cliente_id or s.n_orden = any (c.ordenes))) ultimo_cambio,
         (select count(*) from seg s where s.tipo = c.tipo and s.modo = 'cambio' and (s.cliente_id = c.cliente_id or s.n_orden = any (c.ordenes))) cambios,
         (select max(s.f) from seg s where s.tipo = c.tipo and s.modo = 'noaplica' and (s.cliente_id = c.cliente_id or s.n_orden = any (c.ordenes))) noaplica_el,
         (select max(s.f) from seg s where s.tipo = c.tipo and s.modo in ('whatsapp', 'aviso', 'omitido') and (s.cliente_id = c.cliente_id or s.n_orden = any (c.ordenes))) ultimo_aviso
    from cic c join flags a on a.n_orden = c.ancla
),
cic_calc as (
  select c.*, (greatest(c.base, c.ultimo_cambio) + make_interval(months => c.intervalo))::date vence,
         (c.noaplica_el is not null and c.noaplica_el >= greatest(c.base, c.ultimo_cambio)) cerrado,
         (c.ultimo_aviso is not null and c.ultimo_aviso >= greatest(c.base, c.ultimo_cambio)) avisado
    from cic_est c
),
cic_json as (
  select jsonb_build_object(
    'clave', c.cliente_id || '::' || c.tipo, 'clase', 'ciclo', 'tipo', c.tipo, 'intervalo', c.intervalo,
    'cliente_id', c.cliente_id, 'cliente', c.cliente, 'celular', c.celular, 'ciudad', c.ciudad, 'vendedor', c.vendedor,
    'n_orden', c.ancla, 'ordenes', to_jsonb(c.ordenes), 'productos', c.productos,
    'sistema', case when c.sys_date is null then null
                    else coalesce((select btrim(regexp_replace(it, '\s*\((x\d+ )?S/[^)]*\)\s*$', '')) from unnest(string_to_array(c.productos, '|')) it
                                   where upper(it) ~ (case c.tipo when 'aire' then '(PURIFICADOR DE AIRE|AIR PURIFIER|RENA AIR|PURIFICADOR AIRE|AERO ?QUATTRO)' else '(AQUA NANO|AQUA CHECK NANO 500 CTU \(UNID|AQUA CHECK NANO 500 UCU|LX-500)' end)
                                     and upper(it) !~ '(PREFILTRO|PRE-FILTRO|ELEMENTO DESECHABLE|ELEMENTO AQ HD|ALOJAMIENTO REU)' limit 1),
                                  case c.tipo when 'aire' then 'Purificador de aire' else 'Aqua Nano' end) end,
    'fecha_sistema', c.sys_date, 'fecha_repuesto', c.rep_date, 'repuestos', c.reps,
    'src', case when c.rep_date is not null and (c.sys_date is null or c.rep_date >= c.sys_date) then 'repuesto' else 'sistema' end,
    'base', c.base, 'vence', c.vence, 'dias', (c.vence - h.h),
    'ultimo_cambio', c.ultimo_cambio, 'cambios', c.cambios, 'ultimo_aviso', c.ultimo_aviso,
    'estado', case when c.cerrado then 'cerrado'
                   when c.avisado and c.ultimo_aviso > h.h - 30 then 'avisado'
                   when c.vence < h.h then 'vencido'
                   when c.vence - h.h <= 90 then 'proximo'
                   else 'al_dia' end,
    'gestiones', coalesce(c.gest, '[]'::jsonb)) j
  from cic_calc c, hoy h
)
select j from uno_json union all select j from cic_json
$$;
grant execute on function public.crm_acciones(date) to authenticated;
revoke execute on function public.crm_acciones(date) from anon;

create or replace function public.wa_cl_cliente_json(p_cliente uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', c.id, 'nombre', coalesce(c.nombre, (select p.cliente from public.crm_pedidos p where p.cliente_id = c.id order by p.n_orden desc limit 1)),
    'celular', coalesce((select p.celular from public.crm_pedidos p where p.cliente_id = c.id and coalesce(p.celular, '') <> '' order by p.n_orden desc limit 1), c.celular),
    'ciudad', (select p.ciudad from public.crm_pedidos p where p.cliente_id = c.id order by p.n_orden desc limit 1),
    'trato', c.trato,
    'ordenes', coalesce((select jsonb_agg(jsonb_build_object('n_orden', p.n_orden, 'fecha', coalesce(public.crm_fecha(p.delivery_date), public.crm_fecha(p.fecha_ordenado)),
                                                            'estatus', p.estatus, 'productos', p.productos, 'total', p.total, 'vendedor', p.vendedor,
                                                            'credito', p.credito_contado ilike 'cr%', 'cuotas', p.cuotas) order by p.n_orden desc)
                          from public.crm_pedidos p where p.cliente_id = c.id), '[]'::jsonb),
    'acciones', coalesce((select jsonb_agg(a order by a->>'vence') from public.crm_acciones() a where (a->>'cliente_id')::uuid = c.id), '[]'::jsonb))
  from public.clientes c where c.id = p_cliente
$$;
revoke all on function public.wa_cl_cliente_json(uuid) from public, anon, authenticated;

create or replace function public.wa_cl_datos(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_hoy date := public.hoy_lima(); v_acc jsonb; v_cli jsonb;
begin
  if not public.es_admin(p_token) then raise exception 'Sesion invalida'; end if;
  select coalesce(jsonb_agg(a), '[]'::jsonb) into v_acc
    from public.crm_acciones(v_hoy) a
   where a->>'clase' = 'ciclo'
      or a->>'estado' in ('vencido', 'proximo')
      or (a->>'estado' = 'pendiente' and (a->>'dias')::int <= 60)
      or (a->>'estado' in ('hecho', 'omitido') and (a->>'vence')::date >= v_hoy - 90);
  select coalesce(jsonb_agg(x), '[]'::jsonb) into v_cli
    from (select distinct (a->>'cliente_id')::uuid cid from jsonb_array_elements(v_acc) a where a->>'cliente_id' is not null) ids
    cross join lateral (select jsonb_build_object('id', c.id, 'nombre', coalesce(c.nombre, (select p.cliente from public.crm_pedidos p where p.cliente_id = c.id order by p.n_orden desc limit 1)),
                                 'celular', coalesce((select p.celular from public.crm_pedidos p where p.cliente_id = c.id and coalesce(p.celular, '') <> '' order by p.n_orden desc limit 1), c.celular),
                                 'ciudad', (select p.ciudad from public.crm_pedidos p where p.cliente_id = c.id order by p.n_orden desc limit 1),
                                 'trato', c.trato,
                                 'ordenes', coalesce((select jsonb_agg(jsonb_build_object('n_orden', p.n_orden, 'fecha', coalesce(public.crm_fecha(p.delivery_date), public.crm_fecha(p.fecha_ordenado)),
                                                            'estatus', p.estatus, 'productos', p.productos, 'total', p.total, 'vendedor', p.vendedor,
                                                            'credito', p.credito_contado ilike 'cr%', 'cuotas', p.cuotas) order by p.n_orden desc)
                                                       from public.crm_pedidos p where p.cliente_id = c.id), '[]'::jsonb)) x
                          from public.clientes c where c.id = ids.cid) x;
  return jsonb_build_object('hoy', v_hoy, 'acciones', v_acc, 'clientes', v_cli,
    'oficina', coalesce((select a.data from public.wa_bv_ajustes a where a.id = 'vigente'), '{}'::jsonb),
    'adjuntos', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'dia', a.dia, 'orden', a.orden, 'tipo', a.tipo, 'nombre', a.nombre, 'descripcion', a.descripcion,
                                                            'ruta', a.ruta, 'archivo', a.archivo, 'bytes', a.bytes, 'content_type', a.content_type) order by a.dia, a.orden, a.creado_en)
                           from public.wa_bv_adjuntos a where not a.borrado and a.dia between 11 and 20), '[]'::jsonb),
    'plantillas', public.n0_plantillas_json(),
    'trato', (select c.trato from public.n0_config c where c.id = 'vigente'));
end $$;
grant execute on function public.wa_cl_datos(uuid) to anon, authenticated;

create or replace function public.wa_cl_envio_registrar(p_token uuid, p_n_orden bigint, p_tipo text, p_modo text, p_texto text, p_fecha date default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_cli uuid; v_f date := coalesce(p_fecha, public.hoy_lima());
begin
  if not public.es_admin(p_token) then raise exception 'Sesion invalida'; end if;
  select cliente_id into v_cli from public.crm_pedidos where n_orden = p_n_orden;
  if v_cli is null then raise exception 'La orden no existe'; end if;
  if coalesce(p_tipo, '') not in ('bienvenida', 'semana1', 'mes1', 'fincuotas', 'prefiltro', 'filtroppal', 'aire') then raise exception 'Paso no valido'; end if;
  if coalesce(p_modo, '') not in ('whatsapp', 'aviso', 'omitido', 'cambio', 'noaplica') then raise exception 'Modo no valido'; end if;
  if v_f > public.hoy_lima() or v_f < date '2015-01-01' then raise exception 'Fecha no valida'; end if;
  if not exists (select 1 from public.crm_seguimiento s where s.n_orden = p_n_orden and s.tipo = p_tipo and s.modo = p_modo and not s.anulado and s.created_at > now() - interval '10 minutes') then
    insert into public.crm_seguimiento (n_orden, tipo, fecha_gestion, modo, texto, cliente_id)
    values (p_n_orden, p_tipo, to_char(v_f, 'DD/MM/YYYY'), p_modo, left(nullif(btrim(p_texto), ''), 1500), v_cli);
  end if;
  return public.wa_cl_cliente_json(v_cli);
end $$;
grant execute on function public.wa_cl_envio_registrar(uuid, bigint, text, text, text, date) to anon, authenticated;

create or replace function public.wa_cl_envio_anular(p_token uuid, p_id bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_cli uuid;
begin
  if not public.es_admin(p_token) then raise exception 'Sesion invalida'; end if;
  update public.crm_seguimiento s set anulado = true where s.id = p_id and not s.anulado
    returning coalesce(s.cliente_id, (select cliente_id from public.crm_pedidos p where p.n_orden = s.n_orden)) into v_cli;
  if v_cli is null then raise exception 'La gestion ya no existe'; end if;
  return public.wa_cl_cliente_json(v_cli);
end $$;
grant execute on function public.wa_cl_envio_anular(uuid, bigint) to anon, authenticated;

create or replace function public.wa_cl_trato_guardar(p_token uuid, p_cliente uuid, p_trato text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.es_admin(p_token) then raise exception 'Sesion invalida'; end if;
  if p_trato is not null and p_trato not in ('tu', 'usted') then raise exception 'Trato no valido'; end if;
  update public.clientes set trato = p_trato, actualizado_en = now() where id = p_cliente;
  if not found then raise exception 'La persona no existe'; end if;
  return public.wa_cl_cliente_json(p_cliente);
end $$;
grant execute on function public.wa_cl_trato_guardar(uuid, uuid, text) to anon, authenticated;

create or replace function public.wa_bv_adjunto_guardar(p_token uuid, p_id uuid, p_datos jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r public.wa_bv_adjuntos; v_dia int;
begin
  if not public.es_admin(p_token) then raise exception 'Sesion invalida'; end if;
  if p_datos is null or jsonb_typeof(p_datos) <> 'object' then raise exception 'Datos no validos'; end if;
  if p_id is null then
    v_dia := (p_datos->>'dia')::int;
    if v_dia is null or not (v_dia between 1 and 5 or v_dia between 11 and 20) then raise exception 'Dia no valido'; end if;
    insert into public.wa_bv_adjuntos (dia, orden, tipo, nombre, descripcion, ruta, archivo, bytes, content_type)
    values (v_dia,
            coalesce((p_datos->>'orden')::int, (select coalesce(max(a.orden), 0) + 1 from public.wa_bv_adjuntos a where a.dia = v_dia and not a.borrado)),
            coalesce(p_datos->>'tipo', 'pdf'), left(coalesce(p_datos->>'nombre', ''), 120), left(coalesce(p_datos->>'descripcion', ''), 1000),
            p_datos->>'ruta', p_datos->>'archivo', (p_datos->>'bytes')::bigint, p_datos->>'content_type')
    returning * into r;
  else
    update public.wa_bv_adjuntos a set
      tipo = case when p_datos ? 'tipo' then coalesce(p_datos->>'tipo', a.tipo) else a.tipo end,
      nombre = case when p_datos ? 'nombre' then left(coalesce(p_datos->>'nombre', ''), 120) else a.nombre end,
      descripcion = case when p_datos ? 'descripcion' then left(coalesce(p_datos->>'descripcion', ''), 1000) else a.descripcion end,
      ruta = case when p_datos ? 'ruta' then p_datos->>'ruta' else a.ruta end,
      archivo = case when p_datos ? 'archivo' then p_datos->>'archivo' else a.archivo end,
      bytes = case when p_datos ? 'bytes' then (p_datos->>'bytes')::bigint else a.bytes end,
      content_type = case when p_datos ? 'content_type' then p_datos->>'content_type' else a.content_type end,
      orden = case when p_datos ? 'orden' then (p_datos->>'orden')::int else a.orden end,
      actualizado_en = now()
    where a.id = p_id and not a.borrado
    returning * into r;
    if not found then raise exception 'El archivo ya no existe'; end if;
  end if;
  return jsonb_build_object('id', r.id, 'dia', r.dia, 'orden', r.orden, 'tipo', r.tipo, 'nombre', r.nombre, 'descripcion', r.descripcion,
                            'ruta', r.ruta, 'archivo', r.archivo, 'bytes', r.bytes, 'content_type', r.content_type);
end $$;
