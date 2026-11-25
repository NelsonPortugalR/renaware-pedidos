# Pedidos y clientes · Rena Ware · Equipo Arequipa

Panel de pedidos de toda la organización (WV08), **ficha de cada cliente** y
**post venta de filtros**: a quién le toca cambiar su repuesto, qué se gestionó
con cada uno y qué sigue.

- **Pedidos**: todas las órdenes, filtros, orden por fecha, exportar a Excel.
  En el detalle, **Corregir cliente** cambia el nombre, celular o dirección de
  un pedido que salió a nombre de otra persona (queda guardado lo que decía el
  back office y la corrección resiste las recargas).
- **Clientes**: un cliente por fila (agrupado por `cliente_id`): compras,
  total, última compra, qué tiene y qué tiene pendiente. Filtros para celular
  inválido o número errado, posible nombre «comodín» (pedidos de 3 o más
  vendedores) y excluidos de post venta. El buscador de arriba (cliente,
  celular o N° de pedido, con o sin tildes) abre la ficha o el pedido.
- **Filtros** (post venta): ciclos de pre-filtro (12 m), filtro principal
  (48 m), filtro de aire (18 m) y botella (36 m) **por cliente**.
  - **Tanda del mes**: los que vencen en 30 días (o ya vencieron) y no tienen
    gestión en su etapa. También «Vence ≤ hoy + 30 días», por tanda (T1, T2…),
    por asesor de seguimiento, sin gestión, ya gestionados, con acción
    siguiente, con el repuesto en mano y número errado.
  - **📝 Gestión** en cada fila (y «Registrar gestión» en la ficha): llamada
    automática o manual (intento, resultado fijo, CallSid, grabación), mensaje
    directo, video enviado, visita coordinada y **aviso al asesor** (a quién y
    cuándo; deja listo el WhatsApp). Con etapa, tanda, acción siguiente con
    fecha y nota. Lo que llega al cliente o a su asesor deja el ciclo en
    «Avisado» 30 días; buzón, no contesta y número errado no.
  - **Avisos a asesores**: a los 5 días aparecen para marcar si ya contactó al
    cliente.
  - **⬆ Cargar resultados**: plantilla con la tanda del mes, carga de un Excel
    o CSV con los resultados (no duplica lo ya cargado) y la guía y las llaves
    de la API del bot.
- **Ficha del cliente**: datos, compras, filtros e **historial de gestiones**
  (editar o deshacer). Ahí se anota el cambio hecho (con fecha), «compró por su
  cuenta», «tiene el repuesto en mano», «ya no aplica», y se editan el
  **asesor de seguimiento** (por defecto, el vendedor), la referencia, la nota
  libre, la exclusión temporal con su motivo y el celular.
- **Análisis** (pedidos entregados, salvo donde se indique): tendencia por
  período, último período contra el anterior, distritos, crédito y contado,
  productos y:
  - **Autocompras vs. ventas a terceros**: qué parte del **monto entregado** (o
    de los pedidos: se elige arriba de la tarjeta) es *autocompra* (precio de
    asesor: la marca `autocompra` de la base), *compra propia a precio regular*
    (el asesor figura como su propio cliente) y *venta a terceros*. Solo cuentan
    los pedidos entregados: no entran rechazados, cancelados ni los que siguen
    en proceso. En total, por período (el del reporte; en % o en total) y por
    vendedor. Dice además cuántos asesores vendieron a terceros y cuántos solo
    se compraron a sí mismos.
  - **Ingreso de pedidos por día**, por la fecha en que se ordenaron: día por
    día con los períodos marcados, por día del período (1 = jueves, 14 =
    miércoles de cierre) y por día de la semana. Por defecto, solo entregados y
    en cantidad de pedidos; se puede pasar a todos los pedidos (con rechazados,
    cancelados y en proceso) y a monto. Rango: últimos 2, 6, 13 o 26 períodos,
    o todo.

  El monto es el total del pedido (el mismo de «Ventas entregadas»). Cada
  gráfico muestra el detalle al pasar el cursor o tocar y tiene «Ver tabla»; lo
  que se elige en estas tarjetas se recuerda en el dispositivo. El calendario
  de períodos (14 días desde el jueves 25/12/2025 = 2026-PB01) es la misma
  cuenta que `periodo_indice()` en la base. El período de un pedido es el de su
  reporte y puede ser el siguiente al de su fecha: por eso el conteo por día no
  siempre calza con el conteo por período.
- **Cuotas** y **Reglas** (las reglas que generan todo, leídas de
  `crm_reglas`).

Los **mensajes de WhatsApp al cliente** viven en
[Bienvenida](https://renaware-bienvenida.pages.dev) (grupo Clientes); esta
página muestra su estado y enlaza allá (`#c=<cliente_id>`, con traspaso de
sesión).

- `public/index.html` — la app completa (una sola página, sin build)
- `sql/` — lo aplicado en la base para este módulo (ver `sql/LEEME.md`)
- `pruebas/prueba.js` — prueba de punta a punta
- `wrangler.toml` — dice que el sitio son los archivos de `public/`

## Cómo se publica

Sitio estático, sin build ni dependencias. Cloudflare está conectado a este
repositorio: **cada push a `main` publica**.

## Pruebas

```
NODE_PATH=$(npm root -g) node pruebas/prueba.js
```

Chromium real (playwright) contra un Supabase falso que aplica las mismas
reglas que la base y **rechaza escrituras directas** a las tablas que deben
entrar por función. Sin internet hacen falta las dos librerías de la página:
`npm i --no-save --prefix pruebas @supabase/supabase-js@2 xlsx@0.18.5`.
`CAPTURAS=/carpeta` guarda capturas de escritorio y celular.

## De dónde salen los datos

**El repo no tiene datos de clientes.** Todo vive en Supabase (proyecto
`kiexpdaaoegbtesqmaff`):

| Qué | Dónde |
|---|---|
| Órdenes | tabla `crm_pedidos` (una fila por orden, `cliente_id` → `clientes`) |
| Acciones por cliente: mensajes por orden y ciclos de filtros con su estado, etapa, tanda, gestiones y avisos | función `crm_acciones()` — la misma que leen Bienvenida, el hub y el bot |
| Estado del ciclo (cambio hecho, por su cuenta, ya no aplica) y mensajes de Bienvenida | tabla `crm_seguimiento` (deshacer = `anulado`) |
| Contactos con el cliente (llamadas, mensajes, videos, visitas) | tabla `crm_gestiones`, por `crm_gestion_registrar` / `_editar` / `_anular` |
| Avisos al asesor y su revisión a los 5 días | tabla `crm_avisos_asesor`, por `crm_gestion_registrar` (canal `aviso_asesor`) y `crm_aviso_revisar` |
| Asesor de seguimiento, referencia, nota, exclusión, repuesto en mano | tabla `crm_cliente_post`, por `crm_cliente_post_guardar` |
| Carga en lote | `crm_gestiones_cargar` (sesión) y `crm_bot_registrar` / `crm_bot_pendientes` (llave del bot): una sola implementación, `crm_gestiones_registrar_int` |
| Reglas | tabla `crm_reglas` |

Las tablas tienen RLS: solo las cuentas de la oficina leen, y lo nuevo se
escribe por función que valida la sesión (`crm_puede`). La app usa la clave
pública de Supabase; la protección la dan el ingreso y esas reglas.

Los pedidos se cargan al cierre de cada período, directo a Supabase: actualizar
datos no requiere publicar.

Enlaces: `#cliente=<id>` abre una ficha, `#orden=<n>` un pedido, `#tab=<id>` una pestaña.
