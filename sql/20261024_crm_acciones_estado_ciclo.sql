-- Migración «crm_acciones_estado_ciclo» (20261024190414), copiada del historial de Supabase el 20/11/2026. Ya está aplicada.

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
    'n_orden', u.n_orden, 'ordenes', jsonb_build_array(u.n_orden), 'periodo', u.periodo,
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
    'n_orden', c.ancla, 'ordenes', to_jsonb(c.ordenes),
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
                   when c.vence - h.h > 90 then 'al_dia'
                   when c.avisado and c.ultimo_aviso > h.h - 30 then 'avisado'
                   when c.vence < h.h then 'vencido'
                   else 'proximo' end,
    'gestiones', coalesce(c.gest, '[]'::jsonb)) j
  from cic_calc c, hoy h
)
select j from uno_json union all select j from cic_json
$$;
