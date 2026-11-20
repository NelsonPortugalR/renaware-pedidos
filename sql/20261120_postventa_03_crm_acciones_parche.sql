-- Post venta (20/11/2026) · 3 de 3: crm_acciones. YA APLICADO (los bloques 2 y 3 no se pueden volver a correr: sus puntos ya cambiaron).
-- crm_acciones: se parcha en vivo (lee la definición actual, cambia 11 puntos y la vuelve a crear).
-- Así no se pisa lo que otro chat haya cambiado en el resto de la función. Si un punto no aparece
-- exactamente una vez, no cambia nada y avisa cuál.
do $do$
declare
  d text; n int; i int;
  viejo text[] := array[
    $a$post as (select * from public.crm_cliente_post),$a$,
    $a$gp as (select g.* from public.crm_gestiones g where not g.anulado),$a$,
    $a$x.excluido_hasta, x.excluido_motivo, x.referencia, nullif(btrim(x.asesor_seguimiento), '') asesor_fijado,$a$,
    $a$and g.resultado in ('pidio_visita', 'no_desea', 'contesto', 'colgo')) ultimo_contacto,$a$,
    $a$'accion', g.accion, 'accion_fecha', g.accion_fecha, 'nota', g.nota, 'call_id', g.call_id, 'grabacion_url', g.grabacion_url, 'origen', g.origen) order by g.fecha desc, g.id desc)$a$,
    $a$(select g.resultado from gp g where g.cliente_id = c.cliente_id order by g.fecha desc, g.id desc limit 1) ultimo_resultado_cli$a$,
    $a$(greatest(c.ultimo_aviso_seg, c.ultimo_contacto) is not null and greatest(c.ultimo_aviso_seg, c.ultimo_contacto) >= greatest(c.base, c.ultimo_cambio)) avisado,$a$,
    $a$greatest(c.ultimo_aviso_seg, c.ultimo_contacto) ultimo_aviso,$a$,
    $a$where ((e->>'fecha')::timestamptz at time zone 'America/Lima')::date >= greatest(c.base, c.ultimo_cambio)) intentos_etapa$a$,
    $a$'intentos_etapa', c.intentos_etapa, 'gestionado_etapa', (c.intentos_etapa > 0),$a$,
    $a$'numero_errado', coalesce(c.ultimo_resultado_cli = 'numero_errado', false)) j$a$
  ];
  nuevo text[] := array[
    -- 1. datos por cliente: si el cliente se fusionó con otro, valen los del cliente que quedó
    $a$post as (select distinct on (r.cli) r.cli cliente_id, x.asesor_seguimiento, x.excluido_hasta, x.excluido_motivo, x.referencia, x.nota, x.en_mano
           from public.crm_cliente_post x cross join lateral (select public.cli_raiz(x.cliente_id) cli) r order by r.cli, x.actualizado desc),$a$,
    -- 2. gestiones (con tanda, video, celular y visita) y avisos al asesor
    $a$gp as (select g.id, public.cli_raiz(g.cliente_id) cliente_id, g.tipo, g.n_orden, g.fecha, g.canal, g.intento, g.resultado, g.etapa, g.accion, g.accion_fecha, g.nota,
              g.call_id, g.grabacion_url, g.origen, g.lote, g.tanda, g.video, g.celular, g.visita_fecha
         from public.crm_gestiones g where not g.anulado),
av as (select a.id, public.cli_raiz(a.cliente_id) cliente_id, a.tipo, a.etapa, a.tanda, a.asesor, a.fecha, a.nota, a.revisar_el, a.estado, a.revisado_el, a.revision_nota, a.gestion_id, a.origen
         from public.crm_avisos_asesor a where not a.anulado),$a$,
    -- 3. nota libre y repuesto en mano
    $a$x.excluido_hasta, x.excluido_motivo, x.referencia, nullif(btrim(x.asesor_seguimiento), '') asesor_fijado, x.nota nota_cliente, x.en_mano,$a$,
    -- 4. cuenta como «avisado»: una respuesta del cliente, un mensaje o video enviado, una visita coordinada o un aviso a su asesor
    $a$and (g.resultado in ('pidio_visita', 'no_desea', 'contesto', 'colgo') or (g.canal in ('whatsapp', 'visita') and g.resultado <> 'numero_errado'))) ultimo_contacto,
         (select max((a.fecha at time zone 'America/Lima')::date) from av a where a.cliente_id = c.cliente_id and a.tipo = c.tipo) ultimo_aviso_asesor,
         (select jsonb_agg(jsonb_build_object('id', a.id, 'fecha', a.fecha, 'asesor', a.asesor, 'etapa', a.etapa, 'tanda', a.tanda, 'nota', a.nota, 'revisar_el', a.revisar_el,
                 'estado', a.estado, 'revisado_el', a.revisado_el, 'revision_nota', a.revision_nota, 'gestion_id', a.gestion_id, 'origen', a.origen) order by a.fecha desc, a.id desc)
            from av a where a.cliente_id = c.cliente_id and a.tipo = c.tipo) avisos,$a$,
    -- 5. más datos por gestión
    $a$'accion', g.accion, 'accion_fecha', g.accion_fecha, 'nota', g.nota, 'call_id', g.call_id, 'grabacion_url', g.grabacion_url, 'origen', g.origen,
                 'tanda', g.tanda, 'video', g.video, 'celular', g.celular, 'visita_fecha', g.visita_fecha, 'lote', g.lote) order by g.fecha desc, g.id desc)$a$,
    -- 6. «número errado» deja de valer cuando ese número ya no está en los pedidos del cliente (se corrigió)
    $a$(select case when g.resultado <> 'numero_errado' or g.celular is null
                           or exists (select 1 from flags z where z.cliente_id = c.cliente_id and public.crm_cel9(z.celular) = g.celular) then g.resultado end
            from gp g where g.cliente_id = c.cliente_id order by g.fecha desc, g.id desc limit 1) ultimo_resultado_cli$a$,
    -- 7 y 8. el aviso al asesor también deja el ciclo en «avisado»
    $a$coalesce(greatest(c.ultimo_aviso_seg, c.ultimo_contacto, c.ultimo_aviso_asesor) >= greatest(c.base, c.ultimo_cambio), false) avisado,$a$,
    $a$greatest(c.ultimo_aviso_seg, c.ultimo_contacto, c.ultimo_aviso_asesor) ultimo_aviso,$a$,
    -- 9 y 10. «ya gestionado en la etapa» cuenta gestiones y avisos al asesor
    $a$where ((e->>'fecha')::timestamptz at time zone 'America/Lima')::date >= greatest(c.base, c.ultimo_cambio)) intentos_etapa,
         (select count(*) from jsonb_array_elements(coalesce(c.avisos, '[]'::jsonb)) e where ((e->>'fecha')::timestamptz at time zone 'America/Lima')::date >= greatest(c.base, c.ultimo_cambio)) avisos_etapa$a$,
    $a$'intentos_etapa', c.intentos_etapa, 'gestionado_etapa', (c.intentos_etapa + c.avisos_etapa > 0),$a$,
    -- 11. campos nuevos del ciclo
    $a$'numero_errado', coalesce(c.ultimo_resultado_cli = 'numero_errado', false))
    || jsonb_build_object(
    'avisos_asesor', coalesce(c.avisos, '[]'::jsonb),
    'aviso_asesor', (select e from jsonb_array_elements(coalesce(c.avisos, '[]'::jsonb)) e where ((e->>'fecha')::timestamptz at time zone 'America/Lima')::date >= c.inicio limit 1),
    'aviso_por_revisar', exists (select 1 from jsonb_array_elements(coalesce(c.avisos, '[]'::jsonb)) e
                                  where e->>'estado' = 'pendiente' and (e->>'revisar_el')::date <= h.h and ((e->>'fecha')::timestamptz at time zone 'America/Lima')::date >= c.inicio),
    'nota', c.nota_cliente,
    'en_mano', coalesce(public.crm_fecha_flex(c.en_mano ->> c.tipo) >= c.inicio, false),
    'tanda', (select e->>'tanda' from jsonb_array_elements(coalesce(c.gpost, '[]'::jsonb) || coalesce(c.avisos, '[]'::jsonb)) e
               where e->>'tanda' is not null and ((e->>'fecha')::timestamptz at time zone 'America/Lima')::date >= c.inicio order by (e->>'fecha')::timestamptz desc limit 1),
    'celular_e164', public.crm_cel_e164(c.celular)) j$a$
  ];
begin
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = 'crm_acciones';
  if d is null then raise exception 'No existe crm_acciones'; end if;
  if position('crm_avisos_asesor' in d) > 0 then raise notice 'crm_acciones ya tiene el parche'; return; end if;
  for i in 1 .. array_length(viejo, 1) loop
    n := (length(d) - length(replace(d, viejo[i], ''))) / length(viejo[i]);
    if n <> 1 then raise exception 'Punto % del parche: aparece % veces (se esperaba 1). No se cambió nada.', i, n; end if;
  end loop;
  for i in 1 .. array_length(viejo, 1) loop d := replace(d, viejo[i], nuevo[i]); end loop;
  execute d;
end $do$;

-- 2. «Ya gestionado en la etapa» también cuenta el aviso que salió desde Bienvenida (crm_seguimiento).
do $do$
declare d text; n int;
  viejo text := $a$'gestionado_etapa', (c.intentos_etapa + c.avisos_etapa > 0),$a$;
  nuevo text := $a$'gestionado_etapa', (c.intentos_etapa + c.avisos_etapa > 0 or coalesce(c.ultimo_aviso_seg >= c.inicio, false)),$a$;
begin
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = 'crm_acciones';
  n := (length(d) - length(replace(d, viejo, ''))) / length(viejo);
  if n <> 1 then raise exception 'Punto del parche: aparece % veces (se esperaba 1). No se cambió nada.', n; end if;
  execute replace(d, viejo, nuevo);
end $do$;

-- 3. «Tiene el repuesto en mano»: la marca guarda el momento exacto y se apaga sola cuando después se anota el cambio
--    (o que lo compró por su cuenta) o cuando compra otro repuesto; así no depende de la fecha que se le ponga al cambio.
do $do$
declare d text; n int; i int;
  viejo text[] := array[
    $a$from av a where a.cliente_id = c.cliente_id and a.tipo = c.tipo) avisos,$a$,
    $a$'en_mano', coalesce(public.crm_fecha_flex(c.en_mano ->> c.tipo) >= c.inicio, false),$a$ ];
  nuevo text[] := array[
    $a$from av a where a.cliente_id = c.cliente_id and a.tipo = c.tipo) avisos,
         (select max(s.created_at) from seg s where s.tipo = c.tipo and s.modo in ('cambio', 'por_su_cuenta') and (s.cliente_id = c.cliente_id or s.n_orden = any (c.ordenes))) cambio_anotado_el,$a$,
    $a$'en_mano', coalesce(public.crm_fecha_flex(c.en_mano ->> c.tipo) >= c.base and public.crm_ts(c.en_mano ->> c.tipo) > coalesce(c.cambio_anotado_el, '-infinity'::timestamptz), false),$a$ ];
begin
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = 'crm_acciones';
  for i in 1 .. 2 loop
    n := (length(d) - length(replace(d, viejo[i], ''))) / length(viejo[i]);
    if n <> 1 then raise exception 'Punto % del parche: aparece % veces (se esperaba 1). No se cambió nada.', i, n; end if;
  end loop;
  for i in 1 .. 2 loop d := replace(d, viejo[i], nuevo[i]); end loop;
  execute d;
end $do$;
