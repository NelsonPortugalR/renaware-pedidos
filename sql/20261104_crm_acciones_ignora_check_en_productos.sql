-- Migración «crm_acciones_ignora_check_en_productos» (20261104174537), copiada del historial de Supabase el 20/11/2026. Ya está aplicada.

do $x$
declare src text; n1 int; n2 int; n3 int;
begin
  select pg_get_functiondef(p.oid) into src from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'crm_acciones';
  if position('[✓✔]' in src) > 0 then return; end if;
  n1 := (length(src) - length(replace(src, $s$upper(coalesce(c.productos, '')) prod$s$, ''))) / length($s$upper(coalesce(c.productos, '')) prod$s$);
  n2 := (length(src) - length(replace(src, $s$where upper(it) ~ c.re_sistema$s$, ''))) / length($s$where upper(it) ~ c.re_sistema$s$);
  n3 := (length(src) - length(replace(src, $s$and upper(it) !~ coalesce(c.re_excluir$s$, ''))) / length($s$and upper(it) !~ coalesce(c.re_excluir$s$);
  if n1 <> 1 or n2 <> 1 or n3 <> 1 then raise exception 'puntos de parche: %, % y %', n1, n2, n3; end if;
  -- "AQUA ✓ NANO CTU-500": el back office mete una marca entre las palabras; se quita antes de buscar palabras clave
  src := replace(src, $s$upper(coalesce(c.productos, '')) prod$s$, $s$upper(regexp_replace(coalesce(c.productos, ''), '[✓✔]\s*', '', 'g')) prod$s$);
  src := replace(src, $s$where upper(it) ~ c.re_sistema$s$, $s$where upper(regexp_replace(it, '[✓✔]\s*', '', 'g')) ~ c.re_sistema$s$);
  src := replace(src, $s$and upper(it) !~ coalesce(c.re_excluir$s$, $s$and upper(regexp_replace(it, '[✓✔]\s*', '', 'g')) !~ coalesce(c.re_excluir$s$);
  execute src;
end $x$;
