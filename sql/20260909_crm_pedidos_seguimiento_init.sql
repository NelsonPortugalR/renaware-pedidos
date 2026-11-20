-- Migración «crm_pedidos_seguimiento_init» (20260909163108), copiada del historial de Supabase el 20/11/2026. Ya está aplicada.


-- Módulo CRM de pedidos Rena Ware (aislado, no toca las tablas existentes)
create table if not exists public.crm_pedidos (
  n_orden               bigint primary key,
  periodo               text,
  fecha_ordenado        text,
  fecha_comision        text,
  fecha_entrega_aprox   text,
  fecha_despacho        text,
  fecha_enviado         text,
  delivery_date         text,
  gdr                   text,
  estatus               text,
  vendedor              text,
  id_vendedor           bigint,
  codigo_oficina        text,
  almacen               text,
  tipo_orden            text,
  comisionable          text,
  document_type         text,
  commissionable_value  numeric,
  puntos                integer,
  cliente               text,
  direccion             text,
  ciudad                text,
  celular               text,
  email                 text,
  credito_contado       text,
  cuotas                integer,
  tasa                  numeric,
  cupon                 numeric,
  deposito              numeric,
  financiado            numeric,
  interes               numeric,
  expenses              numeric,
  total                 numeric,
  productos             text,
  notas                 text,
  updated_at            timestamptz default now()
);

create table if not exists public.crm_seguimiento (
  id             bigint generated always as identity primary key,
  n_orden        bigint not null,
  tipo           text not null,
  fecha_gestion  text not null,        -- dd/mm/aaaa
  nota           text,
  created_by     uuid default auth.uid(),
  created_at     timestamptz default now()
);
create index if not exists crm_seguimiento_orden_tipo_idx on public.crm_seguimiento (n_orden, tipo);

alter table public.crm_pedidos     enable row level security;
alter table public.crm_seguimiento enable row level security;

-- Acceso restringido a los correos autorizados
create policy crm_pedidos_rw on public.crm_pedidos for all to authenticated
  using ( (auth.jwt() ->> 'email') = any (array['CORREO_OFICINA_1','CORREO_OFICINA_2']) )
  with check ( (auth.jwt() ->> 'email') = any (array['CORREO_OFICINA_1','CORREO_OFICINA_2']) );

create policy crm_seguimiento_rw on public.crm_seguimiento for all to authenticated
  using ( (auth.jwt() ->> 'email') = any (array['CORREO_OFICINA_1','CORREO_OFICINA_2']) )
  with check ( (auth.jwt() ->> 'email') = any (array['CORREO_OFICINA_1','CORREO_OFICINA_2']) );
