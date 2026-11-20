-- Migración «crm_bot_api_y_regex_aqua» (20261118015340), copiada del historial de Supabase el 20/11/2026. Ya está aplicada.

-- "AQUA CHECK NANO 500 CTU UNID PORTÁTIL" (formato antiguo, sin paréntesis) también es un sistema de agua
update public.crm_reglas set re_sistema = '(AQUA NANO|AQUA CHECK NANO 500 CTU \(?UNID|AQUA CHECK NANO 500 UCU|LX-500)', actualizado = now()
 where clave in ('prefiltro', 'filtroppal');

create or replace function public.crm_cel_e164(p text) returns text language sql immutable as $$
  select case when public.crm_cel9(p) ~ '^9\d{8}$' then '+51' || public.crm_cel9(p) end $$;

-- Lista para llamar: ciclos que vencen hasta hoy + p_dias, sin cerrar ni excluir
create or replace function public.crm_bot_pendientes(p_clave text, p_dias int default 30, p_tipo text default 'prefiltro')
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
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
      'ultima_gestion', j->'ultima_gestion', 'n_orden', (j->>'n_orden')::bigint, 'sistema', j->>'sistema')
      order by (j->>'vence'), j->>'cliente'), '[]'::jsonb) into v
    from crm_acciones() j
   where j->>'clase' = 'ciclo' and (p_tipo is null or j->>'tipo' = p_tipo)
     and j->>'estado' not in ('cerrado', 'excluido')
     and (j->>'dias')::int <= coalesce(p_dias, 30);
  return v;
end $$;

-- Registro de gestiones en lote (resultados de llamadas automáticas)
create or replace function public.crm_bot_registrar(p_clave text, p_filas jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare f jsonb; i int := 0; v_cli uuid; v_tipo text; v_res text; v_canal text; v_etapa int; v_n bigint;
        ins int := 0; dup int := 0; sin jsonb := '[]'::jsonb; err jsonb := '[]'::jsonb; v_cel text; v_cnt int;
begin
  if not crm_bot_valida(p_clave) then raise exception 'Clave no valida'; end if;
  if jsonb_typeof(p_filas) <> 'array' then raise exception 'Se espera una lista de gestiones'; end if;
  if jsonb_array_length(p_filas) > 2000 then raise exception 'Maximo 2000 gestiones por envio'; end if;
  for f in select * from jsonb_array_elements(p_filas) loop
    i := i + 1;
    begin
      v_tipo := coalesce(nullif(f->>'tipo', ''), 'prefiltro');
      v_res := lower(coalesce(f->>'resultado', ''));
      v_res := case v_res when '1' then 'pidio_visita' when '2' then 'no_desea' when 'sin_marcar' then 'contesto' when 'contesto_sin_marcar' then 'contesto'
                          when 'buzon_de_voz' then 'buzon' when 'no_contesto' then 'no_contesta' else v_res end;
      v_canal := coalesce(nullif(f->>'canal', ''), 'llamada_auto');
      v_cli := nullif(f->>'cliente_id', '')::uuid;
      v_n := nullif(f->>'n_orden', '')::bigint;
      if v_cli is null and v_n is not null then select cliente_id into v_cli from crm_pedidos where n_orden = v_n; end if;
      if v_cli is null and nullif(f->>'celular', '') is not null then
        v_cel := crm_cel9(f->>'celular');
        select count(distinct cliente_id), min(cliente_id::text)::uuid into v_cnt, v_cli from crm_pedidos where crm_cel9(celular) = v_cel and cliente_id is not null;
        if v_cnt <> 1 then v_cli := null; end if;
      end if;
      if v_cli is null then sin := sin || jsonb_build_object('fila', i, 'dato', f); continue; end if;
      if nullif(f->>'call_id', '') is not null and exists (select 1 from crm_gestiones g where g.cliente_id = v_cli and g.tipo = v_tipo and g.call_id = f->>'call_id' and not g.anulado) then
        dup := dup + 1; continue;
      end if;
      v_etapa := nullif(f->>'etapa', '')::int;
      if v_etapa is null then
        select (j->>'etapa')::int into v_etapa from crm_acciones() j where j->>'clase' = 'ciclo' and j->>'cliente_id' = v_cli::text and j->>'tipo' = v_tipo;
      end if;
      insert into crm_gestiones (cliente_id, tipo, n_orden, fecha, canal, intento, resultado, etapa, accion, accion_fecha, nota, call_id, grabacion_url, origen, lote, created_by)
      values (v_cli, v_tipo, v_n, coalesce(nullif(f->>'fecha', '')::timestamptz, now()), v_canal, nullif(f->>'intento', '')::smallint, v_res, v_etapa,
              nullif(f->>'accion', ''), nullif(f->>'accion_fecha', '')::date, nullif(f->>'nota', ''), nullif(f->>'call_id', ''), nullif(f->>'grabacion_url', ''),
              'bot', nullif(f->>'lote', ''), null);
      ins := ins + 1;
    exception when others then
      err := err || jsonb_build_object('fila', i, 'error', sqlerrm);
    end;
  end loop;
  return jsonb_build_object('insertadas', ins, 'duplicadas', dup, 'sin_cliente', sin, 'errores', err);
end $$;
revoke all on function public.crm_bot_pendientes(text, int, text) from public;
revoke all on function public.crm_bot_registrar(text, jsonb) from public;
grant execute on function public.crm_bot_pendientes(text, int, text) to anon, authenticated;
grant execute on function public.crm_bot_registrar(text, jsonb) to anon, authenticated;

-- regla visible
insert into public.crm_reglas (clave, tipo_regla, nombre, aplica_a, cuando, accion, orden) values
('gestiones', 'ajuste', 'Gestiones de post venta', 'Ciclos de filtros y botella',
 'Cada llamada, WhatsApp o visita se anota con canal, intento, resultado, etapa y acción siguiente',
 'Contestó, pidió visita, no desea o colgó cuentan como «avisado» (30 días). La etapa es el número de cambio (1.º, 2.º, 3.º = ya no tiene repuestos del kit: toca compra). «Compró por su cuenta» reinicia el plazo sin gastar repuesto del kit. Excluir deja al cliente fuera hasta la fecha indicada. Lista para llamar: vence hasta hoy + 30 días y sin gestión en la etapa.', 6)
on conflict (clave) do nothing;
