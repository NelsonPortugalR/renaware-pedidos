# Pedidos y clientes · Rena Ware · Equipo Arequipa

Panel de pedidos de toda la organización (WV08) y **ficha de cada cliente**:
compras, qué tiene, filtros con sus fechas de cambio, cuotas y lo anotado.

- **Pedidos**: todas las órdenes, filtros, orden por fecha, exportar a Excel.
- **Clientes**: un cliente por fila (agrupado por `cliente_id`): compras,
  total, última compra, qué tiene (ollas, sartenes, filtro de agua, cocina,
  olla a presión, purificador, repuestos) y qué tiene pendiente. Toca una fila
  para abrir su ficha. El buscador de arriba (cliente, celular o N° de pedido)
  abre la ficha o el pedido desde cualquier pestaña.
- **Filtros**: ciclos de pre-filtro (12 m), filtro principal / elemento
  desechable (48 m) y filtro de aire (18 m) **por cliente**: la base es la
  entrega del sistema o la compra del último repuesto de ese filtro, lo que sea
  más reciente; comprar un repuesto reinicia el ciclo. En la ficha se anota el
  **cambio hecho** (con fecha, reinicia el ciclo) o **ya no aplica** (lo cierra).
- **Cuotas**: créditos en curso primero, ordenados por lo que falta (estimado
  por meses transcurridos).
- **Análisis**: tendencia por período, último período cerrado vs. el anterior,
  vendedores, distritos, productos.

Los **mensajes a clientes** (bienvenida al recibir, semana 1, mes 1, fin de
cuotas y los avisos de cambio de filtro) **ya no se gestionan aquí**: viven en
[Bienvenida](https://renaware-bienvenida.pages.dev) (grupo Clientes). Esta
página solo muestra su estado y enlaza allá (`#c=<cliente_id>`, con traspaso de
sesión si la cuenta tiene rol en la plataforma).

- `public/index.html` — la app completa (una sola página, sin build)
- `public/_headers`, `public/robots.txt`, `public/404.html` — configuración
- `wrangler.toml` — dice que el sitio son los archivos de `public/`

## Cómo se publica

Sitio estático, sin build ni dependencias. Cloudflare está conectado a este
repositorio: **cada push a `main` publica**. No hay que subir nada a mano.

## De dónde salen los datos

**El repo no tiene datos de clientes.** Todo vive en Supabase (proyecto
`kiexpdaaoegbtesqmaff`):

| Qué | Dónde |
|---|---|
| Órdenes (cliente, productos, fechas, estado, financiamiento) | tabla `crm_pedidos` (una fila por orden, `cliente_id` → `clientes`) |
| Acciones por cliente: mensajes por orden y ciclos de filtros, con su estado | función `crm_acciones()` — la misma que lee Bienvenida |
| Lo anotado (cambio hecho, ya no aplica, mensajes enviados u omitidos) | tabla `crm_seguimiento` (`modo`: cambio, noaplica, whatsapp, aviso, omitido; deshacer = `anulado`) |

Las tablas tienen RLS: solo los correos autorizados ven y escriben. La app usa
la clave pública de Supabase; la protección la dan el login y las reglas.

Los pedidos se cargan **una vez al cierre de cada período** (14 días), desde el
back office, directo a Supabase. Por eso actualizar datos no requiere publicar.

Enlaces: `#cliente=<id>` abre una ficha, `#orden=<n>` un pedido, `#tab=<id>` una pestaña.
