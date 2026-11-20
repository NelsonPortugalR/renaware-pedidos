# SQL del módulo Pedidos

Copia de lo que se aplicó en la base (Supabase `kiexpdaaoegbtesqmaff`) para este módulo, en orden de fecha.
La base es la que manda: antes de cambiar una función grande, leer su definición viva (`pg_get_functiondef`).

- Hasta el 18/11/2026: migraciones copiadas del historial de Supabase.
- `20261120_postventa_*`: registro de gestiones, avisos al asesor, datos por cliente y carga en lote. Todo aditivo
  (sin `drop`), aplicado con `execute_sql`; `crm_acciones` se parchó en vivo (archivo 03).
- El repo es público: los correos de la oficina van como `CORREO_OFICINA_1` y `CORREO_OFICINA_2`. Los reales están en la
  base (políticas `crm_*` y función `crm_puede`). Aquí no va ningún dato de clientes.
