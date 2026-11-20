-- Migración «crm_reglas_fuente_unica» (20261103021125), copiada del historial de Supabase el 20/11/2026. Ya está aplicada.

create table if not exists public.crm_reglas (
  clave text primary key,
  tipo_regla text not null check (tipo_regla in ('una_vez','ciclo')),
  nombre text not null,
  aplica_a text not null,
  cuando text not null,
  accion text not null,
  dias int,
  intervalo_meses int,
  familia text,
  re_sistema text,
  re_excluir text,
  re_repuesto text,
  sistema_def text,
  orden int not null default 0,
  activo boolean not null default true,
  actualizado timestamptz not null default now()
);
alter table public.crm_reglas enable row level security;
drop policy if exists crm_reglas_rw on public.crm_reglas;
create policy crm_reglas_rw on public.crm_reglas for all to authenticated
  using ((auth.jwt() ->> 'email') = any (array['CORREO_OFICINA_1','CORREO_OFICINA_2']))
  with check ((auth.jwt() ->> 'email') = any (array['CORREO_OFICINA_1','CORREO_OFICINA_2']));

insert into public.crm_reglas (clave,tipo_regla,nombre,aplica_a,cuando,accion,dias,intervalo_meses,familia,re_sistema,re_excluir,re_repuesto,sistema_def,orden) values
('bienvenida','una_vez','Al recibir su pedido','Todo pedido entregado','El día que recibe el pedido (fecha de entrega; si no hay, la de la orden)','Video de lavado de utensilios + recomendaciones según lo que compró: sartenes (freír sin aceite), filtro (cómo conectarlo), cocina de inducción (cómo usarla), olla a presión (uso)',0,null,null,null,null,null,null,10),
('semana1','una_vez','Semana 1 · Nutri Sensor','Pedidos entregados con ollas (cooker, olla, cacerola, signature, princesa, wok, saucepan, saucier, rondeau, asador, contessa, presión)','7 días después de recibir','Video: cómo lavar el Nutri Sensor de las tapas',7,null,null,null,null,null,null,20),
('mes1','una_vez','Mes 1 · brillo y Rena Lite','Pedidos entregados con ollas','30 días después de recibir','Cómo mantener el brillo, buen uso y Rena Lite',30,null,null,null,null,null,null,30),
('fincuotas','una_vez','Fin de cuotas','Pedidos entregados al crédito','Un mes antes de la última cuota (fecha de orden + cuotas − 1 meses)','Felicitar por la puntualidad y ofrecer completar el juego / promociones del mes',null,null,null,null,null,null,null,40),
('prefiltro','ciclo','Cambio de pre-filtro','Clientes con Aqua Nano (o que compraron pre-filtros)','Cada 12 meses desde la entrega del sistema o el último pre-filtro comprado (lo más reciente)','Coordinar el cambio del pre-filtro',null,12,'agua','(AQUA NANO|AQUA CHECK NANO 500 CTU \(UNID|AQUA CHECK NANO 500 UCU|LX-500)','(PREFILTRO|PRE-FILTRO|PRE FILTRO|ELEMENTO DESECHABLE|ELEMENTO AQ HD|ALOJAMIENTO REU)','(PREFILTRO|PRE-FILTRO|PRE FILTRO)','Aqua Nano',50),
('filtroppal','ciclo','Cambio del filtro principal','Clientes con Aqua Nano (o que compraron elementos)','Cada 48 meses desde la entrega del sistema o el último elemento desechable comprado','Coordinar el cambio del elemento filtrante principal',null,48,'agua','(AQUA NANO|AQUA CHECK NANO 500 CTU \(UNID|AQUA CHECK NANO 500 UCU|LX-500)','(PREFILTRO|PRE-FILTRO|PRE FILTRO|ELEMENTO DESECHABLE|ELEMENTO AQ HD|ALOJAMIENTO REU)','(ELEMENTO DESECHABLE|ELEMENTO AQ HD|ALOJAMIENTO REU)','Aqua Nano',60),
('aire','ciclo','Cambio del filtro de aire','Clientes con purificador de aire','Cada 18 meses desde la entrega del purificador o el último filtro comprado','Coordinar el cambio del filtro del purificador',null,18,'aire','(PURIFICADOR DE AIRE|AIR PURIFIER|RENA AIR|PURIFICADOR AIRE|AERO ?QUATTRO)',null,'(FILTRO HEPA|FILTRO DE AIRE|FILTRO PARA PURIFICADOR|FILTRO AERO)','Purificador de aire',70)
on conflict (clave) do nothing;

create or replace function public.crm_acciones(p_hoy date default null)
 returns setof jsonb language sql stable set search_path to 'public'
as $function$
with hoy as (select coalesce(p_hoy, public.hoy_lima()) h),
reg as (select * from public.crm_reglas where activo),
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
    p.prod ~ '(PURIFICADOR DE AIRE|AIR PURIFIER|RENA AIR|PURIFICADOR AIRE|AERO ?QUATTRO)' as f_aire
  from ped p
),
seg as (
  select s.id, s.n_orden, s.tipo, s.modo, s.texto, s.nota, s.created_at, public.crm_fecha(s.fecha_gestion) f,
         coalesce(s.cliente_id, c.cliente_id) cliente_id
    from public.crm_seguimiento s left join public.crm_pedidos c on c.n_orden = s.n_orden
   where not s.anulado
),
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
  select c.*, greatest(c.sys_date, c.rep_date) base, a.cliente, a.celular, a.ciudad, a.vendedor, a.productos, a.prod,
         r.re_sistema, r.re_excluir, r.sistema_def,
         (select jsonb_agg(jsonb_build_object('id', s.id, 'modo', s.modo, 'fecha', s.f, 'texto', s.texto, 'n_orden', s.n_orden) order by s.f, s.created_at)
            from seg s where s.tipo = c.tipo and (s.cliente_id = c.cliente_id or s.n_orden = any (c.ordenes))) gest,
         (select max(s.f) from seg s where s.tipo = c.tipo and s.modo = 'cambio' and (s.cliente_id = c.cliente_id or s.n_orden = any (c.ordenes))) ultimo_cambio,
         (select count(*) from seg s where s.tipo = c.tipo and s.modo = 'cambio' and (s.cliente_id = c.cliente_id or s.n_orden = any (c.ordenes))) cambios,
         (select max(s.f) from seg s where s.tipo = c.tipo and s.modo = 'noaplica' and (s.cliente_id = c.cliente_id or s.n_orden = any (c.ordenes))) noaplica_el,
         (select max(s.f) from seg s where s.tipo = c.tipo and s.modo in ('whatsapp', 'aviso', 'omitido') and (s.cliente_id = c.cliente_id or s.n_orden = any (c.ordenes))) ultimo_aviso
    from cic c join flags a on a.n_orden = c.ancla join rc r on r.clave = c.tipo
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
                                   where upper(it) ~ c.re_sistema
                                     and upper(it) !~ coalesce(c.re_excluir, '(PREFILTRO|PRE-FILTRO|ELEMENTO DESECHABLE|ELEMENTO AQ HD|ALOJAMIENTO REU)') limit 1),
                                  c.sistema_def) end,
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
$function$;
