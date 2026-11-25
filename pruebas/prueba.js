// Prueba de punta a punta de Pedidos: Chromium real con un Supabase falso.
// El Supabase falso guarda pedidos, ciclos de filtros, gestiones y avisos en memoria, aplica las mismas
// reglas que la base (qué cuenta como «avisado», tanda del mes, número errado, repuesto en mano) y
// RECHAZA cualquier escritura directa a una tabla que deba entrar por función: si la página lo intenta, falla.
// Uso: NODE_PATH=$(npm root -g) node pruebas/prueba.js      (necesita playwright)
// Sin internet hacen falta las dos librerías de la página:  npm i --no-save --prefix pruebas @supabase/supabase-js@2 xlsx@0.18.5
// Capturas: CAPTURAS=/ruta/carpeta (ESCALA=2 para verlas en pantalla)   ·   Con datos reales (no se guardan en el repo): DATOS=/ruta con pedidos.json
//   y acciones.json; si solo está pedidos.json, mira solo Análisis
'use strict';
const http = require('http');
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');

const RAIZ = path.join(__dirname, '..');
const SB = 'https://kiexpdaaoegbtesqmaff.supabase.co';
const HOY = '2026-11-20';
const AHORA = new Date('2026-11-20T10:00:00-05:00');
const CORREO = 'oficina@prueba.test';
const CORS = { 'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'access-control-allow-methods': '*', 'access-control-expose-headers': 'content-range, content-length, content-type' };
const esperar = (ms) => new Promise((r) => setTimeout(r, ms));

/* ---------------- librerías de la página (CDN) desde node_modules ---------------- */
function raizPaquete(nombre) {
  const donde = [path.join(__dirname, 'node_modules'), path.join(RAIZ, 'node_modules')].concat((process.env.NODE_PATH || '').split(path.delimiter).filter(Boolean));
  for (const d of donde) { const p = path.join(d, nombre); if (fs.existsSync(p)) return p; }
  return null;
}
function leerLib(nombre, archivo) { const r = raizPaquete(nombre); const f = r && path.join(r, archivo); return f && fs.existsSync(f) ? fs.readFileSync(f) : null; }
const LIB_SB = leerLib('@supabase/supabase-js', 'dist/umd/supabase.js');
const LIB_XLSX = leerLib('xlsx', 'dist/xlsx.full.min.js');
let XLSX = null; try { XLSX = require(raizPaquete('xlsx')); } catch (e) { /* sin la librería, la carga de Excel no se prueba */ }

/* ---------------- fechas ---------------- */
function iso(d) { return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0'); }
function fecha(s) { const [y, m, d] = String(s).slice(0, 10).split('-').map(Number); return new Date(y, m - 1, d); }
function masDias(s, n) { const d = fecha(s); return iso(new Date(d.getFullYear(), d.getMonth(), d.getDate() + n)); }
function masMeses(s, n) { const d = fecha(s); return iso(new Date(d.getFullYear(), d.getMonth() + n, d.getDate())); }
function dias(a, b) { return Math.round((fecha(b) - fecha(a)) / 864e5); }
function dmy(s) { const [y, m, d] = String(s).slice(0, 10).split('-'); return d + '/' + m + '/' + y; }
function limaDia(ts) { return new Date(new Date(ts).getTime() - 5 * 3600e3).toISOString().slice(0, 10); }
function mayor() { return [...arguments].filter(Boolean).sort().pop() || null; }

/* ---------------- datos de mentira (ningún dato real en el repo) ---------------- */
const MIRIAM = 'Marta Salas Quiroz', OLGA = 'Olga Paredes Ticona', NELSON = 'Nestor Lider Oficina';
const C = (n) => 'c0000000-0000-4000-8000-00000000000' + n;
function pedido(n, o) {
  return Object.assign({ n_orden: n, periodo: '2025-PB24 (13-26 nov)', fecha_ordenado: '01/11/2025', fecha_comision: null, fecha_entrega_aprox: null, fecha_despacho: null, fecha_enviado: null,
    delivery_date: null, gdr: null, estatus: 'ENTREGADA', vendedor: MIRIAM, id_vendedor: 100001, codigo_oficina: 'WV08', almacen: 'AQP', tipo_orden: 'Regular', comisionable: 'Sí', document_type: 'Boleta',
    commissionable_value: 1000, puntos: 10, cliente: '', cliente_id: null, direccion: '', ciudad: 'Cayma, Arequipa', celular: '', email: '', credito_contado: 'Contado', cuotas: null, tasa: null, cupon: null,
    deposito: null, financiado: null, interes: null, expenses: null, total: 1000, productos: '', notas: null, autocompra: false, vendedor_bo: null, cliente_bo: null, celular_bo: null, direccion_bo: null,
    id_vendedor_bo: null, cliente_corregido: false, updated_at: '2026-11-18T01:45:51+00:00' }, o);
}
function datosDePrueba() {
  const AQUA = '2350 - AQUA ✓ NANO CTU-500 (x1 S/3,499) | 2351 - Prefiltro EM para Aqua CK Nano (x2 S/0)';
  const pedidos = [
    pedido(9000001, { cliente: 'Ana Torres Vega', cliente_id: C(1), celular: '959000001', direccion: 'Av. Ejército 100', fecha_ordenado: '23/11/2025', delivery_date: '25/11/2025', estatus: 'ENTREGADA 25/11/2025', productos: AQUA + ' | 6030 - Nueva Botella Filtrante (x1 S/0)', total: 3499, credito_contado: 'Crédito', cuotas: 12 }),
    pedido(9000002, { cliente: 'Bruno Díaz Ríos', cliente_id: C(2), celular: '95900', direccion: 'Calle Lima 506', ciudad: 'Yanahuara, Arequipa, Arequipa, PE', vendedor: OLGA, fecha_ordenado: '28/10/2025', delivery_date: '30/10/2025', estatus: 'ENTREGADA 30/10/2025', productos: AQUA, total: 3499 }),
    pedido(9000003, { cliente: 'Carla Núñez Paz', cliente_id: C(3), celular: '959000003', direccion: 'Av. Bolognesi 300', ciudad: 'Tacna, Tacna', fecha_ordenado: '28/11/2025', delivery_date: '30/11/2025', estatus: 'ENTREGADA 30/11/2025', productos: AQUA, total: 3499 }),
    pedido(9000004, { cliente: 'Darío Peña León', cliente_id: C(4), celular: '959000004', direccion: 'Urb. Los Pinos B-4', ciudad: 'Cerro Colorado, Arequipa', vendedor: OLGA, fecha_ordenado: '08/12/2025', delivery_date: '10/12/2025', estatus: 'ENTREGADA 10/12/2025', productos: AQUA, total: 3499 }),
    pedido(9000005, { cliente: 'Elsa Quispe Mamani', cliente_id: C(5), celular: '959000005', direccion: 'Av. Dolores 77', ciudad: 'Jose Luis Bustamante Y Rivero, Arequipa', fecha_ordenado: '30/05/2025', delivery_date: '01/06/2025', estatus: 'ENTREGADA 1/06/2025', productos: '4001 - PURIFICADOR DE AIRE RENA AIR (x1 S/2,890)', total: 2890 }),
    pedido(9000006, { cliente: 'Comodín Pérez Pérez', cliente_id: C(6), celular: '994000006', direccion: 'Av. Cayma 628', fecha_ordenado: '27/10/2025', delivery_date: '29/10/2025', estatus: 'ENTREGADA 29/10/2025', productos: '96 - Prefiltro EM para Aqua CK Nano (S/222) | 2351 - Prefiltro EM para Aqua CK Nano', total: 222 }),
    pedido(9000007, { cliente: 'Comodín Pérez Pérez', cliente_id: C(6), celular: '994000006', direccion: 'Av. Cayma 628', vendedor: OLGA, fecha_ordenado: '05/01/2026', delivery_date: '07/01/2026', estatus: 'ENTREGADA 7/01/2026', productos: '336 - JUEGO CHEF II 7PZAS (x1 S/4,200)', total: 4200 }),
    pedido(9000008, { cliente: 'Comodín Pérez Pérez', cliente_id: C(6), celular: '994000006', direccion: 'Av. Cayma 628', vendedor: NELSON, fecha_ordenado: '10/02/2026', delivery_date: '12/02/2026', estatus: 'ENTREGADA 12/02/2026', productos: 'SET RENA LITE 04 UNIDADES (x1 S/380)', total: 380 }),
    pedido(9000009, { cliente: 'Fabio Rojas Luna', cliente_id: C(7), celular: '959000007', direccion: 'Jr. Piérola 12', ciudad: 'Jose Luis Bustamante y Rivero, Arequipa', fecha_ordenado: '30/05/2026', delivery_date: '01/06/2026', estatus: 'ENTREGADA 1/06/2026', productos: AQUA, total: 3499 }),
    pedido(9000010, { cliente: 'Gina Rechazada Sola', cliente_id: C(8), celular: '959000008', fecha_ordenado: '02/11/2026', estatus: 'RECHAZADA', productos: '165 - Nueva Saucier con Tapa 1.75 Lt (S/640)', total: 640 })
  ];
  const cic = (n, tipo, o) => Object.assign({ clase: 'ciclo', tipo, n_orden: n, intervalo: { prefiltro: 12, filtroppal: 48, aire: 18, botella: 36 }[tipo], fecha_sistema: null, fecha_repuesto: null, sistema: null,
    seg: [], gestiones_post: [], avisos_asesor: [] }, o);
  const ciclos = [
    cic(9000001, 'prefiltro', { fecha_sistema: '2025-11-25', sistema: 'AQUA ✓ NANO CTU-500' }), cic(9000001, 'filtroppal', { fecha_sistema: '2025-11-25', sistema: 'AQUA ✓ NANO CTU-500' }), cic(9000001, 'botella', { fecha_sistema: '2025-11-25', sistema: 'Nueva Botella Filtrante' }),
    cic(9000002, 'prefiltro', { fecha_sistema: '2025-10-30', sistema: 'AQUA ✓ NANO CTU-500' }), cic(9000002, 'filtroppal', { fecha_sistema: '2025-10-30', sistema: 'AQUA ✓ NANO CTU-500' }),
    cic(9000003, 'prefiltro', { fecha_sistema: '2025-11-30', sistema: 'AQUA ✓ NANO CTU-500', gestiones_post: [{ id: 1, fecha: '2026-11-16T17:00:00+00:00', canal: 'llamada_auto', intento: 1, resultado: 'pidio_visita', etapa: 1, accion: 'coordinar_visita', accion_fecha: null, nota: 'Campaña del 16/11', call_id: null, grabacion_url: null, origen: 'campana', tanda: 'T1', video: false, celular: null, visita_fecha: null, lote: 'campana-2026-11-16' }] }),
    cic(9000003, 'filtroppal', { fecha_sistema: '2025-11-30', sistema: 'AQUA ✓ NANO CTU-500' }),
    cic(9000004, 'prefiltro', { fecha_sistema: '2025-12-10', sistema: 'AQUA ✓ NANO CTU-500',
      gestiones_post: [{ id: 2, fecha: '2026-11-16T17:00:00+00:00', canal: 'llamada_auto', intento: 4, resultado: 'buzon', etapa: 1, accion: 'volver_a_llamar', accion_fecha: null, nota: null, call_id: null, grabacion_url: null, origen: 'campana', tanda: 'T1', video: false, celular: null, visita_fecha: null, lote: 'campana-2026-11-16' }],
      avisos_asesor: [{ id: 1, fecha: '2026-11-14T15:00:00+00:00', asesor: OLGA, etapa: 1, tanda: 'T1', nota: 'quedó en llamarlo', revisar_el: '2026-11-19', estado: 'pendiente', revisado_el: null, revision_nota: null, gestion_id: null, origen: 'portal' }] }),
    cic(9000004, 'filtroppal', { fecha_sistema: '2025-12-10', sistema: 'AQUA ✓ NANO CTU-500' }),
    cic(9000005, 'aire', { fecha_sistema: '2025-06-01', sistema: 'PURIFICADOR DE AIRE RENA AIR' }),
    cic(9000006, 'prefiltro', { fecha_repuesto: '2025-10-29' }),
    cic(9000009, 'prefiltro', { fecha_sistema: '2026-06-01', sistema: 'AQUA ✓ NANO CTU-500' }), cic(9000009, 'filtroppal', { fecha_sistema: '2026-06-01', sistema: 'AQUA ✓ NANO CTU-500' })
  ];
  const unos = [{ n: 9000009, tipo: 'bienvenida', vence: '2026-06-01', estado: 'hecho', hecho_el: '2026-06-02' }, { n: 9000007, tipo: 'mes1', vence: '2026-02-06', estado: 'omitido' }];
  const post = {}; post[C(7)] = { cliente_id: C(7), asesor_seguimiento: NELSON, excluido_hasta: null, excluido_motivo: null, referencia: null, nota: null, en_mano: {}, actualizado: '2026-11-18T00:00:00+00:00' };
  return { pedidos, ciclos, unos, post };
}
// Para la pestaña Análisis: 14 pedidos en 4 períodos, con las tres formas de compra y fechas escogidas.
// Entregados: 4 autocompras (S/ 6,376.90), 1 compra propia a precio regular (S/ 600) y 6 ventas a terceros (S/ 16,000).
function datosAnalisis() {
  const RITA = 'Rita Solo Compra', A = (n) => 'a0000000-0000-4000-8000-0000000000' + String(n).padStart(2, '0');
  const P21 = '2026-PB21 (01-14 oct)', P22 = '2026-PB22 (15-28 oct)', P23 = '2026-PB23 (29 oct-11 nov)';
  const f = (n, fec, per, vend, cli, total, o) => pedido(9100000 + n, Object.assign({ fecha_ordenado: fec, periodo: per, vendedor: vend, cliente: cli, cliente_id: A(n), celular: '9591000' + String(n).padStart(2, '0'), total, productos: 'SET RENA LITE 04 UNIDADES (x1 S/' + total + ')', estatus: 'ENTREGADA' }, o));
  const pedidos = [
    f(1, '01/10/2026', P21, MIRIAM, 'Cliente Uno Tercero', 1000),                                 // jueves, día 1
    f(2, '14/10/2026', P21, MIRIAM, 'Cliente Dos Tercero', 2000),                                 // miércoles de cierre
    f(3, '14/10/2026', P21, OLGA, OLGA, 850.5, { autocompra: true }),
    f(4, '14/10/2026', P21, OLGA, 'Cliente Rechazado', 500, { estatus: 'RECHAZADA' }),
    f(5, '21/10/2026', P22, MIRIAM, 'Cliente Tres Tercero', 3000),                                // miércoles, día 7
    f(6, '28/10/2026', P22, RITA, RITA, 1700.4, { autocompra: true }),
    f(7, '28/10/2026', P22, RITA, 'RITA  SOLO COMPRA', 600),                                      // ella misma, a precio regular
    f(8, '27/10/2026', P22, OLGA, 'Cliente Cuatro Tercero', 4000),                                // martes, día 13
    f(9, '11/11/2026', P23, MIRIAM, MIRIAM, 2550.75, { autocompra: true }),
    f(10, '11/11/2026', P23, OLGA, OLGA, 1275.25, { autocompra: true }),
    f(11, '11/11/2026', P23, NELSON, 'Cliente Cancelado', 900, { estatus: 'CANCELADO' }),
    f(12, '04/11/2026', P23, NELSON, 'Cliente Cinco Tercero', 5000),
    f(13, '28/10/2026', P23, NELSON, 'Cliente Seis Tercero', 1000),                               // se ordenó en el PB22 y comisionó en el PB23
    f(14, '20/08/2026', '2026-PB18 (20 ago-02 sep)', NELSON, 'Cliente Siete Rechazado', 2000, { estatus: 'RECHAZADA' })
  ];
  return { pedidos, ciclos: [], unos: [], post: {} };
}
const REGLAS = [
  { clave: 'gestiones', tipo_regla: 'ajuste', nombre: 'Gestiones de post venta', aplica_a: 'Ciclos de filtros y botella', cuando: 'Cada llamada, mensaje, video, visita o aviso al asesor', accion: 'Lo que llega al cliente o a su asesor cuenta como avisado 30 días.', orden: 6, activo: true },
  { clave: 'bienvenida', tipo_regla: 'una_vez', nombre: 'Al recibir su pedido', aplica_a: 'Todo pedido entregado', cuando: 'El día que recibe', accion: 'Video de lavado', dias: 0, orden: 10, activo: true },
  { clave: 'prefiltro', tipo_regla: 'ciclo', nombre: 'Cambio de pre-filtro', aplica_a: 'Clientes con Aqua Nano', cuando: 'Cada 12 meses', accion: 'Coordinar el cambio', intervalo_meses: 12, familia: 'agua', re_sistema: '(AQUA NANO)', re_excluir: '(PREFILTRO)', re_repuesto: '(PREFILTRO)', sistema_def: 'Aqua Nano', orden: 50, activo: true },
  { clave: 'filtroppal', tipo_regla: 'ciclo', nombre: 'Cambio del filtro principal', aplica_a: 'Clientes con Aqua Nano', cuando: 'Cada 48 meses', accion: 'Coordinar el cambio', intervalo_meses: 48, familia: 'agua', orden: 60, activo: true },
  { clave: 'aire', tipo_regla: 'ciclo', nombre: 'Cambio del filtro de aire', aplica_a: 'Clientes con purificador', cuando: 'Cada 18 meses', accion: 'Coordinar el cambio', intervalo_meses: 18, familia: 'aire', orden: 70, activo: true },
  { clave: 'botella', tipo_regla: 'ciclo', nombre: 'Renovar botella filtrante', aplica_a: 'Clientes con botella', cuando: 'Cada 36 meses', accion: 'Ofrecer renovar', intervalo_meses: 36, familia: 'botella', orden: 80, activo: true }
];
const ASESORES = [{ nombre: MIRIAM, celular: '958000001' }, { nombre: NELSON, celular: '958000003' }, { nombre: OLGA, celular: '958000002' }, { nombre: 'Sin Celular Asesor', celular: null }];

/* ---------------- Supabase falso ---------------- */
function crearBase(datos) {
  const db = { llamadas: [], directas: [], claves: [], idG: 100, idA: 100, idS: 1, idK: 1, real: false };
  if (process.env.DATOS && !datos) {       // foto de la base real: se usa tal cual y solo se recalcula el ciclo que se toca
    db.real = true;
    db.pedidos = JSON.parse(fs.readFileSync(path.join(process.env.DATOS, 'pedidos.json'), 'utf8'));
    const fAcc = path.join(process.env.DATOS, 'acciones.json'), acc = fs.existsSync(fAcc) ? JSON.parse(fs.readFileSync(fAcc, 'utf8')) : [];      // sin acciones.json solo se mira Análisis
    db.unosJson = acc.filter((a) => a.clase !== 'ciclo');
    db.ciclos = acc.filter((a) => a.clase === 'ciclo').map((a) => Object.assign(a, { seg: a.gestiones || [], _json: true }));
    db.post = {};
    db.ciclos.forEach((a) => { if (a.asesor_fijado || a.nota || a.referencia || a.excluido_hasta) db.post[a.cliente_id] = { cliente_id: a.cliente_id, asesor_seguimiento: a.asesor_fijado, excluido_hasta: a.excluido_hasta, excluido_motivo: a.excluido_motivo, referencia: a.referencia, nota: a.nota, en_mano: {}, actualizado: AHORA.toISOString() }; });
  } else {
    Object.assign(db, datos || datosDePrueba());
    db.unosJson = db.unos.map((u) => { const p = db.pedidos.find((x) => x.n_orden === u.n);
      return { clave: u.n + '::' + u.tipo, clase: 'uno', tipo: u.tipo, cliente_id: p.cliente_id, cliente: p.cliente, celular: p.celular, ciudad: p.ciudad, vendedor: p.vendedor, autocompra: false, n_orden: u.n, ordenes: [u.n], periodo: p.periodo,
        flags: {}, base: u.vence, vence: u.vence, dias: dias(HOY, u.vence), estado: u.estado, hecho_el: u.hecho_el || null, gestiones: [], vendedor_pedido: p.vendedor, compra_propia: false }; });
  }
  const ped = (n) => db.pedidos.find((p) => String(p.n_orden) === String(n));
  db.ped = ped;
  // lo mismo que calcula crm_acciones() para un ciclo
  db.recalc = function (a) {
    const p = ped(a.n_orden) || {}, x = db.post[a.cliente_id || p.cliente_id] || {};
    if (!a._json) Object.assign(a, { cliente_id: p.cliente_id, cliente: p.cliente, celular: p.celular, ciudad: p.ciudad, direccion: p.direccion, vendedor_pedido: p.vendedor_bo || p.vendedor, autocompra: false, compra_propia: false, ordenes: [a.n_orden],
      repuestos: a.fecha_repuesto ? 1 : 0, src: a.fecha_repuesto && (!a.fecha_sistema || a.fecha_repuesto >= a.fecha_sistema) ? 'repuesto' : 'sistema', base: mayor(a.fecha_sistema, a.fecha_repuesto), provincia: (String(p.ciudad || '').split(',')[1] || '').trim() || null });
    else { const pc = db.pedidos.filter((q) => q.cliente_id === a.cliente_id); if (pc.length) a.celular = (pc.find((q) => q.n_orden === a.n_orden) || pc[0]).celular; }
    a.clave = a.cliente_id + '::' + a.tipo;
    const seg = a.seg.filter((s) => !s.anulado), gp = a.gestiones_post.filter((g) => !g.anulado).sort((m, n) => (new Date(n.fecha) - new Date(m.fecha)) || (n.id - m.id)), av = a.avisos_asesor.filter((v) => !v.anulado).sort((m, n) => (new Date(n.fecha) - new Date(m.fecha)) || (n.id - m.id));
    const de = (modos) => seg.filter((s) => modos.includes(s.modo));
    a.ultimo_cambio = mayor(...de(['cambio', 'por_su_cuenta']).map((s) => s.fecha)); a.cambios = de(['cambio']).length;
    const ini = mayor(a.base, a.ultimo_cambio); a.inicio_etapa = ini; a.vence = masMeses(ini, a.intervalo); a.dias = dias(HOY, a.vence); a.etapa = Math.min(3, a.cambios + 1);
    const efectivo = (g) => ['pidio_visita', 'no_desea', 'contesto', 'colgo'].includes(g.resultado) || (['whatsapp', 'visita'].includes(g.canal) && g.resultado !== 'numero_errado');
    const avisoSeg = mayor(...de(['whatsapp', 'aviso', 'omitido']).map((s) => s.fecha));
    a.ultimo_aviso = mayor(avisoSeg, ...gp.filter(efectivo).map((g) => limaDia(g.fecha)), ...av.map((v) => limaDia(v.fecha)));
    const noaplica = mayor(...de(['noaplica']).map((s) => s.fecha)), enEtapa = (e) => limaDia(e.fecha) >= ini;
    const exh = x.excluido_hasta || null;
    a.estado = noaplica && noaplica >= ini ? 'cerrado' : exh && exh >= HOY ? 'excluido' : a.dias > 90 ? 'al_dia' : (a.ultimo_aviso && a.ultimo_aviso >= ini && a.ultimo_aviso > masDias(HOY, -30)) ? 'avisado' : a.vence < HOY ? 'vencido' : 'proximo';
    a.gestiones = seg.map((s) => ({ id: s.id, modo: s.modo, fecha: s.fecha, texto: s.texto || null, n_orden: a.n_orden }));
    a.gestiones_post_json = gp; a.intentos_etapa = gp.filter(enEtapa).length;
    a.gestionado_etapa = a.intentos_etapa + av.filter(enEtapa).length > 0 || !!(avisoSeg && avisoSeg >= ini);
    a.aviso_asesor = av.filter(enEtapa)[0] || null;
    a.aviso_por_revisar = av.some((v) => v.estado === 'pendiente' && v.revisar_el <= HOY && enEtapa(v));
    a.tanda = ([...gp, ...av].filter((e) => e.tanda && enEtapa(e)).sort((m, n) => new Date(n.fecha) - new Date(m.fecha))[0] || {}).tanda || null;
    const marca = (x.en_mano || {})[a.tipo], cambioEl = mayor(...de(['cambio', 'por_su_cuenta']).map((s) => s.creado));
    a.en_mano = !!(marca && marca.slice(0, 10) >= a.base && (!cambioEl || marca > cambioEl));
    a.nota = x.nota || null; a.referencia = x.referencia || null; a.excluido_hasta = exh; a.excluido_motivo = x.excluido_motivo || null;
    a.asesor_fijado = (x.asesor_seguimiento || '').trim() || null; a.vendedor = a.asesor_fijado || a.vendedor_pedido;
    a.celular_e164 = /^9\d{8}$/.test(String(a.celular || '').replace(/\D/g, '').slice(-9)) ? '+51' + String(a.celular).replace(/\D/g, '').slice(-9) : null;
    return a;
  };
  db.acciones = function () {
    db.ciclos.forEach(db.recalc);
    // número errado: la última gestión del cliente (de cualquier repuesto) y el número sigue siendo el suyo
    const porCli = {}; db.ciclos.forEach((a) => a.gestiones_post.filter((g) => !g.anulado).forEach((g) => { const u = porCli[a.cliente_id]; if (!u || new Date(g.fecha) > new Date(u.fecha) || (g.fecha === u.fecha && g.id > u.id)) porCli[a.cliente_id] = g; }));
    return db.unosJson.concat(db.ciclos.map((a) => { const u = porCli[a.cliente_id], cels = db.pedidos.filter((p) => p.cliente_id === a.cliente_id).map((p) => String(p.celular || '').replace(/\D/g, '').slice(-9));
      const j = Object.assign({}, a, { gestiones_post: a.gestiones_post_json, ultima_gestion: a.gestiones_post_json[0] || null, avisos_asesor: a.avisos_asesor.filter((v) => !v.anulado).sort((m, n) => new Date(n.fecha) - new Date(m.fecha)),
        numero_errado: !!(u && u.resultado === 'numero_errado' && (!u.celular || cels.includes(u.celular))) });
      delete j.seg; delete j.gestiones_post_json; delete j._json; return j; }));
  };
  const clave = (t) => String(t == null ? '' : t).normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '');
  const CANAL = { llamada_auto: 'llamada_auto', llamada_automatica: 'llamada_auto', llamada: 'llamada', whatsapp: 'whatsapp', mensaje: 'whatsapp', mensaje_directo: 'whatsapp', video: 'video', video_enviado: 'video', visita: 'visita', visita_coordinada: 'visita', aviso_asesor: 'aviso_asesor', aviso_al_asesor: 'aviso_asesor' };
  const RES = { 1: 'pidio_visita', pidio_visita: 'pidio_visita', 2: 'no_desea', no_desea: 'no_desea', contesto: 'contesto', contesto_sin_marcar: 'contesto', colgo: 'colgo', buzon: 'buzon', buzon_de_voz: 'buzon', no_contesta: 'no_contesta', numero_errado: 'numero_errado' };
  const ACC = { enviar_video: 'enviar_video', coordinar_visita: 'coordinar_visita', volver_a_llamar: 'volver_a_llamar', ninguna: 'ninguna' };
  const tanda = (t) => { const k = String(t || '').trim().toUpperCase(); if (!k) return null; const m = k.match(/^T?(\d{1,3})$/); if (!m) throw new Error('Tanda no válida (usa T1, T2…): ' + t); return 'T' + (+m[1]); };
  const ts = (t) => { const k = String(t || '').trim(); if (!k) return null; let m = k.match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})(?:[ T,]+(\d{1,2}):(\d{2}))?/);
    if (m) return new Date(m[3] + '-' + m[2].padStart(2, '0') + '-' + m[1].padStart(2, '0') + 'T' + (m[4] || '12').padStart(2, '0') + ':' + (m[5] || '00') + ':00-05:00').toISOString();
    if (/^\d{4}-\d{2}-\d{2}$/.test(k)) return new Date(k + 'T12:00:00-05:00').toISOString();
    const d = new Date(/(Z|[+-]\d{2}(:?\d{2})?)$/.test(k) ? k : k + '-05:00'); if (isNaN(d)) throw new Error('Fecha no válida: ' + t); return d.toISOString(); };
  const dia = (t) => { const k = String(t || '').trim(); if (/^\d{4}-\d{2}-\d{2}/.test(k)) return k.slice(0, 10); const m = k.match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})/); return m ? m[3] + '-' + m[2].padStart(2, '0') + '-' + m[1].padStart(2, '0') : null; };
  // la misma lógica de crm_gestiones_registrar_int
  db.registrar = function (filas, origen, canalDef, lote) {
    const r = { insertadas: 0, duplicadas: 0, avisos: 0, sin_cliente: [], errores: [], ids: [] };
    filas.forEach((f, i) => { try {
      let tipo = clave(f.tipo) || 'prefiltro'; if (!['prefiltro', 'filtroppal', 'aire', 'botella'].includes(tipo)) throw new Error('Repuesto no válido: ' + f.tipo);
      let canal = CANAL[clave(f.canal || canalDef)]; if (!canal) throw new Error('Tipo de gestión no válido: ' + f.canal);
      const video = canal === 'video'; if (video) canal = 'whatsapp';
      let cli = f.cliente_id || null; const n = String(f.n_orden || '').replace(/\D/g, '');
      if (!cli && n) cli = (ped(n) || {}).cliente_id || null;
      if (!cli && f.celular) { const c9 = String(f.celular).replace(/\D/g, '').slice(-9), ids = [...new Set(db.pedidos.filter((p) => String(p.celular || '').replace(/\D/g, '').slice(-9) === c9).map((p) => p.cliente_id))]; cli = ids.length === 1 ? ids[0] : null; }
      if (!cli || !db.pedidos.some((p) => p.cliente_id === cli)) { r.sin_cliente.push({ fila: i + 1, dato: f }); return; }
      const suyos = db.ciclos.filter((c) => c.cliente_id === cli);
      if (!String(f.tipo || '').trim() && !suyos.some((c) => c.tipo === 'prefiltro')) {      // sin repuesto escrito y sin pre-filtro: el que vence primero
        const u = suyos.filter((c) => c.estado !== 'cerrado').sort((m, n) => m.dias - n.dias)[0]; if (!u) throw new Error('El cliente no tiene repuestos en seguimiento'); tipo = u.tipo; }
      const a = suyos.find((c) => c.tipo === tipo); if (!a) throw new Error('El cliente no tiene ese repuesto en seguimiento');
      const fec = ts(f.fecha) || AHORA.toISOString(); if (new Date(fec) > new Date(AHORA.getTime() + 864e5)) throw new Error('La fecha no puede ser futura');
      const tan = tanda(f.tanda), etapa = +String(f.etapa || '').replace(/\D/g, '') || (a ? a.etapa : null);
      if (canal === 'aviso_asesor') {
        const ases = String(f.asesor || '').trim() || a.vendedor; if (!ases) throw new Error('Falta a quién se avisó');
        if (a.avisos_asesor.some((v) => !v.anulado && v.fecha === fec && v.asesor === ases)) { r.duplicadas++; return; }
        const id = ++db.idA; a.avisos_asesor.push({ id, fecha: fec, asesor: ases, etapa, tanda: tan, nota: f.nota || null, revisar_el: dia(f.revisar_el) || masDias(limaDia(fec), 5), estado: 'pendiente', revisado_el: null, revision_nota: null, gestion_id: null, origen });
        r.insertadas++; r.avisos++; r.ids.push({ fila: i + 1, id, que: 'aviso' }); return;
      }
      let res = RES[clave(f.resultado)];
      if (!res) { if (String(f.resultado || '').trim()) throw new Error('Resultado no válido: ' + f.resultado); res = canal === 'whatsapp' ? 'no_contesta' : canal === 'visita' ? 'pidio_visita' : null; if (!res) throw new Error('Falta el resultado de la llamada'); }
      const acc = String(f.accion || '').trim() ? ACC[clave(f.accion)] : null; if (String(f.accion || '').trim() && !acc) throw new Error('Acción siguiente no válida: ' + f.accion);
      const callId = String(f.call_id || '').trim() || null, intento = +String(f.intento || '').replace(/\D/g, '') || null;
      if ((callId && a.gestiones_post.some((g) => !g.anulado && g.call_id === callId)) || a.gestiones_post.some((g) => !g.anulado && g.canal === canal && g.resultado === res && g.fecha === fec && g.intento === intento)) { r.duplicadas++; return; }
      const id = ++db.idG; let cel = String(f.celular || '').replace(/\D/g, '').slice(-9); if (!/^9\d{8}$/.test(cel)) cel = String(a.celular || '').replace(/\D/g, '').slice(-9) || null;
      a.gestiones_post.push({ id, fecha: fec, canal, intento, resultado: res, etapa, accion: acc, accion_fecha: dia(f.accion_fecha), nota: String(f.nota || '').trim() || null, call_id: callId, grabacion_url: String(f.grabacion_url || '').trim() || null, origen, tanda: tan, video, celular: cel,
        visita_fecha: canal === 'visita' ? dia(f.visita_fecha) : null, lote: f.lote || lote || null });
      r.insertadas++; r.ids.push({ fila: i + 1, id, que: 'gestion' });
    } catch (e) { r.errores.push({ fila: i + 1, error: e.message }); } });
    return r;
  };
  const gestion = (id) => { for (const a of db.ciclos) { const g = a.gestiones_post.find((x) => x.id === id && !x.anulado); if (g) return { a, g }; } return null; };
  const aviso = (id) => { for (const a of db.ciclos) { const v = a.avisos_asesor.find((x) => x.id === id && !x.anulado); if (v) return { a, v }; } return null; };
  db.rpc = {
    crm_post_config: () => ({ hoy: HOY, admin: true, asesores: ASESORES }),
    traspaso_crear: () => '00000000-0000-4000-8000-0000000000aa',
    crm_gestion_registrar: (x) => { const r = db.registrar([x.p_fila], 'portal', 'llamada'); if (r.errores.length) throw new Error(r.errores[0].error); if (r.sin_cliente.length) throw new Error('No se encontró al cliente'); return r; },
    crm_gestiones_cargar: (x) => db.registrar(x.p_filas, 'campana', 'llamada_auto', x.p_lote),
    crm_gestion_editar: (x) => { const e = gestion(x.p_id); if (!e) throw new Error('La gestión ya no existe'); const d = x.p_datos, g = e.g;
      if ('resultado' in d) { const res = RES[clave(d.resultado)]; if (!res) throw new Error('Resultado no válido'); g.resultado = res; }
      if ('fecha' in d) g.fecha = ts(d.fecha); if ('intento' in d) g.intento = +d.intento || null; if ('etapa' in d) g.etapa = +d.etapa || null; if ('tanda' in d) g.tanda = tanda(d.tanda);
      if ('accion' in d) g.accion = ACC[clave(d.accion)] || null; if ('accion_fecha' in d) g.accion_fecha = dia(d.accion_fecha); if ('nota' in d) g.nota = String(d.nota || '').trim() || null;
      if ('call_id' in d) g.call_id = String(d.call_id || '').trim() || null; if ('grabacion_url' in d) g.grabacion_url = String(d.grabacion_url || '').trim() || null;
      return { id: g.id, cliente_id: e.a.cliente_id, tipo: e.a.tipo }; },
    crm_gestion_anular: (x) => { const e = x.p_que === 'aviso' ? aviso(x.p_id) : gestion(x.p_id); if (!e) throw new Error('La gestión ya no existe'); (e.g || e.v).anulado = true; return { id: x.p_id, anulado: true }; },
    crm_aviso_revisar: (x) => { const e = aviso(x.p_id); if (!e) throw new Error('El aviso ya no existe'); if (!['contactado', 'no_contactado', 'pendiente'].includes(x.p_estado)) throw new Error('Estado no válido');
      e.v.estado = x.p_estado; e.v.revisado_el = x.p_estado === 'pendiente' ? null : AHORA.toISOString(); return { id: e.v.id, estado: e.v.estado }; },
    crm_cliente_post_guardar: (x) => { const d = x.p_datos, id = x.p_cliente; if (!db.pedidos.some((p) => p.cliente_id === id)) throw new Error('El cliente no existe');
      const r = db.post[id] = db.post[id] || { cliente_id: id, asesor_seguimiento: null, excluido_hasta: null, excluido_motivo: null, referencia: null, nota: null, en_mano: {} };
      if ('asesor_seguimiento' in d) r.asesor_seguimiento = String(d.asesor_seguimiento || '').trim() || null; if ('referencia' in d) r.referencia = String(d.referencia || '').trim() || null; if ('nota' in d) r.nota = String(d.nota || '').trim() || null;
      if ('excluido_hasta' in d) { const h = dia(d.excluido_hasta); if (!h) { if (r.excluido_hasta && r.excluido_hasta >= HOY) r.excluido_hasta = masDias(HOY, -1); } else { if (h < HOY) throw new Error('La fecha de la exclusión ya pasó'); if (!String(d.excluido_motivo || '').trim()) throw new Error('Escribe el motivo de la exclusión'); r.excluido_hasta = h; r.excluido_motivo = String(d.excluido_motivo).trim(); } }
      if ('en_mano' in d) { if (d.en_mano.valor) r.en_mano[d.en_mano.tipo] = new Date(AHORA.getTime() + (++db.idS) * 1000).toISOString(); else delete r.en_mano[d.en_mano.tipo]; }
      r.actualizado = AHORA.toISOString(); return r; },
    crm_pedido_corregir_cliente: (x) => { const p = ped(x.p_n_orden); if (!p) throw new Error('La orden no existe'); if (!String(x.p_cliente || '').trim()) throw new Error('Falta el nombre del cliente');
      const cel = String(x.p_celular || '').replace(/\D/g, '').slice(-9); if (String(x.p_celular || '').trim() && !/^9\d{8}$/.test(cel)) throw new Error('El celular debe tener 9 dígitos y empezar en 9');
      p.cliente_bo = p.cliente_bo || p.cliente; if (cel) { p.celular_bo = p.celular_bo || p.celular; p.celular = cel; } if (String(x.p_direccion || '').trim()) { p.direccion_bo = p.direccion_bo || p.direccion; p.direccion = x.p_direccion.trim(); }
      if (clave(p.cliente) !== clave(x.p_cliente)) { const otro = db.pedidos.find((q) => q !== p && clave(q.cliente) === clave(x.p_cliente)); p.cliente_id = otro ? otro.cliente_id : 'c0000000-0000-4000-8000-0000000009' + String(++db.idK).padStart(2, '0'); }   // como el disparador: lo liga al cliente de ese nombre
      p.cliente = x.p_cliente.trim(); p.cliente_corregido = true; return { n_orden: p.n_orden, cliente: p.cliente, celular: p.celular, cliente_id: p.cliente_id }; },
    crm_bot_clave_crear: (x) => { db.claves.push({ id: ++db.idK, nombre: x.p_nombre || 'Bot post venta', activo: true, creado_en: AHORA.toISOString(), ultimo_uso: null }); return 'rwpv_' + 'a1b2c3'.repeat(8); },
    crm_bot_clave_anular: (x) => { const k = db.claves.find((c) => c.id === x.p_id); if (k) k.activo = false; return undefined; }
  };
  return db;
}
function jwt(datos) { const b = (o) => Buffer.from(JSON.stringify(o)).toString('base64url'); return b({ alg: 'HS256', typ: 'JWT' }) + '.' + b(datos) + '.firma'; }
function sesionFalsa() { const exp = Math.floor(AHORA.getTime() / 1000) + 3600, user = { id: '11111111-1111-4111-8111-111111111111', aud: 'authenticated', role: 'authenticated', email: CORREO, app_metadata: {}, user_metadata: {}, created_at: '2026-01-01T00:00:00Z' };
  return { access_token: jwt({ sub: user.id, email: CORREO, role: 'authenticated', exp }), token_type: 'bearer', expires_in: 3600, expires_at: exp, refresh_token: 'refresco', user }; }
async function atender(route, db) {
  const req = route.request(), u = new URL(req.url()), m = req.method();
  const json = (status, cuerpo) => route.fulfill({ status, headers: Object.assign({ 'content-type': 'application/json' }, CORS), body: cuerpo === undefined ? '' : JSON.stringify(cuerpo) });
  if (m === 'OPTIONS') return route.fulfill({ status: 204, headers: CORS, body: '' });
  if (u.pathname.startsWith('/auth/v1/token')) { const b = JSON.parse(req.postData() || '{}'); return b.password === 'clave-buena' ? json(200, sesionFalsa()) : json(400, { error: 'invalid_grant', error_description: 'Invalid login credentials', msg: 'Invalid login credentials', code: 400, error_code: 'invalid_credentials' }); }
  if (u.pathname.startsWith('/auth/v1/')) return json(200, {});
  const rango = (l) => { const o = +(u.searchParams.get('offset') || 0), n = +(u.searchParams.get('limit') || 1000); return l.slice(o, o + n); };
  const rp = u.pathname.match(/^\/rest\/v1\/rpc\/(\w+)$/);
  if (rp) { const args = JSON.parse(req.postData() || '{}'); db.llamadas.push({ fn: rp[1], args });
    if (rp[1] === 'crm_acciones') return json(200, rango(db.acciones()));
    const f = db.rpc[rp[1]]; if (!f) return json(404, { code: 'PGRST202', message: 'No existe la función ' + rp[1] });
    try { const r = f(args); return r === undefined ? route.fulfill({ status: 204, headers: CORS, body: '' }) : json(200, r); } catch (e) { return json(400, { code: 'P0001', message: e.message, details: null, hint: null }); } }
  const tb = u.pathname.match(/^\/rest\/v1\/(\w+)$/);
  if (tb && m === 'GET') {
    if (tb[1] === 'crm_pedidos') return json(200, rango(db.pedidos.slice().sort((a, b) => a.n_orden - b.n_orden)));
    if (tb[1] === 'crm_reglas') return json(200, REGLAS);
    if (tb[1] === 'crm_cliente_post') return json(200, Object.values(db.post));
    if (tb[1] === 'crm_bot_claves') return json(200, db.claves.slice().sort((a, b) => b.id - a.id));
    return json(200, []);
  }
  if (tb && tb[1] === 'crm_seguimiento' && m === 'POST') {      // lo único que Pedidos escribe directo (política por correo): el estado del ciclo
    const b = JSON.parse(req.postData() || '{}'), a = db.ciclos.find((c) => String(c.cliente_id) === String(b.cliente_id) && c.tipo === b.tipo);
    if (!a || !['cambio', 'noaplica', 'por_su_cuenta'].includes(b.modo)) return json(400, { code: '23514', message: 'new row violates check constraint' });
    db.llamadas.push({ fn: 'insert crm_seguimiento', args: b });
    a.seg.push({ id: ++db.idS + 1000, modo: b.modo, fecha: b.fecha_gestion.split('/').reverse().join('-'), creado: new Date(AHORA.getTime() + (++db.idS) * 1000).toISOString() }); return route.fulfill({ status: 201, headers: CORS, body: '' }); }
  if (tb && tb[1] === 'crm_seguimiento' && m === 'PATCH') { const id = +(u.searchParams.get('id') || '').replace('eq.', ''); db.ciclos.forEach((c) => c.seg.forEach((s) => { if (s.id === id) s.anulado = true; }));
    db.llamadas.push({ fn: 'update crm_seguimiento', args: { id } }); return route.fulfill({ status: 204, headers: CORS, body: '' }); }
  if (tb) { db.directas.push(m + ' ' + tb[1]); return json(403, { code: '42501', message: 'new row violates row-level security policy for table "' + tb[1] + '"' }); }
  return json(404, { message: 'no hay ' + u.pathname });
}

/* ---------------- la prueba ---------------- */
let bien = 0; const mal = [];
function ok(cond, que, detalle) { if (cond) { bien++; } else { mal.push(que + (detalle !== undefined ? '  → ' + JSON.stringify(detalle) : '')); console.log('  ✗ ' + que + (detalle !== undefined ? '  → ' + JSON.stringify(detalle) : '')); } }

async function main() {
  const servidor = http.createServer((req, res) => { const f = path.join(RAIZ, 'public', 'index.html'); res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' }); res.end(fs.readFileSync(f)); });
  await new Promise((r) => servidor.listen(0, '127.0.0.1', r));
  const URL0 = 'http://127.0.0.1:' + servidor.address().port + '/';
  const db = crearBase();
  const nav = await chromium.launch();
  const errores = [];
  async function abrir(vp, base) {
    const ctx = await nav.newContext({ viewport: vp, timezoneId: 'America/Lima', locale: 'es-PE', deviceScaleFactor: +process.env.ESCALA || 1 });
    await ctx.route(SB + '/**', (r) => atender(r, base || db));
    await ctx.route('https://cdn.jsdelivr.net/**', (r) => LIB_SB ? r.fulfill({ status: 200, contentType: 'application/javascript', body: LIB_SB }) : r.continue());
    await ctx.route('https://cdnjs.cloudflare.com/**', (r) => LIB_XLSX ? r.fulfill({ status: 200, contentType: 'application/javascript', body: LIB_XLSX }) : r.continue());
    await ctx.route(/renaware-bienvenida\.pages\.dev|wa\.me/, (r) => r.fulfill({ status: 200, contentType: 'text/html', body: '<p>fuera</p>' }));
    const page = await ctx.newPage();
    await page.clock.install({ time: AHORA });
    page.on('pageerror', (e) => errores.push('pageerror: ' + e.message));
    page.on('console', (m) => { if (m.type() === 'error' && !/Failed to load resource/.test(m.text())) errores.push('console: ' + m.text()); });
    return { ctx, page };
  }
  const { ctx, page } = await abrir({ width: 1280, height: 900 });
  const txt = (sel) => page.evaluate((s) => { const e = document.querySelector(s); return e ? e.textContent.replace(/\s+/g, ' ').trim() : null; }, sel);
  const cuenta = (sel) => page.evaluate((s) => document.querySelectorAll(s).length, sel);
  const toast = () => txt('#toast');
  const quieto = async () => { await page.waitForLoadState('networkidle').catch(() => {}); await esperar(120); };
  const ultima = (fn) => db.llamadas.filter((l) => l.fn === fn).pop();
  const veces = (fn) => db.llamadas.filter((l) => l.fn === fn).length;
  const foto = async (nombre, p) => { if (process.env.CAPTURAS) await (p || page).screenshot({ path: path.join(process.env.CAPTURAS, nombre + '.png'), fullPage: false }); };
  const filasAgua = () => page.evaluate(() => [...document.querySelectorAll('#filtrosBody tr.fila')].map((tr) => tr.querySelector('strong').textContent));
  const filaDe = (nombre, cuerpo) => page.locator('#' + (cuerpo || 'filtrosBody') + ' tr.fila', { hasText: nombre }).first();
  const kpi = async () => ({ tanda: await txt('#f_tanda'), venc: await txt('#f_venc'), prox: await txt('#f_prox'), avis: await txt('#f_avis'), seg: await txt('#f_seg'), agua: await txt('#f_agua') });

  /* ---- 1. ingreso ---- */
  console.log('1. Ingreso');
  await page.goto(URL0); await quieto();
  ok(await page.isVisible('#authGate'), 'sin sesión pide ingresar');
  await page.fill('#authEmail', CORREO); await page.fill('#authPass', 'mala'); await page.click('#authGate button'); await quieto();
  ok(/Invalid login/.test(await txt('#authMsg') || ''), 'con clave mala no entra', await txt('#authMsg'));
  await page.fill('#authPass', 'clave-buena'); await page.click('#authGate button');
  await page.waitForFunction(() => document.getElementById('authGate').style.display === 'none' && document.querySelectorAll('#tableBody tr.fila').length > 0, null, { timeout: 15000 });
  ok((await txt('#whoami')) === CORREO, 'entra y muestra el correo');
  ok(await cuenta('#tableBody tr.fila') === db.pedidos.length, 'lista todos los pedidos', await cuenta('#tableBody tr.fila'));
  ok(veces('crm_post_config') === 1 && veces('crm_acciones') >= 1, 'lee la configuración de post venta y las acciones');

  if (db.real) { await conDatosReales(); return terminar(); }

  /* ---- 2. buscador y pedido ---- */
  console.log('2. Buscador');
  await page.fill('#globalSearch', 'nunez'); await esperar(80);
  ok(/Carla Núñez Paz/.test(await txt('#globalResults') || ''), 'el buscador encuentra sin tildes');
  await page.click('#globalResults button.ped'); await esperar(80);
  ok(/Pedido 9000003/.test(await txt('#detailTitle') || '') && await page.isVisible('#overlay.active'), 'abre el pedido desde el buscador');
  await page.keyboard.press('Escape');

  /* ---- 3. pestaña Filtros: tarjetas y tanda del mes ---- */
  console.log('3. Filtros y tanda del mes');
  await page.click('.tab[data-tab="tab-filtros"]'); await esperar(80);
  ok(JSON.stringify(await kpi()) === JSON.stringify({ tanda: '4', venc: '2', prox: '2', avis: '2', seg: '1', agua: '6' }), 'tarjetas de la pestaña Filtros', await kpi());
  ok(await cuenta('#filtrosBody tr.fila') === 6 && await page.isVisible('#aireWrap') && await page.isVisible('#botellaWrap'), 'sin filtros se ven los 6 de agua, el de aire y la botella');
  await page.click('.card:has(#f_tanda)'); await esperar(80);
  ok(await page.inputValue('#filtroEstado') === 'tanda', 'la tarjeta «Tanda del mes» pone el filtro');
  ok(JSON.stringify(await filasAgua()) === JSON.stringify(['Comodín Pérez Pérez', 'Bruno Díaz Ríos', 'Ana Torres Vega']), 'tanda del mes: vencen en 30 días y sin gestión, primero lo más vencido', await filasAgua());
  ok(await cuenta('#aireBody tr.fila') === 1 && !(await page.isVisible('#botellaWrap')), 'tanda del mes: entra el purificador y no la botella al día');
  ok(/celular inválido/.test(await filaDe('Bruno Díaz').textContent()), 'marca el celular que no tiene 9 dígitos');
  ok(/Sin gestión/.test(await filaDe('Ana Torres').textContent()), 'quien no tiene gestión lo dice');
  await page.selectOption('#filtroEstado', 'v30'); await esperar(60);
  ok(await cuenta('#filtrosBody tr.fila') === 5, '«Vence ≤ hoy + 30 días» incluye también a los ya gestionados', await filasAgua());
  await page.selectOption('#filtroEstado', ''); await page.selectOption('#filtroGestion', 'con'); await esperar(60);
  ok(JSON.stringify((await filasAgua()).sort()) === JSON.stringify(['Carla Núñez Paz', 'Darío Peña León']), 'filtro «ya gestionados en la etapa»', await filasAgua());
  const carla = await filaDe('Carla Núñez').textContent();
  ok(/T1/.test(carla) && /ya gestionado/.test(carla) && /Coordinar visita/.test(carla) && /Pidió visita/.test(carla), 'la fila muestra tanda, «ya gestionado», la última gestión y lo que sigue', carla.replace(/\s+/g, ' '));
  ok(JSON.stringify(await page.evaluate(() => [...document.querySelectorAll('#filtroTanda option')].map((o) => o.value))) === JSON.stringify(['', 'T1', 'sin']), 'el filtro de tandas ofrece las que existen');
  await page.selectOption('#filtroGestion', ''); await page.selectOption('#filtroTanda', 'sin'); await esperar(60);
  ok(await cuenta('#filtrosBody tr.fila') === 3, 'filtro «sin tanda»: de los que ya tocan, los que no entraron en ninguna', await filasAgua());
  await page.selectOption('#filtroTanda', ''); await page.selectOption('#filtroGestion', 'sin'); await esperar(60);
  ok(JSON.stringify((await filasAgua()).sort()) === JSON.stringify(['Ana Torres Vega', 'Bruno Díaz Ríos', 'Comodín Pérez Pérez']), 'filtro «sin gestión»: no cuenta a los que están al día', await filasAgua());
  await page.selectOption('#filtroGestion', '');
  await page.selectOption('#filtroTanda', ''); await page.selectOption('#filtroAsesor', 'Nestor Lider Oficina'); await esperar(60);
  const fabio = await filaDe('Fabio Rojas').textContent();
  ok(await cuenta('#filtrosBody tr.fila') === 1 && /Nestor Lider Oficina/.test(fabio) && /vendió Marta Salas Quiroz/.test(fabio), 'asesor de seguimiento distinto del vendedor: se ven los dos y se filtra por el de seguimiento', fabio.replace(/\s+/g, ' '));
  await page.click('button[onclick="limpiarFiltros()"]'); await esperar(60);
  await page.fill('#filtroSearch', '959000004'); await esperar(60);
  ok(JSON.stringify(await filasAgua()) === JSON.stringify(['Darío Peña León']), 'busca también por celular');
  await page.click('button[onclick="limpiarFiltros()"]'); await esperar(60);

  /* ---- 4. registrar una gestión desde la pestaña Filtros ---- */
  console.log('4. Registrar gestión');
  await page.selectOption('#filtroEstado', 'tanda'); await esperar(60);
  await filaDe('Ana Torres').locator('.mini-btn.reg').click(); await esperar(80);
  ok(await page.isVisible('#gestOverlay.active') && !(await page.isVisible('#fichaOverlay.active')), 'el botón 📝 abre el registro sin abrir la ficha');
  ok(/Registrar gestión — Ana Torres Vega/.test(await txt('#gestTitle')), 'título con el cliente', await txt('#gestTitle'));
  ok(await page.evaluate(() => document.querySelector('#gestBody .seg button.on').dataset.canal) === 'llamada', 'por defecto, llamada');
  ok(await page.inputValue('#gestBody [data-g="etapa"]') === '1' && await page.inputValue('#gestBody [data-g="tanda"]') === 'T1', 'propone la etapa del ciclo y la última tanda');
  ok(await page.inputValue('#gestBody [data-g="fecha"]') === '2026-11-20T10:00', 'fecha y hora de ahora', await page.inputValue('#gestBody [data-g="fecha"]'));
  ok(await cuenta('#gestBody #g_rep option') === 3, 'deja elegir el repuesto del cliente (pre-filtro, principal, botella)');
  await page.click('#gestGuardar'); await esperar(60);
  ok(/Elige el resultado/.test(await toast()) && !ultima('crm_gestion_registrar'), 'una llamada sin resultado no se guarda', await toast());
  ok(JSON.stringify(await page.evaluate(() => [...document.querySelectorAll('#gestBody [data-g="resultado"] option')].map((o) => o.value).filter(Boolean))) === JSON.stringify(['pidio_visita', 'no_desea', 'contesto', 'colgo', 'buzon', 'no_contesta', 'numero_errado']), 'resultados fijos de la llamada');
  await page.selectOption('#gestBody [data-g="resultado"]', 'buzon'); await esperar(40);
  ok(await page.inputValue('#gestBody [data-g="accion"]') === 'volver_a_llamar', 'buzón de voz propone «volver a llamar»');
  await page.selectOption('#gestBody [data-g="intento"]', '2'); await page.fill('#gestBody [data-g="tanda"]', 'tanda9'); await page.click('#gestGuardar'); await esperar(60);
  ok(/T1, T2/.test(await toast()), 'la tanda mal escrita se avisa', await toast());
  await page.fill('#gestBody [data-g="tanda"]', 't2'); await page.fill('#gestBody [data-g="call_id"]', 'CA777'); await page.fill('#gestBody [data-g="grabacion_url"]', 'https://grabaciones.test/ca777.mp3');
  await page.fill('#gestBody [data-g="accion_fecha"]', '2026-11-22'); await page.fill('#gestBody [data-g="nota"]', 'no contesta de día');
  await foto('gestion-escritorio');
  await page.click('#gestGuardar'); await quieto();
  let f = (ultima('crm_gestion_registrar') || { args: {} }).args.p_fila || {};
  ok(f.cliente_id === C(1) && f.tipo === 'prefiltro' && f.canal === 'llamada' && f.resultado === 'buzon' && String(f.intento) === '2' && f.tanda === 't2' && String(f.etapa) === '1' && f.accion === 'volver_a_llamar' && f.accion_fecha === '2026-11-22' && f.call_id === 'CA777' && f.celular === '959000001' && f.n_orden === 9000001 && f.nota === 'no contesta de día', 'la gestión viaja completa a crm_gestion_registrar', f);
  ok(f.fecha === '2026-11-20T15:00:00.000Z', 'la fecha viaja con su zona (10:00 de Lima)', f.fecha);
  ok(/Gestión anotada/.test(await toast()) && !(await page.isVisible('#gestOverlay.active')), 'avisa y cierra');
  ok(JSON.stringify(await filasAgua()) === JSON.stringify(['Comodín Pérez Pérez', 'Bruno Díaz Ríos']) && (await kpi()).tanda === '3', 'quien ya tiene gestión sale de la tanda del mes', await filasAgua());
  await page.selectOption('#filtroEstado', ''); await esperar(60);
  const ana = await filaDe('Ana Torres').textContent();
  ok(/T2/.test(ana) && /ya gestionado/.test(ana) && /Buzón de voz/.test(ana) && /Volver a llamar · 22 nov/.test(ana) && /Próximo/.test(ana), 'la fila queda con T2, ya gestionado, lo que sigue y sigue «próximo» (el buzón no cuenta como aviso)', ana.replace(/\s+/g, ' '));

  /* ---- 5. aviso al asesor y su seguimiento a los 5 días ---- */
  console.log('5. Aviso al asesor');
  await filaDe('Carla Núñez').locator('.mini-btn.reg').click(); await esperar(80);
  ok(await page.evaluate(() => document.querySelector('#gestBody .seg button.on').dataset.canal) === 'aviso_asesor', 'si lo que sigue es coordinar la visita, propone el aviso al asesor');
  ok(await page.inputValue('#gestBody [data-g="asesor"]') === MIRIAM && await page.inputValue('#gestBody [data-g="revisar_el"]') === '2026-11-25', 'a quién: su asesor de seguimiento; revisar a los 5 días');
  const wa = await page.getAttribute('#waAsesor a', 'href');
  ok(wa && wa.startsWith('https://wa.me/51958000001?text=') && /Carla Núñez Paz/.test(decodeURIComponent(wa)) && /Pidió que lo visiten/.test(decodeURIComponent(wa)) && /pre-filtro/.test(decodeURIComponent(wa)), 'deja listo el WhatsApp al asesor con el cliente y el motivo', wa && decodeURIComponent(wa).slice(0, 200));
  await page.fill('#gestBody [data-g="asesor"]', 'Sin Celular Asesor'); await esperar(40);
  ok(/No tengo el celular/.test(await txt('#waAsesor')), 'si no hay celular del asesor, lo dice');
  await page.fill('#gestBody [data-g="asesor"]', MIRIAM); await page.fill('#gestBody [data-g="nota"]', 'pidió visita en la tarde');
  await page.click('#gestGuardar'); await quieto();
  f = ultima('crm_gestion_registrar').args.p_fila;
  ok(f.canal === 'aviso_asesor' && f.asesor === MIRIAM && f.revisar_el === '2026-11-25' && f.cliente_id === C(3) && !('resultado' in f), 'el aviso viaja con a quién y cuándo revisar', f);
  ok(/Aviso anotado/.test(await toast()), 'avisa que se revisa en 5 días', await toast());
  ok(/Revisar si Marta lo contactó · 25 nov/.test(await filaDe('Carla Núñez').textContent()) && !/Coordinar visita/.test(await filaDe('Carla Núñez').textContent()), 'la fila pasa de «coordinar visita» a «revisar si lo contactó»', (await filaDe('Carla Núñez').textContent()).replace(/\s+/g, ' '));
  let av = await txt('#avisosWrap');
  ok(/Darío Peña León/.test(av) && /tocaba revisar el 19\/11\/2026/.test(av) && /1 en espera/.test(av), 'el aviso de hace 5 días aparece por revisar y el de hoy queda en espera', av);
  await page.locator('#avisosWrap .av-row', { hasText: 'Darío' }).first().locator('button', { hasText: 'Sí lo contactó' }).click(); await quieto();
  ok(ultima('crm_aviso_revisar').args.p_id === 1 && ultima('crm_aviso_revisar').args.p_estado === 'contactado', 'marcar «sí lo contactó» va a crm_aviso_revisar');
  av = await txt('#avisosWrap');
  ok(/Ninguno por revisar hoy/.test(av) && (await kpi()).seg === '0', 'sale de los pendientes por revisar', av);

  // nota fija del cliente, escrita desde la pestaña Filtros (sin registrar una gestión)
  await filaDe('Darío Peña').locator('.mini-btn.reg').click(); await esperar(80);
  await page.fill('#gestBody [data-g="nota_cliente"]', 'Trabaja de noche: llamar después de las 3'); await page.click('#gestBody button:has-text("Guardar solo la nota")'); await quieto();
  ok(ultima('crm_cliente_post_guardar').args.p_cliente === C(4) && JSON.stringify(ultima('crm_cliente_post_guardar').args.p_datos) === JSON.stringify({ nota: 'Trabaja de noche: llamar después de las 3' }) && veces('crm_gestion_registrar') === 2, 'desde Filtros se guarda una nota del cliente sin registrar gestión');
  ok(/📝 Trabaja de noche/.test(await filaDe('Darío Peña').textContent()) && !(await page.isVisible('#gestOverlay.active')), 'la nota se ve en la fila');

  /* ---- 6. ficha: datos de post venta ---- */
  console.log('6. Ficha y datos de post venta');
  await filaDe('Bruno Díaz').click(); await esperar(80);
  ok(await page.isVisible('#fichaOverlay.active') && /no es un celular válido/.test(await txt('#fichaBody')), 'la ficha marca el celular inválido');
  await page.click('#fichaBody button:has-text("Editar datos de post venta")'); await esperar(60);
  const antes = veces('crm_cliente_post_guardar');
  await page.fill('#p_asesor', NELSON); await page.fill('#p_ref', 'portón verde'); await page.fill('#p_nota', 'llamar en la tarde'); await page.fill('#p_exh', '2026-12-20');
  await page.click('#fichaBody .form-post .mini-btn.done'); await esperar(60);
  ok(/motivo/.test(await toast()) && veces('crm_cliente_post_guardar') === antes, 'excluir sin motivo no se guarda', await toast());
  await page.fill('#p_exm', 'de viaje'); await page.fill('#p_cel', '95900000'); await page.click('#fichaBody .form-post .mini-btn.done'); await esperar(60);
  ok(/9 dígitos/.test(await toast()) && veces('crm_cliente_post_guardar') === antes, 'un celular que no tiene 9 dígitos empezando en 9 no se guarda', await toast());
  await page.fill('#p_cel', '959 000 002'); await page.click('#fichaBody .form-post .mini-btn.done'); await quieto();
  let d = ultima('crm_cliente_post_guardar').args;
  ok(d.p_cliente === C(2) && JSON.stringify(d.p_datos) === JSON.stringify({ asesor_seguimiento: NELSON, referencia: 'portón verde', nota: 'llamar en la tarde', excluido_hasta: '2026-12-20', excluido_motivo: 'de viaje' }), 'guarda asesor de seguimiento, referencia, nota y exclusión', d);
  d = ultima('crm_pedido_corregir_cliente').args;
  ok(veces('crm_pedido_corregir_cliente') === 1 && d.p_n_orden === 9000002 && d.p_celular === '959000002' && d.p_cliente === 'Bruno Díaz Ríos' && d.p_direccion === '', 'el celular se corrige en sus pedidos con la función que ya existía', d);
  let fi = await txt('#fichaBody');
  ok(/Excluido de post venta hasta el 20\/12\/2026: de viaje/.test(fi) && /Asesor de seguimiento\s*Nestor Lider Oficina · vendió Olga Paredes Ticona/.test(fi) && /portón verde/.test(fi) && /llamar en la tarde/.test(fi) && /959000002 · abrir chat/.test(fi) && !/no es un celular válido/.test(fi), 'la ficha muestra lo guardado', fi.slice(0, 400));
  ok(/Excluido hasta 20 dic/.test(await txt('#fichaBody [data-ciclo="prefiltro"]')), 'el ciclo queda «Excluido hasta…»', await txt('#fichaBody [data-ciclo="prefiltro"]'));
  ok((await kpi()).tanda === '2' && (await kpi()).venc === '1', 'el excluido sale de la tanda y de los vencidos', await kpi());
  await page.click('#fichaBody .aviso-ex button'); await quieto();
  ok(JSON.stringify(ultima('crm_cliente_post_guardar').args.p_datos) === JSON.stringify({ excluido_hasta: '' }) && !/Excluido de post venta/.test(await txt('#fichaBody')) && (await kpi()).tanda === '3', 'quitar la exclusión lo devuelve a la tanda');

  /* ---- 7. ficha: repuesto en mano, por su cuenta, cambio hecho ---- */
  console.log('7. Estado del ciclo');
  const pre = '#fichaBody [data-ciclo="prefiltro"]';
  await page.click(pre + ' button:has-text("Tiene el repuesto")'); await quieto();
  ok(JSON.stringify(ultima('crm_cliente_post_guardar').args.p_datos) === JSON.stringify({ en_mano: { tipo: 'prefiltro', valor: true } }) && /tiene el repuesto/.test(await txt(pre + ' .chip.mano')), 'marca «tiene el repuesto en mano»');
  ok(/en mano/.test(await filaDe('Bruno Díaz').textContent()), 'y se ve en la pestaña Filtros');
  await page.click(pre + ' button:has-text("Compró por su cuenta")'); await esperar(60);
  await page.fill('#fechaCambio', '2026-11-10'); await page.click(pre + ' button:has-text("Guardar")'); await quieto();
  d = ultima('insert crm_seguimiento').args;
  ok(d.modo === 'por_su_cuenta' && d.fecha_gestion === '10/11/2026' && d.tipo === 'prefiltro' && d.n_orden === 9000002 && d.cliente_id === C(2), '«compró por su cuenta» se anota con su fecha', d);
  let c = await txt(pre);
  ok(/Al día/.test(c) && /vence 10\/11\/2027/.test(c) && /1\.er cambio/.test(c) && !/tiene el repuesto/.test(c), 'reinicia el plazo, no gasta etapa y apaga «en mano»', c);
  ok(/compró el repuesto por su cuenta/.test(await txt('#fichaHist')), 'queda en el historial');
  await page.click('#fichaHist li:has-text("por su cuenta") button:has-text("deshacer")'); await quieto();
  ok(/Vencido/.test(await txt(pre)) && ultima('update crm_seguimiento'), 'se puede deshacer');
  await page.click(pre + ' button:has-text("Cambio hecho")'); await esperar(60);
  await page.click(pre + ' button:has-text("Guardar")'); await quieto();
  c = await txt(pre);
  ok(ultima('insert crm_seguimiento').args.modo === 'cambio' && /Al día/.test(c) && /vence 20\/11\/2027/.test(c) && /2\.º cambio/.test(c), '«cambio hecho» reinicia el ciclo y pasa a la segunda etapa', c);
  await page.keyboard.press('Escape'); await esperar(60);

  /* ---- 8. historial: editar, deshacer y número errado ---- */
  console.log('8. Historial');
  await filaDe('Ana Torres').click(); await esperar(80);
  let hi = await txt('#fichaHist');
  ok(/Llamada · 2\.º intento · Buzón de voz/.test(hi) && /20\/11\/2026 10:00/.test(hi) && /T2/.test(hi) && /sigue: volver a llamar el 22\/11\/2026/.test(hi) && /CallSid CA777/.test(hi) && /no contesta de día/.test(hi) && /grabación/.test(hi), 'el historial muestra la gestión con todo', hi);
  ok(await page.getAttribute('#fichaHist a', 'href') === 'https://grabaciones.test/ca777.mp3', 'enlace a la grabación');
  await page.click('#fichaHist button:has-text("editar")'); await esperar(80);
  ok(/Editar gestión/.test(await txt('#gestTitle')) && await page.inputValue('#gestBody [data-g="resultado"]') === 'buzon' && await page.inputValue('#gestBody [data-g="nota"]') === 'no contesta de día' && await page.isDisabled('#gestBody .seg button.on'), 'editar abre la gestión con sus datos y no deja cambiar el tipo');
  await page.selectOption('#gestBody [data-g="resultado"]', 'contesto'); await page.fill('#gestBody [data-g="nota"]', 'al final contestó'); await page.click('#gestGuardar'); await quieto();
  d = ultima('crm_gestion_editar').args;
  ok(d.p_id === 101 && d.p_datos.resultado === 'contesto' && d.p_datos.nota === 'al final contestó' && d.p_datos.accion === 'volver_a_llamar' && d.p_datos.call_id === 'CA777', 'la corrección va a crm_gestion_editar', d);
  ok(/Contestó sin marcar/.test(await txt('#fichaHist')) && /Avisado/.test(await txt(pre)), 'contestó: el ciclo pasa a «avisado»', await txt(pre));
  await page.click(pre + ' button:has-text("Registrar gestión")'); await esperar(80);
  await page.click('#gestBody .seg button[data-canal="llamada_auto"]'); await page.selectOption('#gestBody [data-g="resultado"]', 'numero_errado'); await page.click('#gestGuardar'); await quieto();
  ok(/número errado/.test(await txt('#fichaBody .detail-grid')) && /Número errado/.test(await txt('#fichaHist')), 'una llamada con «número errado» marca el número', await txt('#fichaBody .detail-grid'));
  await page.click('#fichaHist li:has-text("Número errado") button:has-text("deshacer")'); await quieto();
  d = ultima('crm_gestion_anular').args;
  ok(d.p_id === 102 && d.p_que === 'gestion' && !/número errado/.test(await txt('#fichaBody .detail-grid')), 'deshacer va a crm_gestion_anular y limpia la marca', d);
  // mensaje, video y visita
  await page.click(pre + ' button:has-text("Registrar gestión")'); await esperar(60);
  await page.click('#gestBody .seg button[data-canal="video"]'); await esperar(40);
  ok(await page.inputValue('#gestBody [data-g="resultado"]') === 'no_contesta' && await cuenta('#gestBody [data-g="intento"]') === 0 && await cuenta('#gestBody [data-g="call_id"]') === 0, 'video enviado: sin intento ni CallSid, con la respuesta del cliente');
  await page.click('#gestGuardar'); await quieto();
  f = ultima('crm_gestion_registrar').args.p_fila;
  ok(f.canal === 'video' && f.resultado === 'no_contesta' && !('intento' in f), 'video enviado viaja como tal', f);
  ok(/🎬 Video enviado · Sin respuesta aún/.test(await txt('#fichaHist')), 'y se lee «Video enviado · Sin respuesta aún»', await txt('#fichaHist'));
  await page.click(pre + ' button:has-text("Registrar gestión")'); await esperar(60);
  await page.click('#gestBody .seg button[data-canal="visita"]'); await esperar(40); await page.fill('#gestBody [data-g="visita_fecha"]', '2026-11-24'); await page.click('#gestGuardar'); await quieto();
  f = ultima('crm_gestion_registrar').args.p_fila;
  ok(f.canal === 'visita' && f.visita_fecha === '2026-11-24' && !('resultado' in f), 'visita coordinada viaja con su día', f);
  ok(/Visita coordinada · para el 24\/11\/2026/.test(await txt('#fichaHist')) && /Visita · 24 nov/.test(await txt(pre)), 'la visita queda como lo que sigue', await txt(pre));
  await foto('ficha-escritorio');
  await page.keyboard.press('Escape'); await esperar(60);

  /* ---- 9. corregir el cliente de un pedido (nombre comodín) ---- */
  console.log('9. Cliente comodín');
  await page.click('.tab[data-tab="tab-clientes"]'); await page.selectOption('#cliEstado', 'comodin'); await esperar(60);
  ok(await cuenta('#clientesBody tr.fila') === 1 && /Comodín Pérez Pérez/.test(await txt('#clientesBody')) && /¿comodín\?/.test(await txt('#clientesBody')), 'el filtro «posible comodín» encuentra al cliente con pedidos de 3 vendedores');
  await page.click('#clientesBody tr.fila'); await esperar(60);
  ok(/pedidos de 3 vendedores distintos/.test(await txt('#fichaBody')), 'la ficha explica por qué');
  await page.click('#fichaBody li.clic:has-text("9000007")'); await esperar(60);
  await page.click('#detailBody button:has-text("Corregir cliente")'); await esperar(60);
  await page.fill('#k_nombre', 'Gloria Real Cliente'); await page.fill('#k_cel', '959000077'); await page.click('#detailBody button:has-text("Guardar corrección")'); await quieto();
  d = ultima('crm_pedido_corregir_cliente').args;
  ok(d.p_n_orden === 9000007 && d.p_cliente === 'Gloria Real Cliente' && d.p_celular === '959000077' && d.p_direccion === '', 'la corrección viaja con lo que cambió', d);
  ok(/Pedido 9000007 — Gloria Real Cliente/.test(await txt('#detailTitle')) && /Corregido a mano\. En el back office figura: Comodín Pérez Pérez · 994000006/.test(await txt('#detailBody')), 'el pedido muestra al cliente real y lo que decía el back office', await txt('#detailTitle'));
  await page.keyboard.press('Escape'); await page.keyboard.press('Escape'); await esperar(60);
  ok(await cuenta('#clientesBody tr.fila') === 0, 'con dos vendedores ya no es «posible comodín»');
  await page.selectOption('#cliEstado', 'cel'); await esperar(60);
  ok(await cuenta('#clientesBody tr.fila') === 0, 'ya no quedan celulares inválidos (el de Bruno se corrigió)');
  await page.selectOption('#cliEstado', ''); await esperar(60);
  ok(/Gloria Real Cliente/.test(await txt('#clientesBody')), 'el cliente real aparece en la lista');

  /* ---- 10. Excel ---- */
  console.log('10. Excel');
  if (LIB_XLSX) {
    await page.evaluate(async () => { await cargarXLSX(); XLSX.writeFile = (wb, nombre) => { window.__wb = wb; window.__nombre = nombre; }; });
    await page.click('.tab[data-tab="tab-table"]'); await page.click('#tab-table button:has-text("Excel")'); await esperar(150);
    ok(await page.evaluate(() => XLSX.utils.sheet_to_json(window.__wb.Sheets.Pedidos).length) === 10, 'el Excel de Pedidos sigue saliendo');
    await page.click('.tab[data-tab="tab-clientes"]');
    await page.click('#tab-clientes button:has-text("Excel")'); await esperar(150);
    let x = await page.evaluate(() => { const ws = window.__wb.Sheets.Clientes, f = XLSX.utils.sheet_to_json(ws, { raw: true }); const col = Object.keys(f[0]).indexOf('Última compra'); return { cab: Object.keys(f[0]), bruno: f.find((r) => r.Cliente === 'Bruno Díaz Ríos'), celda: ws[XLSX.utils.encode_cell({ r: 1, c: col })] }; });
    ok(['Dirección', 'Distrito', 'Provincia', 'Departamento', 'Referencia', 'Celular +51', 'Vendedor', 'Asesor de seguimiento', 'Nota'].every((k) => x.cab.includes(k)), 'Excel de Clientes: dirección completa, provincia, departamento y referencia', x.cab);
    ok(x.bruno && x.bruno['Dirección'] === 'Calle Lima 506' && x.bruno.Distrito === 'Yanahuara' && x.bruno.Provincia === 'Arequipa' && x.bruno.Departamento === 'Arequipa' && x.bruno.Referencia === 'portón verde' && x.bruno['Celular +51'] === '+51959000002' && x.bruno['Asesor de seguimiento'] === NELSON && x.bruno.Vendedor === OLGA, 'fila de Bruno con sus datos separados', x.bruno);
    ok(x.celda && x.celda.t === 'n' && x.celda.z === 'dd/mm/yyyy', 'las fechas salen como fecha de Excel, no como texto', x.celda);
    await page.click('.tab[data-tab="tab-filtros"]'); await page.click('#tab-filtros button:has-text("Excel")'); await esperar(150);
    x = await page.evaluate(() => { const wb = window.__wb, a = XLSX.utils.sheet_to_json(wb.Sheets['Agua por cliente'], { raw: true }), r = XLSX.utils.sheet_to_json(wb.Sheets['Por repuesto'], { raw: true });
      const ws = wb.Sheets['Agua por cliente'], col = Object.keys(a[0]).indexOf('Pre-filtro vence'); return { hojas: wb.SheetNames, cabA: Object.keys(a[0]), cabR: Object.keys(r[0]), carla: a.find((q) => q.Cliente === 'Carla Núñez Paz'), com: r.find((q) => q.Cliente === 'Comodín Pérez Pérez'), nA: a.length, nR: r.length, celda: ws[XLSX.utils.encode_cell({ r: 1, c: col })], nombre: window.__nombre }; });
    ok(JSON.stringify(x.hojas) === JSON.stringify(['Agua por cliente', 'Por repuesto']) && x.nA === 6 && x.nR === 13, 'Excel de Filtros: una hoja por cliente y otra por repuesto', [x.hojas, x.nA, x.nR]);
    ok(['Vendedor', 'Asesor de seguimiento', 'N° Orden', 'Celular +51', 'Pre-filtro etapa', 'Última gestión', 'Última gestión (fecha)', 'Fecha último repuesto (pre-filtro)', 'Fecha último repuesto (principal)'].every((k) => x.cabA.includes(k)), 'con vendedor, asesor de seguimiento, N° de orden, +51, etapa, última gestión y fecha del último repuesto', x.cabA);
    ok(x.carla && x.carla['Celular +51'] === '+51959000003' && x.carla['N° Orden'] === 9000003 && x.carla.Vendedor === MIRIAM && x.carla['Pre-filtro etapa'] === '1.er cambio' && /Aviso a Marta Salas Quiroz: por revisar/.test(x.carla['Última gestión']) && x.carla.Tanda === 'T2' && x.carla['Pre-filtro vence'] === 46356, 'fila de Carla (vence el 30/11/2026 como fecha)', x.carla);
    ok(x.celda && x.celda.t === 'n' && x.celda.z === 'dd/mm/yyyy' && x.celda.v === 46324, 'la fecha de vencimiento es una fecha de Excel con su formato (29/10/2026)', x.celda);
    ok(x.com && x.com['Fecha último repuesto'] === 45959 && x.com.Repuesto === 'Pre-filtro de agua' && x.com['Etapa del recambio'] === '1.er cambio', '«Fecha último repuesto» en su propia columna y como fecha (29/10/2025)', x.com);
    ok(/^renaware-filtros-2026-11-20\.xlsx$/.test(x.nombre), 'nombre del archivo', x.nombre);
  } else console.log('  (sin la librería xlsx no se prueba el Excel)');

  /* ---- 11. carga en lote y API ---- */
  console.log('11. Carga en lote');
  await page.click('.tab[data-tab="tab-filtros"]'); await page.click('#tab-filtros button:has-text("Cargar resultados")'); await quieto();
  ok(await page.isVisible('#loteOverlay.active') && /crm_bot_pendientes/.test(await txt('#loteBody')) && /Todavía no hay llaves/.test(await txt('#loteBody')), 'abre la carga en lote con la guía de la API');
  if (LIB_XLSX) {
    await page.click('#loteBody button:has-text("Descargar plantilla")'); await esperar(150);
    let x = await page.evaluate(() => { const r = XLSX.utils.sheet_to_json(window.__wb.Sheets.Resultados, { raw: true }); return { n: r.length, cab: Object.keys(r[0]), uno: r[0], hojas: window.__wb.SheetNames }; });
    ok(x.n === 2 && x.hojas.includes('Valores') && ['N° Orden', 'Celular', 'Repuesto', 'Gestión', 'Fecha', 'Intento', 'Resultado', 'CallSid', 'Tanda'].every((k) => x.cab.includes(k)) && x.uno['Tanda'] === 'T3' && x.uno['Gestión'] === 'Llamada automática', 'la plantilla trae la tanda del mes lista para llenar', x);
    const csv = 'N° Orden,Cliente,Gestión,Fecha,Intento,Resultado,CallSid,Nota,Columna rara\n9000005,Elsa,Llamada automática,19/11/2026 10:15,1,1,CA900,pidió visita,x\n9999999,Nadie,Llamada automática,19/11/2026 10:20,1,Buzón de voz,CA901,,\n9000006,Comodín,Llamada automática,,,,,,\n9000006,Comodín,Video enviado,19/11/2026 11:00,,,,le mandé el video,\n';
    await page.setInputFiles('#l_file', { name: 'tanda-2.csv', mimeType: 'text/csv', buffer: Buffer.from(csv, 'utf8') }); await esperar(200);
    let lo = await txt('#loteBody');
    ok(/tanda-2\.csv: 3 gestión\(es\) para cargar · 1 fila\(s\) sin resultado no se cargan/.test(lo) && /Columnas que no se usan: Columna rara/.test(lo) && await cuenta('#loteBody .prev tbody tr') === 3, 'lee el CSV, avisa de las filas sin resultado y de las columnas que no usa', lo.slice(0, 500));
    await page.fill('#l_tanda', 'T2'); await foto('lote-escritorio');
    const cabe = await page.evaluate(() => { const b = document.getElementById('loteBody'); return { cont: b.scrollWidth, caja: b.clientWidth }; });
    ok(cabe.cont <= cabe.caja + 1, 'la carga en lote no se sale de su ventana', cabe);
    await page.click('#l_subir'); await quieto();
    d = ultima('crm_gestiones_cargar').args;
    ok(d.p_filas.length === 3 && d.p_lote === 'tanda-2' && JSON.stringify(d.p_filas[0]) === JSON.stringify({ n_orden: '9000005', canal: 'Llamada automática', fecha: '19/11/2026 10:15', intento: '1', resultado: 'pidio_visita', call_id: 'CA900', nota: 'pidió visita', tanda: 'T2' }) && d.p_filas[2].canal === 'Video enviado' && !('resultado' in d.p_filas[2]), 'el lote viaja a crm_gestiones_cargar con cada fila normalizada', d.p_filas);
    lo = await txt('#loteBody');
    ok(/✓ 2 cargada\(s\)/.test(lo) && /1 con problema/.test(lo) && /no encontré al cliente/.test(lo) && /Nadie · 9999999/.test(lo), 'dice cuántas entraron y cuál fila no y por qué', lo.slice(0, 600));
    await page.setInputFiles('#l_file', { name: 'tanda-2.csv', mimeType: 'text/csv', buffer: Buffer.from(csv, 'utf8') }); await esperar(200); await page.click('#l_subir'); await quieto();
    ok(/✓ 0 cargada\(s\)/.test(await txt('#loteBody')) && /2 ya estaban/.test(await txt('#loteBody')), 'subir dos veces el mismo archivo no duplica', (await txt('#loteBody')).slice(0, 300));
    if (XLSX) {
      const wb = XLSX.utils.book_new(), ws = XLSX.utils.aoa_to_sheet([['Celular', 'Resultado', 'Fecha', 'Intento'], ['+51 959 000 004', 'No contesta', { t: 'n', v: 46345.6875, z: 'dd/mm/yyyy hh:mm' }, 3]]);
      XLSX.utils.book_append_sheet(wb, ws, 'Hoja1');
      await page.setInputFiles('#l_file', { name: 'bot.xlsx', mimeType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', buffer: XLSX.write(wb, { type: 'buffer', bookType: 'xlsx' }) }); await esperar(250);
      await page.click('#l_subir'); await quieto();
      d = ultima('crm_gestiones_cargar').args;
      ok(JSON.stringify(d.p_filas[0]) === JSON.stringify({ celular: '959000004', resultado: 'no_contesta', fecha: '19/11/2026 16:30', intento: '3', canal: 'llamada_auto' }), 'de un Excel lee el celular con +51 y la fecha como se ve en la hoja', d.p_filas[0]);
    }
    await page.fill('#l_clave_nombre', 'Bot de llamadas'); await page.click('#loteBody button:has-text("Crear llave")'); await quieto();
    ok(ultima('crm_bot_clave_crear').args.p_nombre === 'Bot de llamadas' && /^rwpv_/.test(await txt('#l_llave')) && /🔑 Bot de llamadas/.test(await txt('#loteBody')), 'crea la llave del bot y la muestra una sola vez');
    await page.click('#loteBody ul.lista button:has-text("anular")'); await esperar(60);
    ok(!ultima('crm_bot_clave_anular') && /¿Seguro\?/.test(await txt('#loteBody ul.lista')), 'anular pide confirmar');
    await page.click('#loteBody ul.lista button:has-text("¿Seguro?")'); await quieto();
    ok(ultima('crm_bot_clave_anular') && /🚫 Bot de llamadas/.test(await txt('#loteBody')) && /anulada/.test(await txt('#loteBody')), 'y entonces la anula');
  }
  await page.keyboard.press('Escape'); await esperar(60);
  ok(!(await page.isVisible('#loteOverlay.active')), 'Escape cierra la carga en lote');
  if (LIB_XLSX) {
    const elsa = await filaDe('Elsa Quispe', 'aireBody').textContent();
    ok(/Avisado/.test(elsa) && /T2/.test(elsa) && /Pidió visita/.test(elsa), 'lo cargado se ve en la pestaña: el purificador de Elsa quedó avisado en T2', elsa.replace(/\s+/g, ' '));
  }

  /* ---- 12. reglas y celular ---- */
  console.log('12. Reglas y celular');
  await page.click('.tab[data-tab="tab-reglas"]'); await esperar(60);
  ok(/Gestiones de post venta/.test(await txt('#reglasBody')) && /gestiones anotadas · \d+ avisos a asesores/.test(await txt('#reglasBody')), 'la regla de gestiones cuenta lo anotado', (await txt('#reglasBody')).slice(0, 200));
  const { ctx: ctxM, page: movil } = await abrir({ width: 390, height: 844 });
  await ctxM.addInitScript((s) => { localStorage.setItem('sb-kiexpdaaoegbtesqmaff-auth-token', JSON.stringify(s)); localStorage.setItem('rw_ped_tab', 'tab-filtros'); }, sesionFalsa());
  await movil.goto(URL0);
  await movil.waitForFunction(() => document.getElementById('authGate').style.display === 'none' && document.querySelectorAll('#filtrosBody tr.fila').length > 0, null, { timeout: 15000 });
  const ancho = () => movil.evaluate(() => ({ doc: document.documentElement.scrollWidth, vp: window.innerWidth }));
  let w = await ancho(); ok(w.doc <= w.vp + 1, 'celular: la pestaña Filtros no se desborda a lo ancho', w);
  await foto('filtros-celular', movil);
  await movil.locator('#filtrosBody tr.fila .mini-btn.reg').first().click(); await esperar(100);
  const caja = await movil.evaluate(() => { const r = document.querySelector('#gestOverlay .detail-panel').getBoundingClientRect(); return { izq: r.left, der: r.right, ancho: window.innerWidth, btn: !!document.getElementById('gestGuardar') }; });
  ok(caja.izq >= 0 && caja.der <= caja.ancho + 1 && caja.btn, 'celular: el registro de gestión entra en la pantalla', caja);
  await foto('gestion-celular', movil);
  await ctxM.close();

  /* ---- 13. Análisis: autocompras vs. terceros e ingreso de pedidos por día ---- */
  console.log('13. Análisis');
  {
    const dbA = crearBase(datosAnalisis());
    const listo = (p) => p.waitForFunction(() => document.getElementById('authGate').style.display === 'none' && document.querySelectorAll('#chart_dia .vz-hit').length > 0, null, { timeout: 15000 });
    const entrar = async (vp) => { const o = await abrir(vp, dbA);
      await o.ctx.addInitScript((s) => { localStorage.setItem('sb-kiexpdaaoegbtesqmaff-auth-token', JSON.stringify(s)); localStorage.setItem('rw_ped_tab', 'tab-analytics'); }, sesionFalsa());
      await o.page.goto(URL0); await listo(o.page); return o; };
    const { ctx: ctxA, page: pa } = await entrar({ width: 1280, height: 900 });
    const t = (sel) => pa.evaluate((s) => { const e = document.querySelector(s); return e ? e.textContent.replace(/\s+/g, ' ').trim() : null; }, sel);
    const n = (sel) => pa.evaluate((s) => document.querySelectorAll(s).length, sel);
    const lista = (sel) => pa.evaluate((s) => [...document.querySelectorAll(s)].map((e) => e.textContent.replace(/\s+/g, ' ').trim()), sel);
    const fichas = (id) => pa.evaluate((i) => [...document.querySelectorAll('#' + i + ' > div')].map((d) => [d.querySelector('.k').textContent.trim(), d.querySelector('.v').textContent.trim(), d.querySelector('.hint').textContent.replace(/\s+/g, ' ').trim()]), id);
    const tip = () => pa.evaluate(() => { const e = document.getElementById('vzTip'); return e && e.style.display === 'block' ? [...e.children].map((c) => [...c.children].length ? [...c.children].map((x) => x.textContent).filter(Boolean).join(' | ') : c.textContent) : null; });
    const igual = (a, b) => JSON.stringify(a) === JSON.stringify(b);
    const sobre = async (sel, p) => { const l = (p || pa).locator(sel); await l.scrollIntoViewIfNeeded(); await esperar(80); await l.hover(); };      // el tooltip se quita al deslizar: primero se trae a la vista
    const partida = () => pa.evaluate(() => [...document.querySelectorAll('#mix_seg i')].map((e) => getComputedStyle(e).flexGrow + ' ' + getComputedStyle(e).backgroundColor));
    const marcas = () => pa.evaluate(() => [...document.querySelectorAll('#chart_mix .vz-sc svg > path, #chart_mix .vz-sc svg > rect:not(.vz-hit)')].map((e) => { const b = e.getBBox(); return getComputedStyle(e).fill + ' ' + Math.round(b.height); }));
    const eje = (id) => lista('#' + id + ' .vz-wrap > svg text');
    const elegido = (id) => pa.evaluate((i) => [...document.querySelectorAll('#' + i + ' button')].filter((b) => b.classList.contains('on') && b.getAttribute('aria-pressed') === 'true').map((b) => b.dataset.v).join(','), id);
    const TER_M = ['Venta a terceros', '69.6%', 'S/16,000 · 6 pedidos (54.5% de los pedidos)'];
    const POR_PEDIDOS = [['Autocompra (precio de asesor)', '36.4%', '4 pedidos · S/6,377 (27.8% del monto)'], ['Compra propia a precio regular', '9.1%', '1 pedido · S/600 (2.6% del monto)'], ['Venta a terceros', '54.5%', '6 pedidos · S/16,000 (69.6% del monto)']];
    const POR_MONTO = [['Autocompra (precio de asesor)', '27.8%', 'S/6,377 · 4 pedidos (36.4% de los pedidos)'], ['Compra propia a precio regular', '2.6%', 'S/600 · 1 pedido (9.1% de los pedidos)'], TER_M];
    const DE_ELLAS = 'De las autocompras, el 91% es a precio de asesor y el 9% a precio regular; el 37% es de asesores que se compraron una sola vez y el 63% de recurrentes.';
    const NARANJA = 'rgb(244, 114, 48)', VERDE = 'rgb(0, 184, 148)', AZUL = 'rgb(37, 125, 224)', CLARO = 'rgb(254, 148, 101)', OSCURO = 'rgb(162, 65, 5)';
    const rellenos = () => pa.evaluate(() => [...document.querySelectorAll('#chart_mix .vz-sc svg > path, #chart_mix .vz-sc svg > rect:not(.vz-hit)')].map((e) => getComputedStyle(e).fill));
    const quienes = () => lista('#mix_lista li');

    const cal = await pa.evaluate(() => ['2025-05-15', '2025-12-24', '2025-12-25', '2026-10-28', '2026-10-29', '2026-11-11', '2026-12-24'].map((f) => { const i = pbIndice(parseDate(f)); return pbNombre(i) + ' ' + pbRango(i); }));
    ok(igual(cal, ['2025-PB11 15-28 may', '2025-PB26 11-24 dic', '2026-PB01 25 dic-7 ene', '2026-PB22 15-28 oct', '2026-PB23 29 oct-11 nov', '2026-PB23 29 oct-11 nov', '2027-PB01 24 dic-6 ene']), 'el calendario de períodos (14 días desde el 25/12/2025) da el período de cada fecha', cal);

    // resumen: solo entregados, por monto y con las autocompras separadas por precio mientras no se pida otra cosa
    ok((await t('#mix_sub')) === 'solo entregados: 11 pedidos · S/22,977', 'autocompras: cuenta solo los entregados (ni rechazados ni cancelados)', await t('#mix_sub'));
    let f = await fichas('mix_tiles');
    ok(igual(f, POR_MONTO) && (await elegido('mix_medida')) === 'monto' && (await elegido('mix_separa')) === 'precio', 'por defecto el porcentaje es del monto entregado; separa autocompra, compra propia a precio regular (aunque el nombre venga en mayúsculas) y venta a terceros', f);
    ok(igual(await partida(), ['6377 ' + NARANJA, '600 ' + VERDE, '16000 ' + AZUL]), 'la barra partida va en proporción al monto y con el color de cada forma de compra', await partida());
    ok(/Autocompra \(precio de asesor\) 27\.8% · Compra propia a precio regular 2\.6% · Venta a terceros 69\.6%/.test(await pa.getAttribute('#mix_seg', 'aria-label')), 'la barra partida se describe con texto');
    ok((await t('#mix_total')) === 'Autocompras totales: 30.4% del monto (S/6,977 en 5 pedidos). ' + DE_ELLAS, 'siempre dice el total de autocompras (las dos juntas) y cómo se reparten por precio y por repetición', await t('#mix_total'));
    ok((await t('#mix_ases')) === 'De 4 asesores con pedidos entregados, 3 vendieron a terceros y 1 solo compró para sí.', 'dice cuántos asesores vendieron a terceros y cuántos solo se compraron a sí mismos', await t('#mix_ases'));
    ok(igual(await lista('#mix_leg span'), ['Autocompra (precio de asesor)', 'Compra propia a precio regular', 'Venta a terceros']), 'el gráfico por período lleva leyenda');

    // evolución por período (el del reporte): % del monto
    ok(await n('#chart_mix .vz-hit') === 3 && igual(await lista('#chart_mix .vz-sc text:not(.rot)'), ['PB21', 'PB22', 'PB23', '2026']) && (await t('#mix_evo_sub')) === '· todos los períodos', 'evolución: una columna por período con entregados y el año debajo', await lista('#chart_mix .vz-sc text'));
    ok(igual(await eje('chart_mix'), ['0%', '25%', '50%', '75%', '100%']) && igual(await lista('#mix_vista button'), ['% del monto', 'Soles']) && (await elegido('mix_vista')) === 'pct', 'la evolución empieza en % del monto', await lista('#mix_vista button'));
    let m = await marcas();
    ok(igual(m, [NARANJA + ' 35', AZUL + ' 123', NARANJA + ' 29', VERDE + ' 8', AZUL + ' 118', NARANJA + ' 62', AZUL + ' 96']),
      'apila las autocompras abajo y terceros arriba en proporción al monto, con 2 px de aire entre tramos; el pedido que comisionó en el PB23 cuenta en el PB23', m);
    await sobre('#chart_mix .vz-hit >> nth=1');
    ok(igual(await tip(), ['2026-PB22 (15-28 oct)', 'Autocompra (precio de asesor) | S/1,700 · 18.3%', 'Compra propia a precio regular | S/600 · 6.4%', 'Venta a terceros | S/7,000 · 75.3%', '4 pedidos entregados · S/9,300']), 'al pasar por una columna sale el monto y el % de cada forma de compra', await tip());
    await pa.mouse.move(5, 5); ok((await tip()) === null, 'y se quita al salir');
    await pa.focus('#chart_mix .vz-hit >> nth=2');
    ok(((await tip()) || [])[0] === '2026-PB23 (29 oct-11 nov)' && /Autocompra \(precio de asesor\) S\/3,826 · 38\.9%/.test(await pa.getAttribute('#chart_mix .vz-hit >> nth=2', 'aria-label')), 'con el teclado sale lo mismo y la columna se describe con texto', await tip());
    await pa.evaluate(() => document.activeElement.blur());
    ok(!(await pa.isVisible('#mix_tabla')), 'la tabla del gráfico empieza oculta');
    await pa.click('#card_mix button:has-text("Ver tabla")');
    ok(await pa.isVisible('#mix_tabla') && igual(await lista('#mix_tabla tbody tr:first-child td'), ['2026-PB23 (29 oct-11 nov)', 'S/3,826', '38.9%', 'S/0', '0.0%', 'S/6,000', '61.1%', 'S/3,826', '38.9%', 'S/9,826', '4']) && await n('#mix_tabla tbody tr') === 3,
      '«Ver tabla» muestra los mismos números y el total de autocompras, del período más reciente al más antiguo', await lista('#mix_tabla tbody tr:first-child td'));
    await pa.locator('#card_mix').scrollIntoViewIfNeeded(); await foto('analisis-autocompras', pa);
    await pa.click('#mix_vista button[data-v="abs"]');
    ok(igual(await eje('chart_mix'), ['0', 'S/5K', 'S/10K']) && (await elegido('mix_vista')) === 'abs', '«Soles» pone el eje en soles', await eje('chart_mix'));

    // por pedidos: cambia el resumen, la barra y el gráfico a la vez
    await pa.click('#mix_medida button[data-v="n"]');
    f = await fichas('mix_tiles');
    ok(igual(f, POR_PEDIDOS) && (await elegido('mix_medida')) === 'n' && igual(await partida(), ['4 ' + NARANJA, '1 ' + VERDE, '6 ' + AZUL]), '«Por pedidos» pasa el resumen y la barra a cantidad de pedidos', f);
    ok(igual(await eje('chart_mix'), ['0', '1', '2', '3', '4']) && igual(await lista('#mix_vista button'), ['% de pedidos', 'Pedidos']) && /^Autocompras totales: 45\.5% de los pedidos \(S\/6,977 en 5 pedidos\)\. De las autocompras, el 80% es a precio de asesor y el 20% a precio regular; el 20% es de asesores que se compraron una sola vez y el 80% de recurrentes\.$/.test(await t('#mix_total')),
      'y el gráfico y el total de autocompras también', [await eje('chart_mix'), await t('#mix_total')]);
    ok(igual(await lista('#mix_tabla tbody tr:first-child td'), ['2026-PB23 (29 oct-11 nov)', '2', '50.0%', '0', '0.0%', '2', '50.0%', '2', '50.0%', 'S/9,826', '4']), 'y la tabla', await lista('#mix_tabla tbody tr:first-child td'));
    await pa.click('#mix_vista button[data-v="pct"]');
    m = await marcas();
    ok(igual(m, [NARANJA + ' 53', AZUL + ' 105', NARANJA + ' 40', VERDE + ' 38', AZUL + ' 78', NARANJA + ' 80', AZUL + ' 78']), 'en % de pedidos las columnas van en proporción a la cantidad', m);
    await sobre('#chart_mix .vz-hit >> nth=1');
    ok(igual(await tip(), ['2026-PB22 (15-28 oct)', 'Autocompra (precio de asesor) | 1 · 25.0%', 'Compra propia a precio regular | 1 · 25.0%', 'Venta a terceros | 2 · 50.0%', '4 pedidos entregados · S/9,300']), 'y el detalle sale en pedidos', await tip());
    await pa.mouse.move(5, 5);
    await pa.click('#mix_medida button[data-v="monto"]');

    // las autocompras juntas: precio de asesor + precio regular en un solo total
    await pa.click('#mix_separa button[data-v="juntas"]');
    f = await fichas('mix_tiles');
    ok(igual(f, [['Autocompras totales', '30.4%', 'S/6,977 · 5 pedidos (45.5% de los pedidos)'], TER_M]) && igual(await partida(), ['6977 ' + NARANJA, '16000 ' + AZUL]) && (await elegido('mix_separa')) === 'juntas',
      '«Juntas» une la autocompra a precio de asesor y la compra propia a precio regular en un solo total', f);
    ok((await t('#mix_total')) === DE_ELLAS && igual(await lista('#mix_leg span'), ['Autocompras totales', 'Venta a terceros']) && igual(await rellenos(), [NARANJA, AZUL, NARANJA, AZUL, NARANJA, AZUL])
      && igual(await lista('#mix_tabla thead th'), ['Período', 'Autocompras totales', '%', 'Venta a terceros', '%', 'Monto entregado', 'Pedidos entregados']), 'y la leyenda, las columnas y la tabla quedan en dos grupos', [await t('#mix_total'), await rellenos()]);

    // una sola vez o recurrentes: según cuántas autocompras entregadas tiene el asesor en todo el historial
    await pa.click('#mix_separa button[data-v="veces"]');
    f = await fichas('mix_tiles');
    ok(igual(f, [['Autocompras de una sola vez', '11.1%', 'S/2,551 · 1 pedido (9.1% de los pedidos)'], ['Autocompras recurrentes (2 o más)', '19.3%', 'S/4,426 · 4 pedidos (36.4% de los pedidos)'], TER_M]) && igual(await partida(), ['2551 ' + CLARO, '4426 ' + OSCURO, '16000 ' + AZUL]),
      '«Una vez o recurrentes» separa las autocompras del asesor que se compró una sola vez de las del que repite (la compra propia a precio regular también cuenta como vez)', f);
    ok(/^Autocompras totales: 30\.4% del monto/.test(await t('#mix_total')) && igual(await rellenos(), [OSCURO, AZUL, OSCURO, AZUL, CLARO, OSCURO, AZUL]), 'el total de autocompras y el de terceros no cambian al separar de otra forma, y la evolución usa los dos tonos de naranja', await rellenos());
    await sobre('#chart_mix .vz-hit >> nth=2');
    ok(igual(await tip(), ['2026-PB23 (29 oct-11 nov)', 'Autocompras de una sola vez | S/2,551 · 25.9%', 'Autocompras recurrentes (2 o más) | S/1,275 · 13.0%', 'Venta a terceros | S/6,000 · 61.1%', '4 pedidos entregados · S/9,826']), 'y el detalle del período sale con esa separación', await tip());
    await pa.mouse.move(5, 5);
    await pa.click('#mix_separa button[data-v="precio"]');

    // rango: últimos períodos o uno solo; lo que queda fuera se atenúa en la evolución
    ok(igual(await pa.evaluate(() => [...document.querySelectorAll('#mixRango option')].map((o) => o.value)), ['todo', 'u2', 'u6', 'u13', 'u26', 'p:2026-PB23 (29 oct-11 nov)', 'p:2026-PB22 (15-28 oct)', 'p:2026-PB21 (01-14 oct)']), 'el rango ofrece todo, los últimos períodos y cada período');
    await pa.selectOption('#mixRango', 'u2');
    f = await fichas('mix_tiles');
    ok((await t('#mix_sub')) === 'solo entregados: 8 pedidos · S/19,126' && igual(f, [['Autocompra (precio de asesor)', '28.9%', 'S/5,526 · 3 pedidos (37.5% de los pedidos)'], ['Compra propia a precio regular', '3.1%', 'S/600 · 1 pedido (12.5% de los pedidos)'], ['Venta a terceros', '68.0%', 'S/13,000 · 4 pedidos (50.0% de los pedidos)']]),
      '«Últimos 2 períodos» recalcula el resumen solo con esos períodos', [await t('#mix_sub'), f]);
    ok(await n('#chart_mix .vz-sc svg > [opacity]') === 2 && await n('#chart_mix .vz-hit') === 3 && (await t('#mix_evo_sub')) === '· lo atenuado queda fuera del rango elegido' && (await t('#mix_quien_sub')) === '· 3 asesores: 2 recurrentes y 1 de una sola vez',
      'la evolución sigue mostrando todos los períodos y atenúa el que quedó fuera', [await n('#chart_mix .vz-sc svg > [opacity]'), await t('#mix_quien_sub')]);
    await pa.selectOption('#mixRango', 'p:2026-PB22 (15-28 oct)');
    ok((await t('#mix_sub')) === 'solo entregados: 4 pedidos · S/9,300' && igual((await fichas('mix_tiles')).map((x) => x[1]), ['18.3%', '6.4%', '75.3%']) && await n('#chart_mix .vz-sc svg > [opacity]') === 4 && (await t('#mix_quien_sub')) === '· 1 asesor: 1 recurrente y 0 de una sola vez',
      'y se puede mirar un solo período', [await t('#mix_sub'), await t('#mix_quien_sub')]);
    await pa.selectOption('#mixRango', 'todo');

    // quiénes se autocompran: con nombre, cuántas veces, a qué precio, si además venden a terceros y cuándo fue la última
    const MARTA = 'Marta Salas Quiroz una sola vez 1 a precio de asesor · a terceros: 3 pedidos (S/6,000) · última: 11/11/2026 S/2,551 1 autocompra';
    const RITA_L = 'Rita Solo Compra recurrente: 2 en total 1 a precio de asesor y 1 a precio regular · a terceros: ninguno · última: 28/10/2026 S/2,300 2 autocompras';
    const OLGA_L = 'Olga Paredes Ticona recurrente: 2 en total 2 a precio de asesor · a terceros: 1 pedido (S/4,000) · última: 11/11/2026 S/2,126 2 autocompras';
    ok((await t('#mix_quien_sub')) === '· 3 asesores: 2 recurrentes y 1 de una sola vez' && igual(await quienes(), [MARTA, RITA_L, OLGA_L]), 'la lista de asesores que se autocompran sale con nombre y por monto', await quienes());
    await pa.selectOption('#mixQuien', 'rec');
    ok(igual((await quienes()).map((x) => x.split(' ')[0]), ['Rita', 'Olga']), 'se puede dejar solo a los recurrentes', await quienes());
    await pa.selectOption('#mixQuien', 'una');
    ok(igual(await quienes(), [MARTA]), 'o solo a los de una sola vez', await quienes());
    await pa.selectOption('#mixQuien', 'todos'); await pa.selectOption('#mixOrden', 'n');
    ok(igual((await quienes()).map((x) => x.split(' ')[0]), ['Rita', 'Olga', 'Marta']), 'y ordenar por número de autocompras', await quienes());
    await pa.selectOption('#mixOrden', 'fecha');
    ok(igual((await quienes()).map((x) => x.split(' ')[0]), ['Marta', 'Olga', 'Rita']), 'o por la más reciente', await quienes());
    await pa.click('#mix_medida button[data-v="n"]');
    ok(/última: 28\/10\/2026 2 autocompras S\/2,300$/.test((await quienes())[2]), 'por pedidos, la lista pone primero la cantidad', (await quienes())[2]);
    await pa.click('#mix_medida button[data-v="monto"]'); await pa.selectOption('#mixOrden', 'monto');
    await pa.click('#mix_lista li >> nth=0');
    ok(await pa.isVisible('#tab-table') && (await pa.inputValue('#searchInput')) === 'Marta Salas Quiroz' && (await pa.inputValue('#filterEstatus')) === 'ENTREGADA' && await n('#tableBody tr.fila') === 4, 'al tocar a un asesor se abren sus pedidos entregados en la pestaña Pedidos', await n('#tableBody tr.fila'));
    await pa.click('.tab[data-tab="tab-analytics"]'); await esperar(100);
    await pa.click('#mix_medida button[data-v="n"]');      // se deja «por pedidos»: más abajo se comprueba que se recuerda

    // por vendedor: barra partida y orden
    const vend = () => pa.evaluate(() => [...document.querySelectorAll('#chart_vendedor .bar-row')].map((r) => r.querySelector('.bar-label').textContent + ' ' + r.querySelectorAll('.tres i').length + ' ' + r.querySelector('.bar-val').textContent));
    ok(igual(await vend(), ['Marta Salas Quiroz 2 S/8,551 · 4', 'Olga Paredes Ticona 2 S/6,126 · 3', 'Nestor Lider Oficina 1 S/6,000 · 2', 'Rita Solo Compra 2 S/2,300 · 2']), 'ventas por vendedor: la barra se parte en las formas de compra', await vend());
    await pa.selectOption('#vendOrden', 'prop');
    ok(igual((await vend()).map((x) => x.split(' ')[0]), ['Marta', 'Rita', 'Olga', 'Nestor']), 'se puede ordenar por compras propias', await vend());
    await pa.selectOption('#vendOrden', 'ter');
    ok(igual((await vend()).map((x) => x.split(' ')[0]), ['Marta', 'Nestor', 'Olga', 'Rita']), 'y por ventas a terceros', await vend());
    await sobre('#chart_vendedor .bar-row >> nth=3');
    ok(igual(await tip(), ['Rita Solo Compra', 'Autocompra (precio de asesor) | 1 pedido · S/1,700', 'Compra propia a precio regular | 1 pedido · S/600', 'Venta a terceros | —', '2 pedidos entregados · S/2,300']), 'el detalle del vendedor sale al pasar por su fila', await tip());
    await pa.mouse.move(5, 5);

    // ingreso por día: por la fecha en que se ordenó; solo entregados mientras no se pida otra cosa
    f = await fichas('dia_tiles');
    ok(igual(f, [['Pedidos entregados', '11', 'S/22,977 · 6 períodos · 1.8 por período'], ['Entran el día de cierre', '64%', '7 pedidos · S/9,977 el día 14 del período (miércoles)'], ['Entran en los últimos 3 días', '73%', '8 pedidos · S/13,977 entre los días 12 y 14'], ['Día con más pedidos', '3', 'mié 28 oct 2026 · día 14 de PB22']]),
      'ingreso por día: por defecto cuenta solo los entregados de los últimos 6 períodos', f);
    ok((await t('#dia_sub')) === 'por la fecha en que se ordenó · solo entregados' && (await pa.inputValue('#diaQue')) === 'ent' && (await elegido('dia_medida')) === 'n', 'y lo dice', await t('#dia_sub'));
    ok(await n('#chart_dia .vz-hit') === 84 && await n('#chart_dia .vz-sc svg > path') === 7, 'una columna por día (6 períodos × 14) y barra solo donde hubo pedidos entregados', [await n('#chart_dia .vz-hit'), await n('#chart_dia .vz-sc svg > path')]);
    ok(igual(await lista('#chart_dia .vz-sc text:not(.rot)'), ['2026-PB18', '20 ago-2 set', 'PB19', '3-16 set', 'PB20', '17-30 set', 'PB21', '1-14 oct', 'PB22', '15-28 oct', 'PB23', '29 oct-11 nov']), 'marca cada período con su nombre y sus fechas (el rango no cambia al quitar los rechazados)', await lista('#chart_dia .vz-sc text:not(.rot)'));
    ok(igual(await lista('#chart_dia .vz-sc text.rot'), ['2', '3', '2']), 'rotula solo el día más alto de cada período', await lista('#chart_dia .vz-sc text.rot'));
    ok(igual(await lista('#chart_dper .vz-sc text.rot'), ['18%', '64%']) && await n('#chart_dper .vz-hit') === 14 && (await t('#dper_sub')) === '% de los pedidos · 1 = jueves, 14 = miércoles de cierre', 'por día del período: el 64 % de los entregados entró el día 14', await lista('#chart_dper .vz-sc text.rot'));
    ok(igual(await lista('#chart_dsem .vz-sc text.rot'), ['82%']) && igual(await lista('#chart_dsem .vz-sc text:not(.rot)'), ['lun', 'mar', 'mié', 'jue', 'vie', 'sáb', 'dom']), 'por día de la semana: el 82 % entró un miércoles', await lista('#chart_dsem .vz-sc text.rot'));

    // todos los pedidos: entran también rechazados, cancelados y en proceso
    await pa.selectOption('#diaQue', 'todos');
    f = await fichas('dia_tiles');
    ok(igual(f, [['Pedidos ingresados', '14', 'S/26,377 · 6 períodos · 2.3 por período'], ['Entran el día de cierre', '64%', '9 pedidos · S/11,377 el día 14 del período (miércoles)'], ['Entran en los últimos 3 días', '71%', '10 pedidos · S/15,377 entre los días 12 y 14'], ['Día con más pedidos', '3', 'mié 11 nov 2026 · día 14 de PB23']]),
      '«Todos los pedidos» suma rechazados y cancelados', f);
    ok(await n('#chart_dia .vz-sc svg > path') === 8 && igual(await lista('#chart_dia .vz-sc text.rot'), ['1', '3', '3', '3']) && igual(await lista('#chart_dper .vz-sc text.rot'), ['14%', '14%', '64%']) && igual(await lista('#chart_dsem .vz-sc text.rot'), ['79%', '14%']) && /todos los pedidos/.test(await t('#dia_sub')),
      'y los tres gráficos cambian con él', [await lista('#chart_dia .vz-sc text.rot'), await lista('#chart_dper .vz-sc text.rot'), await lista('#chart_dsem .vz-sc text.rot')]);
    await sobre('#chart_dia .vz-hit[data-i="83"]');
    ok(igual(await tip(), ['mié 11 nov 2026 · día 14 de PB23', 'Pedidos ingresados | 3', 'Monto | S/4,726', 'Entregados | 2', 'Rechazados o cancelados | 1', 'Autocompras | 2']), 'con todos, el día dice cuántos se entregaron y cuántos se rechazaron o cancelaron', await tip());
    await pa.mouse.move(5, 5);

    // por monto
    await pa.selectOption('#diaQue', 'ent'); await pa.click('#dia_medida button[data-v="monto"]');
    f = await fichas('dia_tiles');
    ok(igual(f, [['Monto entregado', 'S/22,977', '11 pedidos · 6 períodos · S/3,829 por período'], ['Entra el día de cierre', '43%', '7 pedidos · S/9,977 el día 14 del período (miércoles)'], ['Entra en los últimos 3 días', '61%', '8 pedidos · S/13,977 entre los días 12 y 14'], ['Día con más monto', 'S/5,000', 'mié 4 nov 2026 · día 7 de PB23']]),
      '«Monto» mide el ingreso en soles entregados', f);
    ok(igual(await eje('chart_dia'), ['0', 'S/2K', 'S/4K', 'S/6K']) && igual(await lista('#chart_dia .vz-sc text.rot'), ['S/2.9K', 'S/4K', 'S/5K']) && igual(await lista('#chart_dper .vz-sc text.rot'), ['35%', '17%', '43%']) && igual(await lista('#chart_dsem .vz-sc text.rot'), ['17%', '78%']) && (await t('#dper_sub')) === '% del monto · 1 = jueves, 14 = miércoles de cierre',
      'y los gráficos pasan a soles y a % del monto', [await eje('chart_dia'), await lista('#chart_dia .vz-sc text.rot'), await lista('#chart_dper .vz-sc text.rot'), await lista('#chart_dsem .vz-sc text.rot')]);
    await sobre('#chart_dia .vz-hit[data-i="83"]');
    ok(igual(await tip(), ['mié 11 nov 2026 · día 14 de PB23', 'Monto entregado | S/3,826', 'Pedidos | 2', 'Autocompras | 2']), 'por monto, el día lleva primero los soles', await tip());
    await pa.mouse.move(5, 5);

    // rango
    await pa.click('#dia_medida button[data-v="n"]'); await pa.selectOption('#diaRango', '2');
    f = await fichas('dia_tiles');
    ok(await n('#chart_dia .vz-hit') === 28 && igual(f.map((x) => x[1] + ' ' + x[2]), ['8 S/19,126 · 2 períodos · 4.0 por período', '63% 5 pedidos · S/7,126 el día 14 del período (miércoles)', '75% 6 pedidos · S/11,126 entre los días 12 y 14', '3 mié 28 oct 2026 · día 14 de PB22']), 'el rango cambia el gráfico y las cifras a la vez', f);
    await sobre('#chart_dia .vz-hit[data-i="13"]');
    ok(igual(await tip(), ['mié 28 oct 2026 · día 14 de PB22', 'Pedidos entregados | 3', 'Monto | S/3,300', 'Autocompras | 1']), 'el día sale por la fecha en que se ordenó: el pedido del 28/10 cuenta en el PB22 aunque comisionó en el PB23', await tip());
    await sobre('#chart_dia .vz-hit[data-i="0"]');
    ok(igual(await tip(), ['jue 15 oct 2026 · día 1 de PB22', 'Pedidos entregados | 0']), 'un día sin pedidos lo dice', await tip());
    await pa.mouse.move(5, 5);
    await pa.click('#card_dia button:has-text("Ver tabla")');
    ok(await n('#dia_tabla table') === 3 && igual(await lista('#dia_tabla .prev:last-child thead th'), ['Fecha', 'Día', 'Período', 'Día del período', 'Pedidos', 'Monto', '% de los pedidos', 'Autocompras']) && igual(await lista('#dia_tabla .prev:last-child tbody tr:first-child td'), ['11/11/2026', 'mié', '2026-PB23', '14', '2', 'S/3,826', '25%', '2']) && await n('#dia_tabla .prev:last-child tbody tr') === 5,
      'la tabla del ingreso trae el día del período, el día de la semana y cada día con pedidos', await lista('#dia_tabla .prev:last-child tbody tr:first-child td'));
    ok(igual(await lista('#dia_tabla .vz-cap:first-child + .prev tbody tr:last-child td'), ['14', 'mié', '5', 'S/7,126', '63%', '3']), 'y el día 14 con sus pedidos, su monto y sus autocompras', await lista('#dia_tabla .vz-cap:first-child + .prev tbody tr:last-child td'));
    await pa.selectOption('#diaRango', '0');
    ok(await n('#chart_dia .vz-hit') === 84 && (await fichas('dia_tiles'))[0][1] === '11', '«Todo» va desde el primer pedido');
    const sinDesborde = (p) => p.evaluate(() => ({ doc: document.documentElement.scrollWidth, vp: window.innerWidth }));
    let w = await sinDesborde(pa); ok(w.doc <= w.vp + 1, 'Análisis no se desborda a lo ancho', w);

    // lo elegido se recuerda al volver a entrar
    await pa.selectOption('#diaQue', 'todos'); await pa.click('#mix_separa button[data-v="veces"]'); await pa.selectOption('#mixRango', 'u2'); await pa.selectOption('#mixQuien', 'rec');
    await pa.reload(); await listo(pa);
    ok((await elegido('mix_medida')) === 'n' && (await elegido('mix_separa')) === 'veces' && (await pa.inputValue('#mixRango')) === 'u2' && (await pa.inputValue('#mixQuien')) === 'rec' && (await t('#mix_sub')) === 'solo entregados: 8 pedidos · S/19,126'
      && (await pa.inputValue('#diaQue')) === 'todos' && (await pa.inputValue('#diaRango')) === '0' && (await fichas('dia_tiles'))[0].slice(0, 2).join(' ') === 'Pedidos ingresados 14',
      'al volver a entrar se mantiene lo elegido (por pedidos, una vez o recurrentes, últimos 2 períodos, solo recurrentes, todos los pedidos, todo el rango)', [await elegido('mix_medida'), await elegido('mix_separa'), await pa.inputValue('#mixRango'), await pa.inputValue('#diaQue'), await pa.inputValue('#diaRango')]);
    await pa.evaluate(() => localStorage.setItem('rw_ped_an', '{"medida":"otra","diaRango":"99","vista":"abs","rango":"p:2030-PB01 (no existe)","separa":7}')); await pa.reload(); await listo(pa);
    ok((await elegido('mix_medida')) === 'monto' && (await elegido('mix_vista')) === 'abs' && (await elegido('mix_separa')) === 'precio' && (await pa.inputValue('#mixRango')) === 'todo' && (await pa.inputValue('#diaRango')) === '6' && igual(await fichas('mix_tiles'), POR_MONTO),
      'una preferencia guardada que no vale (o un período que ya no existe) se ignora', [await elegido('mix_medida'), await elegido('mix_vista'), await elegido('mix_separa'), await pa.inputValue('#mixRango'), await pa.inputValue('#diaRango')]);
    await pa.click('#mix_vista button[data-v="pct"]');
    await pa.locator('#card_dia').scrollIntoViewIfNeeded(); await foto('analisis-ingreso', pa);
    await ctxA.close();

    // celular: entra en la pantalla y el día por día se desliza, empezando por lo más reciente
    const { ctx: ctxB, page: pb } = await entrar({ width: 390, height: 844 });
    w = await sinDesborde(pb); ok(w.doc <= w.vp + 1, 'celular: Análisis no se desborda a lo ancho', w);
    const cajas = await pb.evaluate(() => ['#mixRango', '#mix_medida', '#mix_separa', '#mix_vista', '#mixQuien', '#mixOrden', '#diaRango', '#diaQue', '#dia_medida'].map((s) => { const r = document.querySelector(s).getBoundingClientRect(); return r.left >= 0 && r.right <= window.innerWidth && r.width > 40; }));
    ok(cajas.every(Boolean), 'celular: los controles de las dos tarjetas caben en la pantalla', cajas);
    const sc = await pb.evaluate(() => { const e = document.querySelector('#chart_dia .vz-sc'); return { ancho: e.clientWidth, total: e.scrollWidth, pos: Math.round(e.scrollLeft) }; });
    ok(sc.total > sc.ancho && sc.pos >= sc.total - sc.ancho - 1, 'celular: el día por día se desliza y arranca en lo más reciente', sc);
    ok(igual(await pb.evaluate(() => [...document.querySelectorAll('#chart_dper .vz-sc text.t2')].map((e) => e.textContent).join(' ')), 'ju vi sá do lu ma mi ju vi sá do lu ma mi'), 'celular: caben los 14 días del período con su día de la semana');
    await pb.locator('#chart_dia .vz-hit[data-i="83"]').tap().catch(async () => { await pb.locator('#chart_dia .vz-hit[data-i="83"]').click(); });
    const tipB = await pb.evaluate(() => { const e = document.getElementById('vzTip'), r = e.getBoundingClientRect(); return { ver: e.style.display === 'block', txt: e.textContent, izq: r.left, der: r.right, ancho: window.innerWidth }; });
    ok(tipB.ver && /mié 11 nov 2026/.test(tipB.txt) && tipB.izq >= 0 && tipB.der <= tipB.ancho, 'celular: al tocar un día sale su detalle dentro de la pantalla', tipB);
    await pb.locator('#card_mix').scrollIntoViewIfNeeded(); await foto('analisis-autocompras-celular', pb);
    await pb.locator('#card_dia').scrollIntoViewIfNeeded(); await foto('analisis-ingreso-celular', pb);
    await ctxB.close();
  }

  return terminar();

  /* ---- con la foto de la base real: que todo pinte sin errores y capturas ---- */
  async function conDatosReales() {
    console.log('Datos reales: ' + db.pedidos.length + ' pedidos, ' + db.ciclos.length + ' ciclos');
    if (!db.ciclos.length) return analisisReal();
    await page.click('.tab[data-tab="tab-filtros"]'); await esperar(150);
    console.log('  tarjetas', JSON.stringify(await kpi()));
    ok(+(await kpi()).agua > 50, 'pinta los clientes con filtro'); await foto('real-filtros');
    await page.click('.card:has(#f_tanda)'); await esperar(150); await foto('real-tanda');
    console.log('  tanda del mes:', await cuenta('#filtrosBody tr.fila'), 'de agua;', await cuenta('#aireBody tr.fila'), 'de aire');
    await page.selectOption('#filtroEstado', ''); await page.selectOption('#filtroGestion', 'con'); await esperar(150); await foto('real-gestionados');
    ok(await cuenta('#filtrosBody tr.fila') >= 10, 'los de la campaña salen como gestionados', await cuenta('#filtrosBody tr.fila'));
    await page.locator('#filtrosBody tr.fila').first().click(); await esperar(150); await foto('real-ficha');
    ok(await cuenta('#fichaHist li') >= 1, 'la ficha muestra el historial');
    await page.click('#fichaBody [data-ciclo="prefiltro"] button:has-text("Registrar gestión")'); await esperar(150); await foto('real-gestion');
    await page.keyboard.press('Escape'); await page.keyboard.press('Escape');
    await page.click('.tab[data-tab="tab-clientes"]'); await page.selectOption('#cliEstado', 'comodin'); await esperar(150); await foto('real-comodines');
    console.log('  posibles comodines:', await page.evaluate(() => [...document.querySelectorAll('#clientesBody tr.fila strong')].map((e) => e.textContent)));
    await page.selectOption('#cliEstado', 'cel'); await esperar(100);
    console.log('  celulares inválidos:', await page.evaluate(() => [...document.querySelectorAll('#clientesBody tr.fila')].map((e) => e.children[0].textContent.trim() + ' ' + e.children[2].textContent.trim())));
    if (LIB_XLSX) { await page.evaluate(async () => { await cargarXLSX(); XLSX.writeFile = (wb) => { window.__wb = wb; }; });
      await page.selectOption('#cliEstado', ''); await page.click('#tab-clientes button:has-text("Excel")'); await esperar(300);
      console.log('  Excel clientes:', await page.evaluate(() => XLSX.utils.sheet_to_json(window.__wb.Sheets.Clientes).length), 'filas');
      await page.click('.tab[data-tab="tab-filtros"]'); await page.selectOption('#filtroGestion', ''); await page.click('#tab-filtros button:has-text("Excel")'); await esperar(300);
      console.log('  Excel filtros:', await page.evaluate(() => window.__wb.SheetNames.map((n) => n + ' ' + XLSX.utils.sheet_to_json(window.__wb.Sheets[n]).length).join(' · '))); }
    for (const t of ['tab-table', 'tab-cuotas', 'tab-analytics', 'tab-reglas']) { await page.click('.tab[data-tab="' + t + '"]'); await esperar(120); }
    await analisisReal();
    const { ctx: ctxM, page: movil } = await abrir({ width: 390, height: 844 });
    await ctxM.addInitScript((s) => { localStorage.setItem('sb-kiexpdaaoegbtesqmaff-auth-token', JSON.stringify(s)); localStorage.setItem('rw_ped_tab', 'tab-filtros'); }, sesionFalsa());
    await movil.goto(URL0); await movil.waitForFunction(() => document.querySelectorAll('#filtrosBody tr.fila').length > 0, null, { timeout: 20000 });
    const w = await movil.evaluate(() => ({ doc: document.documentElement.scrollWidth, vp: window.innerWidth })); ok(w.doc <= w.vp + 1, 'celular: no se desborda con datos reales', w);
    await foto('real-filtros-celular', movil);
    await movil.locator('#filtrosBody tr.fila').nth(1).click(); await esperar(150); await foto('real-ficha-celular', movil);
    await ctxM.close();
  }
  async function analisisReal() {
    const ver = async (p, pref) => {
      const tx = (sel) => p.evaluate((s) => [...document.querySelectorAll(s)].map((e) => e.textContent.replace(/\s+/g, ' ').trim()), sel);
      const fichas = (id) => p.evaluate((i) => [...document.querySelectorAll('#' + i + ' > div')].map((d) => d.querySelector('.k').textContent.trim() + ': ' + d.querySelector('.v').textContent.trim() + ' (' + d.querySelector('.hint').textContent.replace(/\s+/g, ' ').trim() + ')').join(' | '), id);
      for (const md of ['n', 'monto']) for (const sp of ['juntas', 'veces', 'precio']) { await p.click('#mix_medida button[data-v="' + md + '"]'); await p.click('#mix_separa button[data-v="' + sp + '"]'); await esperar(60);
        console.log('  ' + pref + ' autocompras (' + md + ', ' + sp + '):', (await tx('#mix_sub'))[0], '|', await fichas('mix_tiles'), '|', (await tx('#mix_total'))[0]); }
      for (const r of ['u2', 'u6', 'u26', 'todo']) { await p.selectOption('#mixRango', r); await esperar(60); console.log('  ' + pref + ' rango ' + r + ':', (await tx('#mix_sub'))[0], '|', (await tx('#mix_total'))[0], '|', (await tx('#mix_quien_sub'))[0]); }
      console.log('  ' + pref + ' asesores:', (await tx('#mix_ases'))[0], '| lista:', (await tx('#mix_lista li')).length);
      for (const q of ['todos', 'ent']) for (const md of ['monto', 'n']) for (const r of ['0', '6']) { await p.selectOption('#diaQue', q); await p.click('#dia_medida button[data-v="' + md + '"]'); await p.selectOption('#diaRango', r); await esperar(80);
        console.log('  ' + pref + ' ingreso (' + q + ', ' + md + ', ' + r + '):', await fichas('dia_tiles')); }
      if (process.env.CAPTURAS) { for (const id of ['card_mix', 'card_dia']) await p.locator('#' + id).screenshot({ path: path.join(process.env.CAPTURAS, 'real-' + id + '-' + pref + '.png') });
        const mix = (nombre) => p.locator('#card_mix').screenshot({ path: path.join(process.env.CAPTURAS, 'real-card_mix-' + nombre + '-' + pref + '.png') });
        await p.click('#mix_separa button[data-v="juntas"]'); await esperar(60); await mix('juntas'); await p.click('#mix_separa button[data-v="veces"]'); await esperar(60); await mix('veces');
        await p.selectOption('#mixRango', 'u6'); await p.selectOption('#mixQuien', 'rec'); await esperar(60); await mix('veces-u6-recurrentes'); await p.selectOption('#mixQuien', 'todos'); await p.selectOption('#mixRango', 'todo'); await p.click('#mix_separa button[data-v="precio"]'); await esperar(60);
        for (const [id, nombre] of [['chart_vendedor', 'vendedores'], ['chart_distrito', 'distritos'], ['chart_tipopago', 'pago'], ['chart_productos', 'productos']]) await p.locator('.analytics-card:has(#' + id + ')').screenshot({ path: path.join(process.env.CAPTURAS, 'real-' + nombre + '-' + pref + '.png') }); }
      const w = await p.evaluate(() => ({ doc: document.documentElement.scrollWidth, vp: window.innerWidth })); ok(w.doc <= w.vp + 1, pref + ': Análisis no se desborda con datos reales', w);
    };
    await page.click('.tab[data-tab="tab-analytics"]'); await esperar(200);
    const periodos = new Set(db.pedidos.filter((p) => /ENTREGADA/i.test(p.estatus || '') && p.periodo).map((p) => p.periodo)).size;
    ok(await cuenta('#chart_mix .vz-hit') === periodos && await cuenta('#chart_dia .vz-hit') === 84, 'Análisis pinta todos los períodos con entregados y 6 períodos de días', [await cuenta('#chart_mix .vz-hit'), periodos, await cuenta('#chart_dia .vz-hit')]);
    await ver(page, 'escritorio');      // deja: por monto, solo entregados, en pedidos, 6 períodos
    if (process.env.CAPTURAS) { const captura = (nombre) => page.locator('#card_' + nombre.split('-')[0]).screenshot({ path: path.join(process.env.CAPTURAS, 'real-card_' + nombre + '.png') });
      await page.click('#mix_vista button[data-v="abs"]'); await captura('mix-soles'); await page.click('#mix_medida button[data-v="n"]'); await page.click('#mix_vista button[data-v="pct"]'); await captura('mix-pedidos'); await page.click('#mix_medida button[data-v="monto"]');
      await page.click('#dia_medida button[data-v="monto"]'); await esperar(80); await captura('dia-monto'); await page.click('#dia_medida button[data-v="n"]');
      await page.selectOption('#diaQue', 'todos'); await page.selectOption('#diaRango', '0'); await esperar(100); await captura('dia-todos-todo'); await page.selectOption('#diaRango', '6'); await page.selectOption('#diaQue', 'ent');
      for (const [sel, nombre] of [['#chart_mix .vz-hit >> nth=12', 'real-tooltip-periodo'], ['#chart_dia .vz-hit >> nth=55', 'real-tooltip-dia'], ['#chart_vendedor .bar-row >> nth=2', 'real-tooltip-vendedor']]) {
        await page.locator(sel).scrollIntoViewIfNeeded(); await esperar(120); await page.hover(sel); await esperar(60); await page.screenshot({ path: path.join(process.env.CAPTURAS, nombre + '.png') }); }
      await page.mouse.move(5, 5); }
    const o = await abrir({ width: 390, height: 844 });
    await o.ctx.addInitScript((s) => { localStorage.setItem('sb-kiexpdaaoegbtesqmaff-auth-token', JSON.stringify(s)); localStorage.setItem('rw_ped_tab', 'tab-analytics'); }, sesionFalsa());
    await o.page.goto(URL0); await o.page.waitForFunction(() => document.querySelectorAll('#chart_dia .vz-hit').length > 0, null, { timeout: 20000 });
    await ver(o.page, 'celular');
    if (process.env.CAPTURAS) { const l = o.page.locator('#chart_dia .vz-hit >> nth=83'); await l.scrollIntoViewIfNeeded(); await esperar(120); await l.click(); await esperar(60); await o.page.screenshot({ path: path.join(process.env.CAPTURAS, 'real-tooltip-celular.png') }); }
    await o.ctx.close();
  }
  async function terminar() {
    ok(db.directas.length === 0, 'la página no escribe directo en tablas que deben entrar por función', db.directas);
    ok(errores.length === 0, 'sin errores de JavaScript', errores.slice(0, 5));
    await ctx.close(); await nav.close(); servidor.close();
    console.log('\n' + bien + ' comprobaciones bien' + (mal.length ? ', ' + mal.length + ' MAL:\n - ' + mal.join('\n - ') : ''));
    process.exit(mal.length ? 1 : 0);
  }
}
main().catch((e) => { console.error(e); process.exit(1); });
