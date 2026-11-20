-- Migración «crm_regla_botella_filtrante» (20261103021148), copiada del historial de Supabase el 20/11/2026. Ya está aplicada.

insert into public.crm_reglas (clave,tipo_regla,nombre,aplica_a,cuando,accion,intervalo_meses,familia,re_sistema,re_excluir,re_repuesto,sistema_def,orden) values
('botella','ciclo','Renovar botella filtrante','Clientes con botella filtrante (sola o de regalo en un combo)','Cada 36 meses (3 años) desde que recibió su botella o compró la última','Ofrecer renovar la botella filtrante',36,'botella','(BOTELLA FILTRANTE)','(BANDAS)',null,'Botella filtrante',80)
on conflict (clave) do nothing;

alter table public.crm_seguimiento drop constraint if exists crm_seguimiento_tipo_chk;
alter table public.crm_seguimiento add constraint crm_seguimiento_tipo_chk
  check (tipo = any (array['bienvenida','semana1','mes1','fincuotas','prefiltro','filtroppal','aire','botella']));

CREATE OR REPLACE FUNCTION public.wa_cl_envio_registrar(p_token uuid, p_n_orden bigint, p_tipo text, p_modo text, p_texto text, p_fecha date DEFAULT NULL::date)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_cli uuid; v_f date := coalesce(p_fecha, public.hoy_lima());
begin
  if not public.es_admin(p_token) then raise exception 'Sesion invalida'; end if;
  select cliente_id into v_cli from public.crm_pedidos where n_orden = p_n_orden;
  if v_cli is null then raise exception 'La orden no existe'; end if;
  if not exists (select 1 from public.crm_reglas r where r.clave = coalesce(p_tipo, '')) then raise exception 'Paso no valido'; end if;
  if coalesce(p_modo, '') not in ('whatsapp', 'aviso', 'omitido', 'cambio', 'noaplica') then raise exception 'Modo no valido'; end if;
  if v_f > public.hoy_lima() or v_f < date '2015-01-01' then raise exception 'Fecha no valida'; end if;
  if not exists (select 1 from public.crm_seguimiento s where s.n_orden = p_n_orden and s.tipo = p_tipo and s.modo = p_modo and not s.anulado and s.created_at > now() - interval '10 minutes') then
    insert into public.crm_seguimiento (n_orden, tipo, fecha_gestion, modo, texto, cliente_id)
    values (p_n_orden, p_tipo, to_char(v_f, 'DD/MM/YYYY'), p_modo, left(nullif(btrim(p_texto), ''), 1500), v_cli);
  end if;
  return public.wa_cl_cliente_json(v_cli);
end $function$;
