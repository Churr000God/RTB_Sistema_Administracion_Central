/* Andamiaje de los mockups: iconos (mismos de lucide-react), sidebar real de AppShell, conmutador de estados. */
const ICONOS = {
  terminal: '<rect width="20" height="14" x="2" y="3" rx="2"/><path d="M8 21h8"/><path d="M12 17v4"/>',
  userplus: '<path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><line x1="19" x2="19" y1="8" y2="14"/><line x1="22" x2="16" y1="11" y2="11"/>',
  history: '<path d="M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8"/><path d="M3 3v5h5"/><path d="M12 7v5l4 2"/>',
  fingerprint: '<path d="M12 10a2 2 0 0 0-2 2c0 1.02-.1 2.51-.26 4"/><path d="M14 13.12c0 2.38 0 6.38-1 8.88"/><path d="M17.29 21.02c.12-.6.43-2.3.5-3.02"/><path d="M2 12a10 10 0 0 1 18-6"/><path d="M2 16h.01"/><path d="M21.8 16c.2-2 .131-5.354 0-6"/><path d="M5 19.5C5.5 18 6 15 6 12a6 6 0 0 1 .34-2"/><path d="M8.65 22c.21-.66.45-1.32.57-2"/><path d="M9 6.8a6 6 0 0 1 9 5.2v2"/>',
  x: '<path d="M18 6 6 18"/><path d="m6 6 12 12"/>',
  clock: '<circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/>',
  lock: '<rect width="18" height="11" x="3" y="11" rx="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/>',
  wrench: '<path d="M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.77-3.77a6 6 0 0 1-7.94 7.94l-6.91 6.91a2.12 2.12 0 0 1-3-3l6.91-6.91a6 6 0 0 1 7.94-7.94z"/>',
  arrow: '<path d="M5 12h14"/><path d="m12 5 7 7-7 7"/>',
  alert: '<path d="m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3"/><path d="M12 9v4"/><path d="M12 17h.01"/>',
  circle: '<circle cx="12" cy="12" r="10"/><path d="M12 16v-4"/><path d="M12 8h.01"/>',
  alertc: '<circle cx="12" cy="12" r="10"/><line x1="12" x2="12" y1="8" y2="12"/><line x1="12" x2="12.01" y1="16" y2="16"/>',
  check: '<path d="M20 6 9 17l-5-5"/>',
  checkc: '<circle cx="12" cy="12" r="10"/><path d="m9 12 2 2 4-4"/>',
  trash: '<path d="M3 6h18"/><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6"/><path d="M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/>',
  loader: '<path d="M21 12a9 9 0 1 1-6.219-8.56"/>',
  search: '<circle cx="11" cy="11" r="8"/><path d="m21 21-4.3-4.3"/>',
  radio: '<path d="M4.9 16.1C1 12.2 1 5.8 4.9 1.9"/><path d="M7.8 4.7a6.14 6.14 0 0 0-.8 7.5"/><circle cx="12" cy="9" r="2"/><path d="M16.2 4.8c2 2 2.26 5.11.8 7.47"/><path d="M19.1 1.9a9.96 9.96 0 0 1 0 14.1"/><path d="M9.5 18h5"/><path d="m8 22 4-11 4 11"/>',
  eye: '<path d="M2 12s3-7 10-7 10 7 10 7-3 7-10 7-10-7-10-7Z"/><circle cx="12" cy="12" r="3"/>',
  chevron: '<path d="m6 9 6 6 6-6"/>',
  chevronr: '<path d="m9 18 6-6-6-6"/>',
};
function ic(n, s = 16) {
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${s}" height="${s}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${ICONOS[n]}</svg>`;
}
document.querySelectorAll('[data-ic]').forEach((el) => { el.innerHTML = ic(el.dataset.ic, +el.dataset.s || 16) + el.innerHTML; });

/* Sidebar idéntico al de layouts/AppShell.tsx (grupo Tiempo expandido, ítem activo por página). */
(function () {
  const aside = document.getElementById('shell-aside');
  if (!aside) return;
  const activo = document.body.dataset.activo;
  const grupos = [
    ['Personas y Usuarios', []], ['Estructura organizacional', []],
    ['Jornadas', ['Asignar jornada', 'Corridas de batch']],
    ['Marcas', ['Captura manual', 'Registro de marcas', 'Tramos', 'Días']],
    ['Autorizaciones', ['Excepciones pendientes', 'Ausencias']],
    ['Reportes', ['Banco de horas', 'Alertas de retardo']],
    ['Terminales', ['Terminales', 'Anomalías']],
    ['Parámetros', []],
  ];
  aside.innerHTML = `<div class="app-shell-wordmark">Kairos</div><nav class="app-shell-nav" aria-label="Principal">` +
    grupos.map(([g, items]) => {
      const abierto = items.includes(activo);
      return `<div class="nav-grupo"><div class="nav-grupo-titulo ${abierto ? 'nav-grupo-titulo--activo' : ''}">${g}${ic(abierto ? 'chevron' : 'chevronr')}</div>` +
        (abierto ? `<div class="nav-subitems">${items.map((i) => `<span class="nav-subitem ${i === activo ? 'nav-subitem--activo' : ''}">${i}</span>`).join('')}</div>` : '') + `</div>`;
    }).join('') + `</nav><div class="app-shell-footer"><p class="app-shell-correo">persona@rtb.example</p></div>`;
})();

/* Conmutador de estados: <section data-solo="vacio carga"> se muestra sólo en esos estados. */
(function () {
  const barra = document.querySelector('[data-estados]');
  const raiz = document.documentElement;
  const params = new URLSearchParams(location.search);
  if (params.has('limpio')) document.body.classList.add('limpio');
  const lista = barra ? barra.dataset.estados.split(',') : [];
  function poner(e) {
    document.body.setAttribute('data-estado-activo', e);
    document.querySelectorAll('[data-solo]').forEach((s) => {
      s.toggleAttribute('data-visible', s.dataset.solo.split(' ').includes(e));
    });
    if (barra) barra.querySelectorAll('button').forEach((b) => b.setAttribute('aria-pressed', b.dataset.e === e));
  }
  if (barra) {
    barra.querySelector('.estados').innerHTML = lista.map((e) => { const [k, t] = e.split(':'); return `<button type="button" data-e="${k}" aria-pressed="false">${t}</button>`; }).join('');
    barra.querySelectorAll('button').forEach((b) => b.addEventListener('click', () => poner(b.dataset.e)));
    poner(params.get('estado') || lista[0].split(':')[0]);
  }
  /* "¿Por qué?" — divulgación accesible (botón con aria-expanded + región con el texto fijo del backend). */
  document.querySelectorAll('.enlace-porque').forEach((b) => b.addEventListener('click', () => {
    const t = document.getElementById(b.getAttribute('aria-controls'));
    const abre = t.hidden; t.hidden = !abre; b.setAttribute('aria-expanded', abre);
  }));
})();

/* Iconos de campo: el CSS real (.campo-con-icono svg.icono-campo) ancla el <svg> directo, sin
   wrapper — un <span> intermedio lo dejaba fuera de flujo absoluto y "flotando" sobre el input. */
document.querySelectorAll('[data-ic-campo]').forEach((el) => {
  el.outerHTML = ic(el.dataset.icCampo).replace('<svg ', '<svg class="icono-campo" ');
});
