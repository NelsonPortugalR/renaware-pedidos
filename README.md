# Pedidos Rena Ware · Equipo Arequipa

Panel de pedidos de toda la organización (WV08) y **seguimiento de clientes**:
bienvenida y videos de uso, Nutri Sensor a la semana, brillo y Rena Lite al mes,
cambio de pre-filtro (12 m), filtro principal (48 m) y filtro de aire (18 m), y
aviso un mes antes de terminar las cuotas.

- `public/index.html` — la app completa (una sola página)
- `public/_headers`, `public/robots.txt`, `public/404.html` — configuración
- `wrangler.toml` — dice que el sitio son los archivos de `public/`

## Cómo se publica

Sitio estático, sin build ni dependencias. Cloudflare está conectado a este
repositorio: **cada push a `main` publica**. No hay que subir nada a mano.

La conexión se hace una sola vez: Cloudflare → Workers & Pages → Create →
Import a repository → `renaware-pedidos`, rama `main`, sin comando de build.
El `wrangler.toml` se encarga del resto.

## De dónde salen los datos

**El repo no tiene datos de clientes.** Todo vive en Supabase (proyecto
`kiexpdaaoegbtesqmaff`), en dos tablas propias que no tocan el resto del
proyecto:

| Tabla | Qué guarda |
|---|---|
| `crm_pedidos` | un registro por orden (cliente, productos, fechas, estado, financiamiento) |
| `crm_seguimiento` | cada gestión registrada (qué acción, qué orden, qué fecha) |

Ambas tienen RLS: solo los correos autorizados ven y escriben. La app usa la
clave pública de Supabase; la protección la dan el login y las reglas.

Los pedidos se cargan **una vez al cierre de cada período** (14 días), desde el
back office, directo a Supabase. Por eso actualizar datos no requiere publicar.
