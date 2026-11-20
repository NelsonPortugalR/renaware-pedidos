-- Post venta (20/11/2026) · 1 de 3: tablas. Todo aditivo (sin drop); aplicado con execute_sql.
-- Más datos por gestión, avisos al asesor con su seguimiento a los 5 días y datos por cliente.

alter table public.crm_gestiones
  add column if not exists tanda text check (tanda ~ '^T[0-9]{1,3}$'),
  add column if not exists video boolean not null default false,
  add column if not exists celular text check (char_length(celular) <= 20),
  add column if not exists visita_fecha date,
  add column if not exists editado_en timestamptz;
comment on table public.crm_gestiones is 'Post venta: cada contacto con el cliente por un repuesto (llamada automática o manual, mensaje directo, video enviado, visita coordinada) con la respuesta del cliente. Los avisos al asesor van en crm_avisos_asesor. Nada se borra: anulado.';
comment on column public.crm_gestiones.tanda is 'Tanda de la campaña en la que se hizo (T1, T2…).';
comment on column public.crm_gestiones.video is 'El mensaje fue el video (canal whatsapp): «video enviado».';
comment on column public.crm_gestiones.celular is 'Número (9 dígitos) al que se llamó o escribió; sirve para saber si un «número errado» sigue vigente.';
comment on column public.crm_gestiones.visita_fecha is 'Canal visita: día acordado para la visita.';
comment on column public.crm_gestiones.canal is 'llamada_auto, llamada, whatsapp (mensaje directo; con video = true es «video enviado») o visita (visita coordinada).';
comment on column public.crm_gestiones.resultado is 'Respuesta del cliente: pidio_visita, no_desea, contesto, colgo, buzon, no_contesta, numero_errado. En mensajes, no_contesta = sin respuesta aún.';
comment on column public.crm_gestiones.etapa is 'Número de cambio del repuesto en que estaba el cliente (1.º, 2.º, 3.º).';

alter table public.crm_cliente_post
  add column if not exists nota text check (char_length(nota) <= 1500),
  add column if not exists en_mano jsonb not null default '{}'::jsonb;
comment on table public.crm_cliente_post is 'Post venta: datos que se editan por cliente (asesor de seguimiento, exclusión temporal, referencia, nota libre, repuesto en mano).';
comment on column public.crm_cliente_post.nota is 'Nota libre del cliente para post venta.';
comment on column public.crm_cliente_post.en_mano is 'Repuestos que el cliente ya tiene en mano: {"prefiltro":"2026-11-20T15:00:00Z"} = desde cuándo. Se apaga solo cuando después se anota el cambio (o que lo compró por su cuenta) o compra otro repuesto.';

create table if not exists public.crm_avisos_asesor (
  id bigint generated always as identity primary key,
  cliente_id uuid not null,
  tipo text not null default 'prefiltro',
  etapa smallint check (etapa between 1 and 3),
  tanda text check (tanda ~ '^T[0-9]{1,3}$'),
  asesor text not null check (char_length(asesor) between 2 and 120),
  fecha timestamptz not null default now(),
  nota text check (char_length(nota) <= 1500),
  revisar_el date not null,
  estado text not null default 'pendiente' check (estado in ('pendiente', 'contactado', 'no_contactado')),
  revisado_el timestamptz,
  revision_nota text check (char_length(revision_nota) <= 500),
  gestion_id bigint,
  origen text not null default 'portal' check (origen in ('portal', 'bot', 'campana')),
  lote text,
  anulado boolean not null default false,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
comment on table public.crm_avisos_asesor is 'Post venta: avisos al asesor para que contacte a su cliente (a quién y cuándo). A los 5 días toca revisar si lo contactó: estado pendiente → contactado / no_contactado. Nada se borra: anulado.';
comment on column public.crm_avisos_asesor.asesor is 'A quién se avisó.';
comment on column public.crm_avisos_asesor.fecha is 'Cuándo se avisó.';
comment on column public.crm_avisos_asesor.revisar_el is 'Día en que toca revisar si el asesor contactó al cliente (5 días después del aviso).';
comment on column public.crm_avisos_asesor.gestion_id is 'Gestión (crm_gestiones.id) que originó el aviso, si la hubo.';
create index if not exists crm_avisos_asesor_cliente on public.crm_avisos_asesor (cliente_id, tipo);
create index if not exists crm_gestiones_cliente on public.crm_gestiones (cliente_id, tipo);
-- Se lee con la sesión de la oficina (crm_acciones corre con los permisos de quien llama); se escribe solo por función.
alter table public.crm_avisos_asesor enable row level security;
revoke all on table public.crm_avisos_asesor from anon, authenticated;
grant select on table public.crm_avisos_asesor to authenticated;
create policy crm_avisos_asesor_ver on public.crm_avisos_asesor for select to authenticated
  using ((auth.jwt() ->> 'email') = any (array['CORREO_OFICINA_1', 'CORREO_OFICINA_2']));
