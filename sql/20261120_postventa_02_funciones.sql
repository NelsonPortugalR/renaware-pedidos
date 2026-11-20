-- ============================================================================================
-- Post venta (20/11/2026) · 2 de 3: funciones. Todo «create or replace»: se puede volver a correr.
-- Regla: lo que escribe entra por una función que valida la sesión (crm_puede) o la llave del bot.
-- ============================================================================================

-- ¿Quién puede? 'admin' = las cuentas de la oficina; 'gestionar' = además el rol «postventa» de perfiles
-- (para una cuenta propia de post venta que solo registre gestiones). Interna: no se llama desde fuera.
create or replace function public.crm_puede(p_que text default 'gestionar')
 returns boolean language sql stable security definer set search_path to 'public'
as $function$
  select coalesce(auth.jwt() ->> 'email', '') in ('CORREO_OFICINA_1', 'CORREO_OFICINA_2')
      or (coalesce(p_que, 'gestionar') = 'gestionar' and auth.uid() is not null and public.tiene_rol('postventa'))
$function$;

-- Fecha suelta: acepta 2026-11-20 y 20/11/2026.
create or replace function public.crm_fecha_flex(p text)
 returns date language plpgsql immutable set search_path to 'public'
as $function$
declare t text := btrim(coalesce(p, ''));
begin
  if t ~ '^\d{4}-\d{2}-\d{2}' then return left(t, 10)::date; end if;
  return public.crm_fecha(t);
exception when others then return null;
end $function$;

-- Fecha y hora: sin zona se entiende hora de Lima; una fecha sola queda al mediodía de Lima.
create or replace function public.crm_ts(p text)
 returns timestamptz language plpgsql stable set search_path to 'public'
as $function$
declare t text := btrim(coalesce(p, '')); m text[];
begin
  if t = '' then return null; end if;
  m := regexp_match(t, '^(\d{1,2})/(\d{1,2})/(\d{4})(?:[ T,]+(\d{1,2}):(\d{2})(?::(\d{2}))?)?');
  if m is not null then
    return make_timestamp(m[3]::int, m[2]::int, m[1]::int, coalesce(m[4], '12')::int, coalesce(m[5], '0')::int, coalesce(m[6], '0')::int) at time zone 'America/Lima';
  end if;
  if t ~ '^\d{4}-\d{2}-\d{2}$' then return (t || ' 12:00')::timestamp at time zone 'America/Lima'; end if;
  if t ~ '\d{2}:\d{2}' and t ~ '(Z|[+-]\d{2}(:?\d{2})?)$' then return t::timestamptz; end if;
  return t::timestamp at time zone 'America/Lima';
exception when others then raise exception 'Fecha no válida: %', p;
end $function$;

-- Normalizadores de los valores fijos de una gestión (una sola definición para la página, el CSV y el bot).
create or replace function public.crm_g_clave(p text)
 returns text language sql immutable set search_path to 'public'
as $function$ select btrim(regexp_replace(public.crm_nz(p), '[^a-z0-9]+', '_', 'g'), '_') $function$;

create or replace function public.crm_g_tipo(p text)
 returns text language sql immutable set search_path to 'public'
as $function$
  select case when k = '' then 'prefiltro'
              when k in ('prefiltro', 'pre_filtro', 'prefiltros', 'pre') then 'prefiltro'
              when k in ('filtroppal', 'filtro_principal', 'principal', 'ppal', 'elemento', 'elemento_desechable') then 'filtroppal'
              when k in ('aire', 'filtro_de_aire', 'purificador') then 'aire'
              when k in ('botella', 'botella_filtrante') then 'botella'
              else k end
    from (select public.crm_g_clave(p) k) s
$function$;

-- Tipo de gestión → canal. «video» y «aviso_asesor» se resuelven aparte (ver crm_gestiones_registrar_int).
create or replace function public.crm_g_canal(p text)
 returns text language sql immutable set search_path to 'public'
as $function$
  select case when k in ('llamada_auto', 'llamada_automatica', 'automatica', 'auto', 'bot', 'ivr') then 'llamada_auto'
              when k in ('llamada', 'llamada_manual', 'telefono', 'manual') then 'llamada'
              when k in ('whatsapp', 'wa', 'mensaje', 'mensaje_directo', 'mensaje_directo_al_cliente', 'mensaje_al_cliente') then 'whatsapp'
              when k in ('video', 'video_enviado') then 'video'
              when k in ('visita', 'visita_coordinada') then 'visita'
              when k in ('aviso_asesor', 'aviso_al_asesor', 'aviso', 'asesor') then 'aviso_asesor'
              else null end
    from (select public.crm_g_clave(p) k) s
$function$;

create or replace function public.crm_g_resultado(p text)
 returns text language sql immutable set search_path to 'public'
as $function$
  select case when k in ('1', 'pidio_visita', 'pide_visita', 'pidio', 'visita', 'quiere_visita', 'marco_1') then 'pidio_visita'
              when k in ('2', 'no_desea', 'no_usa', 'no_usa_el_filtro', 'no_usa_el_filtro_no_desea', 'no_quiere', 'marco_2') then 'no_desea'
              when k in ('contesto', 'sin_marcar', 'contesto_sin_marcar', 'respondio', 'contesta') then 'contesto'
              when k in ('colgo', 'cuelga', 'corto') then 'colgo'
              when k in ('buzon', 'buzon_de_voz', 'casilla', 'voicemail') then 'buzon'
              when k in ('no_contesta', 'no_contesto', 'sin_respuesta', 'sin_respuesta_aun', 'no_responde', 'no_respondio') then 'no_contesta'
              when k in ('numero_errado', 'errado', 'equivocado', 'numero_equivocado', 'no_existe', 'sin_whatsapp', 'fuera_de_servicio') then 'numero_errado'
              else null end
    from (select public.crm_g_clave(p) k) s
$function$;

create or replace function public.crm_g_accion(p text)
 returns text language sql immutable set search_path to 'public'
as $function$
  select case when k in ('enviar_video', 'video') then 'enviar_video'
              when k in ('coordinar_visita', 'visita', 'avisar_al_asesor', 'avisar_asesor') then 'coordinar_visita'
              when k in ('volver_a_llamar', 'rellamar', 'llamar', 'reintentar', 'volver_a_intentar') then 'volver_a_llamar'
              when k in ('ninguna', 'nada', 'no', 'ninguno') then 'ninguna'
              else null end
    from (select public.crm_g_clave(p) k) s
$function$;

create or replace function public.crm_g_tanda(p text)
 returns text language sql immutable set search_path to 'public'
as $function$
  select case when t ~ '^[0-9]{1,3}$' then 'T' || t::int
              when t ~ '^T[0-9]{1,3}$' then 'T' || substr(t, 2)::int
              when t ~ '^TANDA ?[0-9]{1,3}$' then 'T' || regexp_replace(t, '\D', '', 'g')::int
              else null end
    from (select upper(btrim(coalesce(p, ''))) t) s
$function$;

-- ---------------------------------------------------------------------------------------------
-- La única implementación de «registrar gestiones». La usan: la página (una fila), la carga en lote
-- (CSV/Excel) y la API del bot. Cada fila: cliente_id | n_orden | celular (único) para ubicar al cliente;
-- tipo (repuesto), canal (tipo de gestión), fecha, intento, resultado, etapa, tanda, accion, accion_fecha,
-- nota, call_id, grabacion_url, celular, visita_fecha, lote; y para el aviso al asesor: asesor, revisar_el.
-- Interna: sin permisos para anon ni authenticated.
-- ---------------------------------------------------------------------------------------------
create or replace function public.crm_gestiones_registrar_int(p_filas jsonb, p_origen text, p_canal_def text default 'llamada', p_lote text default null, p_por uuid default null)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare
  f jsonb; i int := 0; k text;
  v_cli uuid; v_tipo text; v_res text; v_canal text; v_etapa int; v_n bigint; v_cel text; v_cnt int; v_int int;
  v_fecha timestamptz; v_tanda text; v_acc text; v_video boolean; v_ases text; v_rev date; v_id bigint; v_lote text; v_nota text;
  v_cic jsonb; v_cli_cic jsonb; v_c jsonb; v_tipo_txt text;
  ins int := 0; dup int := 0; avi int := 0;
  ids jsonb := '[]'::jsonb; sin jsonb := '[]'::jsonb; err jsonb := '[]'::jsonb;
begin
  if jsonb_typeof(p_filas) is distinct from 'array' then raise exception 'Se espera una lista de gestiones'; end if;
  if jsonb_array_length(p_filas) > 2000 then raise exception 'Maximo 2000 gestiones por envio'; end if;
  if coalesce(p_origen, '') not in ('portal', 'bot', 'campana') then raise exception 'Origen no valido'; end if;
  for f in select * from jsonb_array_elements(p_filas) loop
    i := i + 1;
    begin
      if jsonb_typeof(f) is distinct from 'object' then raise exception 'La fila no es un objeto'; end if;
      -- repuesto (si no viene, se deduce más abajo de los repuestos del cliente)
      v_tipo_txt := nullif(btrim(coalesce(f->>'tipo', '')), '');
      v_tipo := crm_g_tipo(v_tipo_txt);
      if not exists (select 1 from crm_reglas r where r.clave = v_tipo and r.tipo_regla = 'ciclo') then raise exception 'Repuesto no válido: %', f->>'tipo'; end if;
      -- tipo de gestión
      v_canal := crm_g_canal(coalesce(nullif(btrim(coalesce(f->>'canal', f->>'gestion', '')), ''), p_canal_def));
      if v_canal is null then raise exception 'Tipo de gestión no válido: %', coalesce(f->>'canal', f->>'gestion'); end if;
      v_video := v_canal = 'video' or lower(coalesce(f->>'video', '')) in ('true', 't', '1', 'si', 'sí', 'x');
      if v_canal = 'video' then v_canal := 'whatsapp'; end if;
      if v_video and v_canal <> 'whatsapp' then v_video := false; end if;
      -- cliente: por id, por número de orden o por un celular que sea de un solo cliente
      v_cli := nullif(btrim(coalesce(f->>'cliente_id', '')), '')::uuid;
      v_n := nullif(regexp_replace(coalesce(f->>'n_orden', ''), '\D', '', 'g'), '')::bigint;
      if v_cli is null and v_n is not null then select cliente_id into v_cli from crm_pedidos where n_orden = v_n; end if;
      if v_cli is null and nullif(btrim(coalesce(f->>'celular', '')), '') is not null then
        v_cel := crm_cel9(f->>'celular');
        select count(distinct cliente_id), min(cliente_id::text)::uuid into v_cnt, v_cli from crm_pedidos where crm_cel9(celular) = v_cel and cliente_id is not null;
        if v_cnt <> 1 then v_cli := null; end if;
      end if;
      if v_cli is not null then v_cli := cli_raiz(v_cli); end if;
      if v_cli is null or not exists (select 1 from crm_pedidos where cliente_id = v_cli) then
        sin := sin || jsonb_build_object('fila', i, 'dato', f); continue;
      end if;
      -- fecha, tanda, etapa
      v_fecha := coalesce(crm_ts(f->>'fecha'), now());
      if v_fecha > now() + interval '1 day' then raise exception 'La fecha no puede ser futura'; end if;
      v_tanda := crm_g_tanda(f->>'tanda');
      if v_tanda is null and nullif(btrim(coalesce(f->>'tanda', '')), '') is not null then raise exception 'Tanda no válida (usa T1, T2…): %', f->>'tanda'; end if;
      v_etapa := nullif(regexp_replace(coalesce(f->>'etapa', ''), '\D', '', 'g'), '')::int;
      if v_etapa is not null and v_etapa not between 1 and 3 then raise exception 'La etapa va de 1 a 3'; end if;
      v_ases := nullif(btrim(coalesce(f->>'asesor', f->>'destinatario', f->>'a_quien', '')), '');
      -- Cuando falta el repuesto, la etapa o a quién avisar, se miran los ciclos del cliente (una sola lectura por envío).
      -- La página y el bot mandan repuesto y etapa, así que no pagan esa lectura.
      if v_tipo_txt is null or v_etapa is null or (v_canal = 'aviso_asesor' and v_ases is null) then
        if v_cic is null then
          select coalesce(jsonb_object_agg(j->>'clave', jsonb_build_object('etapa', j->'etapa', 'vendedor', j->'vendedor')), '{}'::jsonb),
                 coalesce(jsonb_object_agg(j->>'clave', jsonb_build_object('cliente_id', j->>'cliente_id', 'tipo', j->>'tipo', 'dias', j->'dias', 'estado', j->>'estado')), '{}'::jsonb)
            into v_cic, v_cli_cic
            from crm_acciones() j where j->>'clase' = 'ciclo';
        end if;
        if v_tipo_txt is null and not (v_cic ? (v_cli::text || '::prefiltro')) then
          -- sin repuesto escrito y sin pre-filtro: el repuesto del cliente que vence primero
          select e.value->>'tipo' into v_tipo from jsonb_each(v_cli_cic) e
           where e.value->>'cliente_id' = v_cli::text and e.value->>'estado' <> 'cerrado' order by (e.value->>'dias')::int limit 1;
          if v_tipo is null then raise exception 'El cliente no tiene repuestos en seguimiento'; end if;
        end if;
        v_c := v_cic -> (v_cli::text || '::' || v_tipo);
        if v_c is null then raise exception 'El cliente no tiene ese repuesto en seguimiento'; end if;
        v_etapa := coalesce(v_etapa, (v_c->>'etapa')::int);
        v_ases := coalesce(v_ases, nullif(btrim(v_c->>'vendedor'), ''));
      end if;
      v_lote := left(coalesce(nullif(btrim(coalesce(f->>'lote', '')), ''), p_lote), 80);
      v_nota := left(nullif(btrim(coalesce(f->>'nota', '')), ''), 1500);

      if v_canal = 'aviso_asesor' then
        -- aviso al asesor: a quién, cuándo, y a los 5 días toca revisar si lo contactó
        if v_ases is null then raise exception 'Falta a quién se avisó'; end if;
        v_rev := coalesce(crm_fecha_flex(f->>'revisar_el'), (v_fecha at time zone 'America/Lima')::date + 5);
        if exists (select 1 from crm_avisos_asesor a where a.cliente_id = v_cli and a.tipo = v_tipo and not a.anulado and crm_nz(a.asesor) = crm_nz(v_ases)
                      and (a.fecha = v_fecha or (p_origen = 'portal' and a.created_at > now() - interval '30 seconds'))) then
          dup := dup + 1; continue;
        end if;
        insert into crm_avisos_asesor (cliente_id, tipo, etapa, tanda, asesor, fecha, nota, revisar_el, gestion_id, origen, lote, created_by)
        values (v_cli, v_tipo, v_etapa, v_tanda, left(v_ases, 120), v_fecha, v_nota, v_rev,
                nullif(regexp_replace(coalesce(f->>'gestion_id', ''), '\D', '', 'g'), '')::bigint, p_origen, v_lote, p_por)
        returning id into v_id;
        ins := ins + 1; avi := avi + 1;
        ids := ids || jsonb_build_object('fila', i, 'id', v_id, 'que', 'aviso');
        continue;
      end if;

      -- contacto con el cliente
      v_res := crm_g_resultado(f->>'resultado');
      if v_res is null then
        if nullif(btrim(coalesce(f->>'resultado', '')), '') is not null then raise exception 'Resultado no válido: %', f->>'resultado'; end if;
        v_res := case v_canal when 'whatsapp' then 'no_contesta' when 'visita' then 'pidio_visita' end;
        if v_res is null then raise exception 'Falta el resultado de la llamada'; end if;
      end if;
      v_int := nullif(regexp_replace(coalesce(f->>'intento', ''), '\D', '', 'g'), '')::int;
      if v_int is not null and v_int not between 1 and 9 then raise exception 'El intento va de 1 a 9'; end if;
      v_acc := crm_g_accion(f->>'accion');
      if v_acc is null and nullif(btrim(coalesce(f->>'accion', '')), '') is not null then raise exception 'Acción siguiente no válida: %', f->>'accion'; end if;
      k := nullif(left(btrim(coalesce(f->>'call_id', f->>'callsid', '')), 120), '');
      v_cel := nullif(crm_cel9(coalesce(f->>'celular', '')), '');
      if v_cel is null or v_cel !~ '^9\d{8}$' then
        select crm_cel9(p.celular) into v_cel from crm_pedidos p where p.cliente_id = v_cli and coalesce(p.celular, '') <> '' order by p.n_orden desc limit 1;
      end if;
      if (k is not null and exists (select 1 from crm_gestiones g where g.cliente_id = v_cli and g.tipo = v_tipo and g.call_id = k and not g.anulado))
         or exists (select 1 from crm_gestiones g where g.cliente_id = v_cli and g.tipo = v_tipo and g.canal = v_canal and g.resultado = v_res and not g.anulado
                      and g.intento is not distinct from v_int::smallint
                      and (g.fecha = v_fecha or (p_origen = 'portal' and k is null and g.created_at > now() - interval '30 seconds'))) then
        dup := dup + 1; continue;
      end if;
      insert into crm_gestiones (cliente_id, tipo, n_orden, fecha, canal, intento, resultado, etapa, accion, accion_fecha, nota, call_id, grabacion_url,
                                 origen, lote, created_by, tanda, video, celular, visita_fecha)
      values (v_cli, v_tipo, v_n, v_fecha, v_canal, v_int, v_res, v_etapa, v_acc, crm_fecha_flex(f->>'accion_fecha'), v_nota, k,
              nullif(left(btrim(coalesce(f->>'grabacion_url', f->>'grabacion', '')), 500), ''),
              p_origen, v_lote, p_por, v_tanda, v_video, v_cel, case when v_canal = 'visita' then crm_fecha_flex(f->>'visita_fecha') end)
      returning id into v_id;
      ins := ins + 1;
      ids := ids || jsonb_build_object('fila', i, 'id', v_id, 'que', 'gestion');
    exception when others then
      err := err || jsonb_build_object('fila', i, 'error', sqlerrm);
    end;
  end loop;
  return jsonb_build_object('insertadas', ins, 'duplicadas', dup, 'avisos', avi, 'sin_cliente', sin, 'errores', err, 'ids', ids);
end $function$;

-- API del bot (llave): igual que antes hacia fuera; por dentro usa la implementación única.
create or replace function public.crm_bot_registrar(p_clave text, p_filas jsonb)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
begin
  if not crm_bot_valida(p_clave) then raise exception 'Clave no valida'; end if;
  return crm_gestiones_registrar_int(p_filas, 'bot', 'llamada_auto', null, null);
end $function$;

-- Lista para llamar (API del bot). Ya no es «stable»: la API corre las funciones stable en solo lectura
-- y validar la llave anota su último uso. Suma tanda, repuesto en mano, aviso al asesor y nota.
create or replace function public.crm_bot_pendientes(p_clave text, p_dias integer default 30, p_tipo text default 'prefiltro')
 returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare v jsonb;
begin
  if not crm_bot_valida(p_clave) then raise exception 'Clave no valida'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'cliente_id', j->>'cliente_id', 'cliente', j->>'cliente', 'celular', crm_cel_e164(j->>'celular'), 'celular_original', j->>'celular',
      'celular_valido', crm_cel_e164(j->>'celular') is not null, 'numero_errado', (j->>'numero_errado')::boolean,
      'ciudad', j->>'ciudad', 'provincia', j->>'provincia', 'direccion', j->>'direccion', 'referencia', j->>'referencia',
      'tipo', j->>'tipo', 'etapa', (j->>'etapa')::int, 'vence', j->>'vence', 'dias', (j->>'dias')::int, 'estado', j->>'estado',
      'asesor', case when (j->>'compra_propia')::boolean then null else j->>'vendedor' end, 'compra_propia', (j->>'compra_propia')::boolean,
      'gestionado_etapa', (j->>'gestionado_etapa')::boolean, 'intentos_etapa', (j->>'intentos_etapa')::int,
      'ultima_gestion', j->'ultima_gestion', 'n_orden', (j->>'n_orden')::bigint, 'sistema', j->>'sistema',
      'tanda', j->>'tanda', 'repuesto_en_mano', (j->>'en_mano')::boolean, 'aviso_asesor', j->'aviso_asesor', 'nota', j->>'nota')
      order by (j->>'vence'), j->>'cliente'), '[]'::jsonb) into v
    from crm_acciones() j
   where j->>'clase' = 'ciclo' and (p_tipo is null or j->>'tipo' = p_tipo)
     and j->>'estado' not in ('cerrado', 'excluido')
     and (j->>'dias')::int <= coalesce(p_dias, 30);
  return v;
end $function$;

-- Página: registrar una gestión (o un aviso al asesor).
create or replace function public.crm_gestion_registrar(p_fila jsonb)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare r jsonb;
begin
  if auth.uid() is null or not crm_puede('gestionar') then raise exception 'Sin permiso'; end if;
  r := crm_gestiones_registrar_int(jsonb_build_array(p_fila), 'portal', 'llamada', null, auth.uid());
  if jsonb_array_length(r->'errores') > 0 then raise exception '%', r->'errores'->0->>'error'; end if;
  if jsonb_array_length(r->'sin_cliente') > 0 then raise exception 'No se encontró al cliente'; end if;
  return r;
end $function$;

-- Página: carga en lote (CSV o Excel con los resultados de una tanda).
create or replace function public.crm_gestiones_cargar(p_filas jsonb, p_lote text default null)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
begin
  if auth.uid() is null or not crm_puede('gestionar') then raise exception 'Sin permiso'; end if;
  return crm_gestiones_registrar_int(p_filas, 'campana', 'llamada_auto',
           coalesce(nullif(btrim(coalesce(p_lote, '')), ''), 'carga-' || to_char(now() at time zone 'America/Lima', 'YYYY-MM-DD-HH24MI')), auth.uid());
end $function$;

-- Página: corregir una gestión ya anotada (solo los campos que llegan).
create or replace function public.crm_gestion_editar(p_id bigint, p_datos jsonb)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare g crm_gestiones; v_res text; v_acc text; v_tanda text; v_int int; v_etapa int; v_fecha timestamptz;
begin
  if auth.uid() is null or not crm_puede('gestionar') then raise exception 'Sin permiso'; end if;
  select * into g from crm_gestiones where id = p_id and not anulado;
  if g.id is null then raise exception 'La gestión ya no existe'; end if;
  if p_datos ? 'resultado' then
    v_res := crm_g_resultado(p_datos->>'resultado');
    if v_res is null then raise exception 'Resultado no válido'; end if;
  end if;
  if p_datos ? 'accion' and nullif(btrim(coalesce(p_datos->>'accion', '')), '') is not null then
    v_acc := crm_g_accion(p_datos->>'accion');
    if v_acc is null then raise exception 'Acción siguiente no válida'; end if;
  end if;
  if p_datos ? 'tanda' and nullif(btrim(coalesce(p_datos->>'tanda', '')), '') is not null then
    v_tanda := crm_g_tanda(p_datos->>'tanda');
    if v_tanda is null then raise exception 'Tanda no válida (usa T1, T2…)'; end if;
  end if;
  if p_datos ? 'intento' then
    v_int := nullif(regexp_replace(coalesce(p_datos->>'intento', ''), '\D', '', 'g'), '')::int;
    if v_int is not null and v_int not between 1 and 9 then raise exception 'El intento va de 1 a 9'; end if;
  end if;
  if p_datos ? 'etapa' then
    v_etapa := nullif(regexp_replace(coalesce(p_datos->>'etapa', ''), '\D', '', 'g'), '')::int;
    if v_etapa is not null and v_etapa not between 1 and 3 then raise exception 'La etapa va de 1 a 3'; end if;
  end if;
  if p_datos ? 'fecha' then
    v_fecha := crm_ts(p_datos->>'fecha');
    if v_fecha is null then raise exception 'Fecha no válida'; end if;
    if v_fecha > now() + interval '1 day' then raise exception 'La fecha no puede ser futura'; end if;
  end if;
  update crm_gestiones x set
    fecha = case when p_datos ? 'fecha' then v_fecha else x.fecha end,
    resultado = case when p_datos ? 'resultado' then v_res else x.resultado end,
    intento = case when p_datos ? 'intento' then v_int::smallint else x.intento end,
    etapa = case when p_datos ? 'etapa' then v_etapa::smallint else x.etapa end,
    tanda = case when p_datos ? 'tanda' then v_tanda else x.tanda end,
    accion = case when p_datos ? 'accion' then v_acc else x.accion end,
    accion_fecha = case when p_datos ? 'accion_fecha' then crm_fecha_flex(p_datos->>'accion_fecha') else x.accion_fecha end,
    nota = case when p_datos ? 'nota' then left(nullif(btrim(coalesce(p_datos->>'nota', '')), ''), 1500) else x.nota end,
    call_id = case when p_datos ? 'call_id' then nullif(left(btrim(coalesce(p_datos->>'call_id', '')), 120), '') else x.call_id end,
    grabacion_url = case when p_datos ? 'grabacion_url' then nullif(left(btrim(coalesce(p_datos->>'grabacion_url', '')), 500), '') else x.grabacion_url end,
    visita_fecha = case when p_datos ? 'visita_fecha' and x.canal = 'visita' then crm_fecha_flex(p_datos->>'visita_fecha') else x.visita_fecha end,
    editado_en = now()
  where x.id = p_id returning * into g;
  return jsonb_build_object('id', g.id, 'cliente_id', g.cliente_id, 'tipo', g.tipo);
end $function$;

-- Página: deshacer (o recuperar) una gestión o un aviso al asesor. Nada se borra.
create or replace function public.crm_gestion_anular(p_id bigint, p_que text default 'gestion', p_anular boolean default true)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare v_cli uuid;
begin
  if auth.uid() is null or not crm_puede('gestionar') then raise exception 'Sin permiso'; end if;
  if coalesce(p_que, 'gestion') = 'aviso' then
    update crm_avisos_asesor set anulado = coalesce(p_anular, true) where id = p_id returning cliente_id into v_cli;
  else
    update crm_gestiones set anulado = coalesce(p_anular, true), editado_en = now() where id = p_id returning cliente_id into v_cli;
  end if;
  if v_cli is null then raise exception 'La gestión ya no existe'; end if;
  return jsonb_build_object('id', p_id, 'cliente_id', v_cli, 'anulado', coalesce(p_anular, true));
end $function$;

-- Página: seguimiento del aviso al asesor (a los 5 días): ¿contactó al cliente?
create or replace function public.crm_aviso_revisar(p_id bigint, p_estado text, p_nota text default null)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare a crm_avisos_asesor;
begin
  if auth.uid() is null or not crm_puede('gestionar') then raise exception 'Sin permiso'; end if;
  if coalesce(p_estado, '') not in ('contactado', 'no_contactado', 'pendiente') then raise exception 'Estado no válido'; end if;
  update crm_avisos_asesor x set estado = p_estado,
         revisado_el = case when p_estado = 'pendiente' then null else now() end,
         revision_nota = case when p_nota is null then x.revision_nota else left(nullif(btrim(p_nota), ''), 500) end
   where x.id = p_id and not x.anulado returning * into a;
  if a.id is null then raise exception 'El aviso ya no existe'; end if;
  return jsonb_build_object('id', a.id, 'cliente_id', a.cliente_id, 'estado', a.estado);
end $function$;

-- Página: datos de post venta del cliente (solo cambia las llaves que llegan):
--   asesor_seguimiento ('' = volver al vendedor), referencia, nota,
--   excluido_hasta + excluido_motivo (excluido_hasta '' = quitar la exclusión),
--   en_mano {"tipo":"prefiltro","valor":true|false}.
create or replace function public.crm_cliente_post_guardar(p_cliente uuid, p_datos jsonb)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare r crm_cliente_post; v_cli uuid := cli_raiz(p_cliente); v_tipo text; v_hasta date; v_hoy date := hoy_lima();
begin
  if auth.uid() is null or not crm_puede('gestionar') then raise exception 'Sin permiso'; end if;
  if v_cli is null or not exists (select 1 from crm_pedidos where cliente_id = v_cli) then raise exception 'El cliente no existe'; end if;
  if jsonb_typeof(p_datos) is distinct from 'object' then raise exception 'Datos no válidos'; end if;
  insert into crm_cliente_post (cliente_id) values (v_cli) on conflict (cliente_id) do nothing;
  if p_datos ? 'asesor_seguimiento' then
    update crm_cliente_post set asesor_seguimiento = left(nullif(btrim(coalesce(p_datos->>'asesor_seguimiento', '')), ''), 120) where cliente_id = v_cli;
  end if;
  if p_datos ? 'referencia' then
    update crm_cliente_post set referencia = left(nullif(btrim(coalesce(p_datos->>'referencia', '')), ''), 300) where cliente_id = v_cli;
  end if;
  if p_datos ? 'nota' then
    update crm_cliente_post set nota = left(nullif(btrim(coalesce(p_datos->>'nota', '')), ''), 1500) where cliente_id = v_cli;
  end if;
  if p_datos ? 'excluido_hasta' then
    v_hasta := crm_fecha_flex(p_datos->>'excluido_hasta');
    if v_hasta is null then
      -- quitar la exclusión: se deja vencida ayer y el motivo queda como constancia
      update crm_cliente_post set excluido_hasta = v_hoy - 1 where cliente_id = v_cli and excluido_hasta >= v_hoy;
    else
      if v_hasta < v_hoy then raise exception 'La fecha de la exclusión ya pasó'; end if;
      if v_hasta > v_hoy + 1100 then raise exception 'La exclusión es temporal: máximo 3 años'; end if;
      if nullif(btrim(coalesce(p_datos->>'excluido_motivo', '')), '') is null then raise exception 'Escribe el motivo de la exclusión'; end if;
      update crm_cliente_post set excluido_hasta = v_hasta, excluido_motivo = left(btrim(p_datos->>'excluido_motivo'), 300) where cliente_id = v_cli;
    end if;
  end if;
  if p_datos ? 'en_mano' then
    v_tipo := crm_g_tipo(p_datos->'en_mano'->>'tipo');
    if not exists (select 1 from crm_reglas x where x.clave = v_tipo and x.tipo_regla = 'ciclo') then raise exception 'Repuesto no válido'; end if;
    update crm_cliente_post set en_mano = case when coalesce((p_datos->'en_mano'->>'valor')::boolean, false)
                                               then en_mano || jsonb_build_object(v_tipo, to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')) else en_mano - v_tipo end
     where cliente_id = v_cli;
  end if;
  update crm_cliente_post set actualizado = now() where cliente_id = v_cli returning * into r;
  return to_jsonb(r);
end $function$;

-- Página: lo que necesita el formulario de gestiones (asesores con su celular para el aviso).
create or replace function public.crm_post_config()
 returns jsonb language plpgsql stable security definer set search_path to 'public'
as $function$
begin
  if auth.uid() is null or not crm_puede('gestionar') then raise exception 'Sin permiso'; end if;
  return jsonb_build_object(
    'hoy', hoy_lima(), 'admin', crm_puede('admin'),
    'asesores', coalesce((select jsonb_agg(jsonb_build_object('nombre', e.nombre, 'celular', nullif(crm_cel9(e.celular), '')) order by e.nombre)
                            from eq_personas e where e.activo and e.codigo_asesor is not null and coalesce(btrim(e.nombre), '') <> ''), '[]'::jsonb));
end $function$;

-- Permisos: nada para anon salvo la API del bot (que valida su llave); lo interno, para nadie de fuera.
revoke all on function public.crm_puede(text) from public, anon, authenticated;
revoke all on function public.crm_gestiones_registrar_int(jsonb, text, text, text, uuid) from public, anon, authenticated;
revoke all on function public.crm_g_clave(text), public.crm_g_tipo(text), public.crm_g_canal(text), public.crm_g_resultado(text), public.crm_g_accion(text), public.crm_g_tanda(text) from public, anon;
revoke all on function public.crm_ts(text), public.crm_fecha_flex(text) from public, anon;
grant execute on function public.crm_g_clave(text), public.crm_g_tipo(text), public.crm_g_canal(text), public.crm_g_resultado(text), public.crm_g_accion(text), public.crm_g_tanda(text), public.crm_ts(text), public.crm_fecha_flex(text) to authenticated;
revoke all on function public.crm_gestion_registrar(jsonb), public.crm_gestiones_cargar(jsonb, text), public.crm_gestion_editar(bigint, jsonb),
  public.crm_gestion_anular(bigint, text, boolean), public.crm_aviso_revisar(bigint, text, text), public.crm_cliente_post_guardar(uuid, jsonb), public.crm_post_config() from public, anon;
grant execute on function public.crm_gestion_registrar(jsonb), public.crm_gestiones_cargar(jsonb, text), public.crm_gestion_editar(bigint, jsonb),
  public.crm_gestion_anular(bigint, text, boolean), public.crm_aviso_revisar(bigint, text, text), public.crm_cliente_post_guardar(uuid, jsonb), public.crm_post_config() to authenticated;

-- Datos: la campaña del 16/11 es la primera tanda, y la regla escrita (pestaña Reglas) dice lo nuevo.
update public.crm_gestiones set tanda = 'T1' where lote = 'campana-2026-11-16' and tanda is null;
update public.crm_reglas set
  cuando = 'Cada llamada, mensaje, video, visita coordinada o aviso al asesor se anota con fecha y hora, intento, resultado, etapa, tanda y acción siguiente',
  accion = 'Cuentan como «avisado» (30 días): que el cliente conteste, pida visita, no desee o cuelgue; un mensaje o video enviado; una visita coordinada; y el aviso a su asesor. Buzón, no contesta y número errado no cuentan. El aviso al asesor se revisa a los 5 días: ¿ya contactó al cliente? La etapa es el número de cambio (1.º, 2.º, 3.º = ya no tiene repuestos del kit: toca compra). «Compró por su cuenta» reinicia el plazo sin gastar repuesto del kit. «Tiene el repuesto en mano» es una marca que dura hasta que se anote el cambio. Excluir deja al cliente fuera hasta la fecha indicada. Tanda del mes: vence hasta hoy + 30 días y sin gestión en la etapa.'
 where clave = 'gestiones';
