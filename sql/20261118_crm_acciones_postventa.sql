-- Migración «crm_acciones_postventa» (20261118015257), copiada del historial de Supabase el 20/11/2026. Ya está aplicada.

CREATE OR REPLACE FUNCTION public.crm_acciones(p_hoy date DEFAULT NULL::date)
 RETURNS SETOF jsonb LANGUAGE sql STABLE SET search_path TO 'public'
AS $function$
with hoy as (select coalesce(p_hoy, public.hoy_lima()) h),
reg as (select * from public.crm_reglas where activo),
ases as (select distinct public.crm_nz(e.nombre) n from public.eq_personas e where e.codigo_asesor is not null),
post as (select * from public.crm_cliente_post),
ped as (
  select c.n_orden, c.cliente_id, c.cliente, c.celular, c.ciudad, c.direccion,
         coalesce(nullif(btrim(x.asesor_seguimiento), ''), c.vendedor_bo, c.cliente_bo, c.vendedor) vendedor,
         c.vendedor vendedor_pedido, c.autocompra,
         (c.autocompra or exists (select 1 from ases where ases.n = public.crm_nz(c.cliente))) compra_propia,
         c.productos, c.credito_contado, c.cuotas, c.total, c.periodo,
         public.crm_fecha(c.delivery_date) entrega, public.crm_fecha(c.fecha_ordenado) ordenado,
         coalesce(public.crm_fecha(c.delivery_date), public.crm_fecha(c.fecha_ordenado)) base,
         upper(regexp_replace(coalesce(c.productos, ''), '[✓✔]\s*', '', 'g')) prod
    from public.crm_pedidos c left join post x on x.cliente_id = c.cliente_id
   where coalesce(c.estatus, '') ~* 'ENTREGADA'
),
flags as (
  select p.*,
    p.prod ~ '(COOKER|OLLA|CACEROLA|SIGNATURE|PRINCESA|RENAWOK|RENA WOK|SAUCEPAN|SAUCIER|RONDEAU|ASADOR|CONTESSA|PRESSURE)' as f_ollas,
    p.prod ~ '(SARTÉN|SARTEN|SKILLET)' as f_sartenes,
    p.prod ~ '(AQUA NANO|FILTRO DE AGUA|AQUA CHECK NANO 500 UCU|LX-500)' as f_filtro,
    p.prod ~ '(INDUCTION COOKER|COCINA DE INDUCC|IC-450|IC-350|IC-400|SW-3000)' as f_cocina,
    p.prod ~ '(OLLA A PRESI|PRESSURE)' as f_presion,
    p.prod ~ '(PURIFICADOR DE AIRE|AIR PURIFIER|RENA AIR|PURIFICADOR AIRE|AERO ?QUATTRO)' as f_aire
  from ped p
),
seg as (
  select s.id, s.n_orden, s.tipo, s.modo, s.texto, s.nota, s.created_at, public.crm_fecha(s.fecha_gestion) f,
         coalesce(s.cliente_id, c.cliente_id) cliente_id
    from public.crm_seguimiento s left join public.crm_pedidos c on c.n_orden = s.n_orden
   where not s.anulado
),
gp as (select g.* from public.crm_gestiones g where not g.anulado),
uno as (
  select f.n_orden, 'bienvenida'::text tipo, f.base vence from flags f where f.base is not null and exists (select 1 from reg where clave='bienvenida')
  union all select f.n_orden, 'semana1', f.base + coalesce((select dias from reg where clave='semana1'), 7) from flags f where f.base is not null and f.f_ollas and exists (select 1 from reg where clave='semana1')
  union all select f.n_orden, 'mes1', f.base + coalesce((select dias from reg where clave='mes1'), 30) from flags f where f.base is not null and f.f_ollas and exists (select 1 from reg where clave='mes1')
  union all select f.n_orden, 'fincuotas', (f.ordenado + make_interval(months => f.cuotas - 1))::date
              from flags f where f.ordenado is not null and f.credito_contado ilike 'cr%' and coalesce(f.cuotas, 0) > 0 and exists (select 1 from reg where clave='fincuotas')
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
    'cliente_id', u.cliente_id, 'cliente', u.cliente, 'celular', u.celular, 'ciudad', u.ciudad, 'vendedor', u.vendedor, 'autocompra', u.autocompra,
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
    'hecho_el', u.hecho_el, 'gestiones', coalesce(u.gest, '[]'::jsonb),
    'vendedor_pedido', u.vendedor_pedido, 'compra_propia', u.compra_propia) j
  from uno_est u, hoy h
),
-- ciclos: reglas de crm_reglas (tipo_regla = 'ciclo'); un ciclo por cliente y regla
rc as (select * from reg where tipo_regla = 'ciclo'),
m as (
  select r.clave tipo, r.intervalo_meses intervalo, r.familia, f.cliente_id, f.n_orden, f.base,
         exists (select 1 from unnest(string_to_array(f.prod, '|')) it
                  where it ~ r.re_sistema and (r.re_excluir is null or it !~ r.re_excluir)) es_sys,
         (r.re_repuesto is not null and f.prod ~ r.re_repuesto) es_rep
    from flags f cross join rc r
   where f.base is not null and f.cliente_id is not null
),
m2 as (select m.*, bool_or(m.es_sys or m.es_rep) over (partition by m.familia, m.n_orden) fam from m),
cic_ord as (select * from m2 where fam),
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
  select c.*, greatest(c.sys_date, c.rep_date) base, a.cliente, a.celular, a.ciudad, a.direccion, a.vendedor, a.vendedor_pedido, a.autocompra,
         (a.compra_propia or exists (select 1 from flags z where z.cliente_id = c.cliente_id and z.compra_propia)) compra_propia,
         a.productos, a.prod, r.re_sistema, r.re_excluir, r.sistema_def,
         x.excluido_hasta, x.excluido_motivo, x.referencia, nullif(btrim(x.asesor_seguimiento), '') asesor_fijado,
         (select jsonb_agg(jsonb_build_object('id', s.id, 'modo', s.modo, 'fecha', s.f, 'texto', s.texto, 'n_orden', s.n_orden) order by s.f, s.created_at)
            from seg s where s.tipo = c.tipo and (s.cliente_id = c.cliente_id or s.n_orden = any (c.ordenes))) gest,
         (select max(s.f) from seg s where s.tipo = c.tipo and s.modo in ('cambio', 'por_su_cuenta') and (s.cliente_id = c.cliente_id or s.n_orden = any (c.ordenes))) ultimo_cambio,
         (select count(*) from seg s where s.tipo = c.tipo and s.modo = 'cambio' and (s.cliente_id = c.cliente_id or s.n_orden = any (c.ordenes))) cambios,
         (select max(s.f) from seg s where s.tipo = c.tipo and s.modo = 'noaplica' and (s.cliente_id = c.cliente_id or s.n_orden = any (c.ordenes))) noaplica_el,
         (select max(s.f) from seg s where s.tipo = c.tipo and s.modo in ('whatsapp', 'aviso', 'omitido') and (s.cliente_id = c.cliente_id or s.n_orden = any (c.ordenes))) ultimo_aviso_seg,
         (select max((g.fecha at time zone 'America/Lima')::date) from gp g where g.cliente_id = c.cliente_id and g.tipo = c.tipo and g.resultado in ('pidio_visita', 'no_desea', 'contesto', 'colgo')) ultimo_contacto,
         (select jsonb_agg(jsonb_build_object('id', g.id, 'fecha', g.fecha, 'canal', g.canal, 'intento', g.intento, 'resultado', g.resultado, 'etapa', g.etapa,
                 'accion', g.accion, 'accion_fecha', g.accion_fecha, 'nota', g.nota, 'call_id', g.call_id, 'grabacion_url', g.grabacion_url, 'origen', g.origen) order by g.fecha desc, g.id desc)
            from gp g where g.cliente_id = c.cliente_id and g.tipo = c.tipo) gpost,
         (select g.resultado from gp g where g.cliente_id = c.cliente_id order by g.fecha desc, g.id desc limit 1) ultimo_resultado_cli
    from cic c join flags a on a.n_orden = c.ancla join rc r on r.clave = c.tipo left join post x on x.cliente_id = c.cliente_id
),
cic_calc as (
  select c.*, greatest(c.base, c.ultimo_cambio) inicio,
         (greatest(c.base, c.ultimo_cambio) + make_interval(months => c.intervalo))::date vence,
         greatest(c.ultimo_aviso_seg, c.ultimo_contacto) ultimo_aviso,
         (c.noaplica_el is not null and c.noaplica_el >= greatest(c.base, c.ultimo_cambio)) cerrado,
         (greatest(c.ultimo_aviso_seg, c.ultimo_contacto) is not null and greatest(c.ultimo_aviso_seg, c.ultimo_contacto) >= greatest(c.base, c.ultimo_cambio)) avisado,
         (select count(*) from jsonb_array_elements(coalesce(c.gpost, '[]'::jsonb)) e where ((e->>'fecha')::timestamptz at time zone 'America/Lima')::date >= greatest(c.base, c.ultimo_cambio)) intentos_etapa
    from cic_est c
),
cic_json as (
  select jsonb_build_object(
    'clave', c.cliente_id || '::' || c.tipo, 'clase', 'ciclo', 'tipo', c.tipo, 'intervalo', c.intervalo,
    'cliente_id', c.cliente_id, 'cliente', c.cliente, 'celular', c.celular, 'ciudad', c.ciudad, 'vendedor', c.vendedor, 'autocompra', c.autocompra,
    'n_orden', c.ancla, 'ordenes', to_jsonb(c.ordenes),
    'sistema', case when c.sys_date is null then null
                    else coalesce((select btrim(regexp_replace(it, '\s*\((x\d+ )?S/[^)]*\)\s*$', '')) from unnest(string_to_array(c.productos, '|')) it
                                   where upper(regexp_replace(it, '[✓✔]\s*', '', 'g')) ~ c.re_sistema
                                     and upper(regexp_replace(it, '[✓✔]\s*', '', 'g')) !~ coalesce(c.re_excluir, '(PREFILTRO|PRE-FILTRO|ELEMENTO DESECHABLE|ELEMENTO AQ HD|ALOJAMIENTO REU)') limit 1),
                                  c.sistema_def) end,
    'fecha_sistema', c.sys_date, 'fecha_repuesto', c.rep_date, 'repuestos', c.reps,
    'src', case when c.rep_date is not null and (c.sys_date is null or c.rep_date >= c.sys_date) then 'repuesto' else 'sistema' end,
    'base', c.base, 'vence', c.vence, 'dias', (c.vence - h.h),
    'ultimo_cambio', c.ultimo_cambio, 'cambios', c.cambios, 'ultimo_aviso', c.ultimo_aviso,
    'estado', case when c.cerrado then 'cerrado'
                   when c.excluido_hasta is not null and c.excluido_hasta >= h.h then 'excluido'
                   when c.vence - h.h > 90 then 'al_dia'
                   when c.avisado and c.ultimo_aviso > h.h - 30 then 'avisado'
                   when c.vence < h.h then 'vencido'
                   else 'proximo' end,
    'gestiones', coalesce(c.gest, '[]'::jsonb),
    'vendedor_pedido', c.vendedor_pedido, 'asesor_fijado', c.asesor_fijado, 'compra_propia', c.compra_propia,
    'direccion', c.direccion, 'provincia', nullif(btrim(split_part(coalesce(c.ciudad, ''), ',', 2)), ''), 'referencia', c.referencia,
    'etapa', least(3, c.cambios + 1), 'inicio_etapa', c.inicio,
    'gestiones_post', coalesce(c.gpost, '[]'::jsonb), 'ultima_gestion', c.gpost -> 0,
    'intentos_etapa', c.intentos_etapa, 'gestionado_etapa', (c.intentos_etapa > 0),
    'excluido_hasta', c.excluido_hasta, 'excluido_motivo', c.excluido_motivo,
    'numero_errado', coalesce(c.ultimo_resultado_cli = 'numero_errado', false)) j
  from cic_calc c, hoy h
)
select j from uno_json union all select j from cic_json
$function$;
