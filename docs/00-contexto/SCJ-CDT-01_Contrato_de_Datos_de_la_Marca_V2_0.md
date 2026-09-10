# Contrato de datos de la marca

**Distribuidora Central, S.A. de C.V. · Sistema de Control de Jornada (SCJ)**
Folio SCJ-CDT-01 · Versión 2.0 · 5 de septiembre de 2026 · Ciudad de México

> **Este documento no contiene datos reales.** Ni nombres, ni CURP, RFC, NSS o salarios, ni
> políticas internas, ni información de negocio. Los valores numéricos que aparecen son
> **ejemplos y parámetros**, no valores definitivos de operación.

> **Cambio de versión (V1.1 → V2.0, mayor):** el valor de `origen` para el registro asistido pasa
> de `asistido` a **`captura_manual`** — nombre definitivo, ya usado en `SCJ-MOD-02`/DDL desde el
> 2 de septiembre; este documento no se había actualizado. Se elimina cualquier tercer valor de
> `origen` (`contingencia` apareció sin respaldo en el modelo lógico y el DDL, nunca en este
> contrato — queda descartado, `origen` sigue siendo exactamente 2 valores). Cambia el valor, no el
> concepto: §XIII completo sigue aplicando tal cual. Ver reconciliación en `db/ddl/02_tiempo.sql` y
> bitácora 2026-09-05.

---

## 0. Qué es este documento y qué no es

Este es el **contrato de datos** entre el terminal de registro y el servidor. Define exactamente qué
sale del aparato, con qué forma, bajo qué garantías y con qué protocolo. Es lo que permite que el
software del kiosco y el modelo de la base de datos se construyan **en paralelo y sin verse**.

**Lo que este documento cierra:** el formato del registro, los campos de integridad temporal, el
identificador único del evento, las reglas de deduplicación, el protocolo de sincronización y el
comportamiento sin conexión.

**Lo que este documento no hace:** no calcula jornada, no decide reglas de negocio y no define
tablas. El cálculo vive en `SCJ-ESP-01`; el modelo lógico es entregable `C1.1`. Aquí sólo se define
**qué llega**.

---

## I. Lugar en el expediente

| Documento | Relación |
|---|---|
| `SCJ-ESP-01` | Incorpora este contrato en su §VII de integridad temporal. Su §XII verifica la correspondencia campo por campo. Consume las marcas; ninguna regla de cálculo se define aquí |
| `SCJ-FRO-01` | Impone que `persona_id` es lo único que cruza la frontera. Este contrato lo hace estructuralmente imposible de romper: ningún otro atributo de identidad tiene dónde viajar |
| `SCJ-ANO-01` | Ningún dato biométrico ni de identidad real aparece en este documento ni en los datos de ejemplo |

---

## II. Los seis principios que gobiernan el contrato

Todo lo demás se deriva de estos. Si una decisión futura contradice alguno, la decisión está mal.

1. **Nada se borra y nada se modifica.** Ni en el aparato, ni en tránsito, ni en el servidor. Una
   marca registrada es evidencia permanente. Las correcciones son registros nuevos que apuntan al
   original, conforme a `SCJ-ESP-01 §VI.7`.
2. **Reintentar siempre es seguro.** Cada evento carga un identificador único, y el servidor descarta
   lo repetido. El terminal nunca tiene que saber si algo llegó: puede volver a mandarlo.
3. **La marca no tiene tipo.** No existe campo *entrada* ni *salida*. La posición ordinal lo dice
   todo: la impar abre, la par cierra.
4. **La hora del dispositivo es el dato; la hora de llegada es evidencia.** El cálculo usa la primera.
   La segunda sirve para medir retrasos y detectar anomalías.
5. **La evidencia nunca se pierde por un error del sistema.** Un rechazo, una caché vieja o un dato
   irresoluble apartan la marca para intervención humana. Nunca la descartan.
6. **Ningún dato biométrico ni de identidad cruza.** Lo único que viaja hacia el subsistema de Tiempo
   es `persona_id`. No viaja huella, plantilla, nombre, CURP, RFC, NSS ni salario.

---

## III. Los dos flujos

El terminal produce dos clases de eventos con destinos distintos. Es la separación que protege la
invariante de paridad.

| | **Flujo A — marca** | **Flujo B — evento** |
|---|---|---|
| Qué contiene | Identificaciones exitosas de personal activo | Todo lo demás que el aparato debe registrar |
| Destino | Subsistema de **Tiempo** | Bitácora de **Operación** |
| Entra al cálculo de jornada | **Sí, y es lo único que entra** | Nunca |
| Lo ve este repositorio | Sí | **No. Fuera de alcance por `SCJ-ESP-01 §II`** |
| Puede identificar persona | Siempre, por `persona_id` | A veces. Un fallo de lectura no identifica a nadie |

**Un solo canal, una sola cola, un solo protocolo.** Los dos flujos viajan en el mismo sobre y por
el mismo endpoint. Un discriminador decide a qué esquema escribe el servidor. El software del kiosco
no tiene dos clientes que mantener.

**Una sola secuencia por terminal, compartida entre ambos flujos.** El número de secuencia es el
reloj lógico del aparato, no un contador de marcas. Si es única, un hueco en la numeración delata
una pérdida sin importar de qué flujo era. El costo es que la numeración de marcas no es continua,
lo cual no importa porque nadie la lee así.

---

## IV. El sobre común

Estos campos viajan en **todos** los eventos, de los dos flujos, sin excepción.

| Campo | Tipo | Obligatorio | Descripción |
|---|---|---|---|
| `evento_id` | UUID v4 | Sí | Identificador único global. **Se genera en el origen**, nunca en el servidor |
| `terminal_id` | texto (≤32) | Sí | Identifica el aparato. Soporta varios dispositivos desde el día uno |
| `secuencia_local` | entero | Sí | Contador monotónico del terminal. Nunca se reinicia ni se reutiliza |
| `flujo` | enum | Sí | `marca` \| `evento` |
| `momento_dispositivo` | timestamp UTC | Sí | Instante en que ocurrió, según el reloj del aparato |
| `desfase_local` | texto (`±HH:MM`) | Sí | Desfase respecto de UTC vigente en ese instante |
| `estado_reloj` | enum | Sí | `sincronizado` \| `deriva` \| `sin_sincronizar` |
| `version_software` | texto (≤16) | Sí | Versión del software del terminal que generó el evento |

El servidor agrega al recibir:

| Campo | Tipo | Descripción |
|---|---|---|
| `momento_recepcion` | timestamp UTC | Cuándo llegó. **No se usa para calcular jornada** |

> **Por qué `flujo` y no `tipo`.** Deliberado. La palabra *tipo* está reservada y prohibida en este
> sistema: nombrar así al discriminador invitaría, tarde o temprano, a que alguien meta ahí
> *entrada* y *salida*.

---

## V. Flujo A — la marca

### V.1 Campos

Además del sobre común:

| Campo | Tipo | Obligatorio | Descripción |
|---|---|---|---|
| `persona_id` | UUID | Sí | Referencia opaca. **Lo único que cruza la frontera** |
| `origen` | enum | Sí | `terminal` \| `captura_manual` |
| `requiere_revision` | booleano | Sí | Verdadero si la marca entra señalada |
| `motivo_revision` | enum \| nulo | Condicional | Obligatorio si `requiere_revision` es verdadero |

Valores de `motivo_revision`: `reloj_no_sincronizado`, `plantilla_desconocida`, `persona_inactiva`,
`fuera_de_horario`, `dia_cerrado`.

### V.2 Lo que la marca NO lleva, y por qué

| No lleva | Razón |
|---|---|
| Tipo de evento (entrada / salida) | Se deriva de la posición ordinal. §V.3 |
| Número de plantilla | Es un identificador del módulo, no del subsistema de Tiempo. Vive en la bitácora |
| Identificador de quien captura | Segundo identificador de persona. Rompería la frontera. Vive en la bitácora |
| Nombre, foto, cualquier atributo de identidad | `SCJ-FRO-01 §I`. Si un requisito parece necesitarlo, el requisito está mal planteado |
| Plantilla, imagen o cualquier derivado de la huella | La plantilla se almacena y se compara dentro del módulo lector y nunca sale de ahí |

### V.3 El tipo se deriva, no se almacena

**La impar abre, la par cierra**, sin importar cuántas marcas tenga el día. Cuatro marcas son dos
tramos; seis son tres. La comida es el hueco entre tramos, no un evento.

El kiosco **sí calcula** la palabra que muestra en pantalla —*"Entrada registrada · 9:03"*— contando
las marcas del día que tiene en su caché local. Pero ese cálculo es **de presentación y se descarta**:
no viaja, no se guarda y no obliga a nada.

> **El servidor vuelve a derivar el tipo al calcular, y su derivación manda siempre.** Si difiere de
> lo que mostró la pantalla, eso significa que el terminal tenía información incompleta —marcas de
> ese día que no había sincronizado—, no que haya un conflicto que reconciliar.

### V.4 Día impar y marcas tardías

El manejo del día incompleto vive en `SCJ-ESP-01 §VI.2`. Aquí sólo se fija la interfaz:

- Si a la **hora de corte** —que es parámetro, no medianoche fija— el día tiene número impar de
  marcas, **ninguna marca se borra ni se invalida**. Se marca el *día*, no las marcas. El día queda
  bloqueado y entra a la cola de excepciones.
- El día bloqueado se registra con la **jornada pactada de esa persona ese día**, tomada del registro
  de jornada con vigencia. **No es una constante de ocho horas**: cada persona tiene la suya, según
  su jornada asignada vigente.
- Una marca que llegue después sobre un día ya cerrado **no lo reabre automáticamente**. Entra con
  `motivo_revision = dia_cerrado` y RH decide si procede recalcular. Sin esta regla, el saldo de una
  quincena ya validada podría moverse solo.

---

## VI. Flujo B — la bitácora del terminal

Además del sobre común:

| Campo | Tipo | Obligatorio | Descripción |
|---|---|---|---|
| `tipo_evento` | enum | Sí | Ver tabla siguiente |
| `persona_id` | UUID \| nulo | No | Cuando el evento identifica a alguien |
| `plantilla_num` | entero \| nulo | No | Número devuelto por el módulo |
| `capturista_id` | UUID \| nulo | No | Quién de RH ejecutó la acción |
| `evento_ref` | UUID \| nulo | No | Apunta al `evento_id` de la marca relacionada |
| `detalle` | JSON | No | Datos específicos del tipo de evento |

| `tipo_evento` | Cuándo |
|---|---|
| `lectura_repetida` | Segunda lectura del mismo dedo dentro de la ventana de supresión. **No genera marca** |
| `umbral_fallos` | Tres intentos fallidos seguidos |
| `no_enrolada` | Huella leída que no corresponde a ninguna plantilla |
| `persona_inactiva` | Intento de alguien en baja o suspensión. Se registra para auditoría |
| `plantilla_desconocida` | El módulo devolvió un número que la caché no resuelve |
| `modulo_sin_respuesta` | El lector no contesta. Alerta a TI |
| `arranque` | El aparato inició. Incluye estado del reloj y versión de la caché |
| `ajuste_reloj` | Se corrigió la hora. Incluye valor anterior y posterior |
| `cache_actualizada` | Se reemplazó la caché. Incluye sello de versión |
| `enrolamiento` | Alta de plantilla. Incluye `persona_id`, `plantilla_num` y `capturista_id` |
| `borrado_plantilla` | Baja de plantilla. **Es el asiento de que el dato biométrico se dio de baja** |
| `marca_rechazada` | El servidor rechazó definitivamente una marca. Incluye `evento_ref` y motivo |

> Los eventos `enrolamiento` y `borrado_plantilla` son la bitácora obligatoria de tratamiento del
> dato biométrico. Es lo único que permite demostrar después que un borrado ocurrió.

**Este flujo está fuera del alcance del subsistema de Tiempo** (`SCJ-ESP-01 §II`). Se documenta aquí
sólo porque comparte transporte y protocolo con el flujo A; ninguna tabla de este repositorio lo
modela.

---

## VII. Integridad temporal

### VII.1 Cómo se representa la hora

**Instante en UTC más el desfase vigente en ese momento.** La hora local no se almacena: se
reconstruye sumando el desfase.

**Ejemplo.** Alguien marca entrada a las 9:03 de la mañana en la Ciudad de México:

```
momento_dispositivo : 2026-08-17T15:03:00Z
desfase_local       : -06:00
hora local reconstruida: 2026-08-17 09:03 (CDMX)
```

Guardar las dos piezas es lo que lo hace útil. Sólo UTC pierde el contexto de qué hora vio la persona
en la pared; sólo hora local vuelve incomparables dos marcas de zonas distintas. Hoy en México el
desfase será siempre `-06:00`, porque ya no hay horario de verano — pero eso puede cambiar por
decreto, o puede aparecer una segunda sucursal, y el dato ya está ahí sin migrar nada.

### VII.2 Los tres estados del reloj

| Estado | Significado | Efecto |
|---|---|---|
| `sincronizado` | Sincronizó dentro de la ventana de tolerancia | Ninguno |
| `deriva` | Sincronizó, pero hace más de la ventana | Marca señalada |
| `sin_sincronizar` | No ha sincronizado desde el arranque | Marca señalada |

Toda marca con estado distinto de `sincronizado` entra con `requiere_revision = true` y
`motivo_revision = reloj_no_sincronizado`.

### VII.3 Reglas duras

1. **El terminal nunca ajusta su reloj hacia atrás en silencio.** Si lo hiciera, podrían existir dos
   marcas donde la segunda parece anterior a la primera. Todo ajuste genera evento `ajuste_reloj`
   con el valor anterior y el posterior.
2. **El orden de llegada no determina el orden de los eventos.** Ese lo fija `momento_dispositivo`,
   y en caso de empate, `secuencia_local`.
3. **`momento_recepcion` nunca entra al cálculo.** Sólo mide retraso de sincronización.

Parámetros de referencia: sincronización horaria contra NTP **cada hora**; ventana de tolerancia
antes de declarar `deriva`, **6 horas**.

---

## VIII. Identificador único y deduplicación

### VIII.1 Dos llaves, dos propósitos

| Llave | Alcance | Para qué |
|---|---|---|
| `evento_id` | Global, todos los orígenes | **Idempotencia.** Es la llave que hace seguro reintentar |
| `terminal_id` + `secuencia_local` | Sólo origen `terminal` | **Detección de huecos.** Si llegan 1, 2 y 4, se perdió el 3 |

Ambas son únicas en el servidor. Un evento que llega dos veces se responde como `duplicado` y no
crea nada.

### VIII.2 Dónde nace el `evento_id`

**Siempre en el origen, nunca en el servidor.** Esa es la única forma de que el reintento sea seguro.

- **En el terminal:** al momento de generar el evento, antes de encolarlo.
- **En la captura asistida:** al **abrir el formulario**, no al dar guardar. Es la distinción que hace
  que funcione. Si se generara al guardar, cada clic produciría uno distinto y no serviría de nada.
  Al confirmarse la captura, el formulario se limpia y genera uno nuevo.

> **El problema que esto resuelve.** RH llena la captura, da guardar, no ve respuesta y vuelve a dar
> guardar. Sin identificador estable, esa persona termina con dos entradas a la misma hora — y como
> las marcas se emparejan por paridad, eso corre el día entero.

### VIII.3 Supresión local en el terminal

Una segunda lectura del mismo dedo dentro de la **ventana de supresión** (parámetro, referencia
**60 segundos**) **no genera marca**: genera un evento `lectura_repetida` en la bitácora y la pantalla
avisa *"ya registrado"*.

> Esto es deduplicación **semántica**, distinta de la idempotencia de transporte. Importa para la
> paridad: dos marcas espurias a un minuto de distancia corren todo el día. Aquí se evita que la
> marca llegue siquiera a existir.

---

## IX. Protocolo de sincronización

### IX.1 Transporte

- HTTPS, JSON, `POST` a un **endpoint configurable**. El kiosco puede escribir directo a Supabase
  desde el día uno y mudarse después sin tocar código.
- Autenticación por credencial del dispositivo, distinta por terminal y revocable.
- Envío **por lotes**, con tope de eventos por lote (referencia: 200). Los dos flujos van mezclados
  en el mismo lote, ordenados por `secuencia_local`.

### IX.2 Confirmación individual

El servidor responde **uno por uno**, nunca en bloque. Un lote puede llegar parcialmente aceptado.

| Respuesta | Qué hace el terminal |
|---|---|
| `confirmado` | Marca el evento como confirmado en la cola local |
| `duplicado` | **Igual que confirmado.** Ya estaba; el reintento hizo su trabajo |
| `rechazo_transitorio` | Lo deja pendiente y reintenta. El servidor está saturado o reiniciándose |
| `rechazo_definitivo` | Lo saca de reintentos y lo pasa a `pendiente_intervencion`. **Nunca lo borra** |

### IX.3 Los tres estados de la cola local

`pendiente` → `confirmado`
`pendiente` → `pendiente_intervencion`

Nace pendiente. **Sólo lo que viene confirmado explícitamente cambia de estado.** Todo lo demás
sigue pendiente y se reintenta. La cola es **sólo-agregar**: nada se borra del dispositivo hasta que
el servidor confirma.

### IX.4 Fallo, rechazo y la diferencia entre ambos

**Silencio no es rechazo.** Si no hay red o el servidor no contesta, el terminal reintenta con espera
creciente: 5 s, 15 s, 1 min, 5 min, tope 15 min.

Hay un caso que el terminal **no puede distinguir** y por eso no lo intenta: que el servidor haya
recibido y guardado, pero se haya perdido la confirmación de regreso. Desde el aparato se ve idéntico
a que nunca llegó. El diseño no depende de saber la diferencia — reintenta, y la idempotencia limpia.

**Rechazo definitivo** es cuando reintentar nunca va a funcionar. Los casos reales son dos: evento
mal formado, o `persona_id` que el servidor no reconoce.

> **Una marca rechazada nunca se descarta.** Esa persona sí puso el dedo en el aparato, y esa
> evidencia no se puede perder porque el servidor no supo qué hacer con ella. Sale de reintentos
> —insistir sólo hace ruido— y se aparta como `pendiente_intervencion`.

**La persona que marcó nunca se entera.** La pantalla confirma y se apaga en cuatro segundos; el
rechazo ocurre después, al sincronizar, cuando ya no hay nadie enfrente. El aparato tampoco muestra
problemas administrativos en un lugar de paso, por la misma razón por la que no muestra retardos.

### IX.5 Alerta a TI

**Tablero, no correo inmediato.** Los rechazos definitivos, los huecos de secuencia, los eventos
`modulo_sin_respuesta` y las marcas en `pendiente_intervencion` aparecen en un tablero que se revisa
**al día siguiente**. Ninguno de estos casos exige reacción en minutos, y una alerta que suena
demasiado se acaba ignorando.

---

## X. Qué ocurre si el kiosco está sin conexión

**Marca igual.** La falta de red no impide registrar: es el caso previsto, no la excepción.

| Aspecto | Comportamiento |
|---|---|
| Registro | Normal. La identificación es local, no depende del servidor |
| Cola | Los eventos se acumulan en estado `pendiente` |
| Pantalla | Confirma normal. Indicador discreto de pendientes |
| LED del módulo | **Ámbar**: marca guardada en cola, sin red |
| Caché | Sigue sirviendo la última versión que bajó. Envejece, pero funciona |
| Reintento | Espera creciente hasta 15 min, indefinidamente |

**Dimensionado para 30 días desconectado.** Con ocho personas y cuatro marcas diarias son ~32 eventos
al día: menos de mil en un mes. La capacidad no es una restricción.

**Si la caché no existe o está corrupta:** el aparato **sigue marcando**. Registra con
`plantilla_desconocida` y confirma en pantalla sin nombre. Ver §XI.3.

**Prioridad al recuperar la red:** primero el flujo `marca`, después el flujo `evento`, ambos en
orden de `secuencia_local`.

---

## XI. La caché de plantillas

### XI.1 Qué contiene

| Contiene | No contiene |
|---|---|
| `plantilla_num` (entero) | Ningún dato biométrico |
| `persona_id` | Ninguna imagen de huella |
| Nombre para mostrar | CURP, RFC, NSS, salario |
| Foto de expediente | Nada del subsistema de Tiempo |

La plantilla vive **dentro del módulo**. La caché sólo guarda un entero, un nombre y una foto.

### XI.2 Cómo se mantiene

El terminal consulta al servidor **cada 15 minutos** si hay una versión más nueva de la lista. Cada
versión lleva un **sello**; el terminal guarda cuál tiene.

**Si hay una más nueva, baja la lista completa y reemplaza la suya entera.** Con ocho personas el
archivo es diminuto, así que no hay razón para hacer nada incremental — y reemplazar completo es
mucho más difícil de romper que ir aplicando cambios uno por uno. Genera evento `cache_actualizada`.

> **La caché es lo único que el terminal puede darse el lujo de perder**, porque se reconstruye desde
> el servidor en cualquier momento. Las marcas no. Si algo tiene que fallar, falla la caché.

### XI.3 Plantilla desconocida

Si el módulo devuelve un número que la caché no resuelve —típicamente alguien recién enrolado con la
caché desactualizada—:

1. El terminal **registra la marca de todos modos**.
2. Viaja con `persona_id` nulo, y el `plantilla_num` va en el evento de bitácora asociado.
3. Entra con `motivo_revision = plantilla_desconocida`.
4. La pantalla **confirma sin nombre**. La persona no tiene por qué enterarse de un problema interno.
5. El servidor la resuelve al recibirla, porque él sí tiene la correspondencia completa.
6. Si tampoco el servidor puede resolverla, queda en `pendiente_intervencion` **en el esquema de
   operación**, no en Tiempo. Cuando RH la resuelve, se inserta en Tiempo con el mismo `evento_id`.

El punto 6 es lo que mantiene limpio el subsistema de Tiempo: `persona_id` nunca es nulo ahí dentro.

---

## XII. Los procesos que sostienen el contrato

Ningún software corrige un procedimiento mal hecho. Estas dos secuencias son parte del contrato.

### XII.1 Alta — el orden importa

```
1. RH da de alta el expediente en el servidor  → nace persona_id
2. El terminal refresca su caché               → la persona aparece en la lista
3. RH enrola la plantilla en el aparato        → evento `enrolamiento`
4. La persona ya puede marcar
```

**El aparato sólo ofrece enrolar a personas activas de su caché.** Si no está en la lista, no hay a
quién asignar la plantilla y el enrolamiento no procede. Eso hace que todo `plantilla_num` nazca
ligado a un `persona_id` que existe, y deja la caché actualizada en ese mismo acto.

### XII.2 Baja — el riesgo real

**La baja nace en el expediente, no en la terminal.** El servidor es la fuente de verdad; ir al
aparato a borrar la plantilla es consecuencia de la baja, no su origen. Y hay una razón fuerte: el
borrado de la plantilla es cómo se ejerce el derecho a que un dato biométrico deje de tratarse, y su
asiento en bitácora es la única prueba de que ocurrió. Si el aparato fuera quien avisa al servidor,
ese registro colgaría de que la red haya funcionado ese día.

```
1. RH da la baja en el expediente              → la persona sale de la lista activa
2. Se genera una TAREA PENDIENTE de borrado de plantilla
3. Alguien va al aparato y borra la plantilla  → evento `borrado_plantilla`
4. La tarea se cierra SÓLO con ese evento
```

> **Son dos acciones y la segunda se puede olvidar.** Ahí está el riesgo: alguien de baja cuya
> plantilla sigue viva en el módulo puede seguir marcando. **La tarea pendiente no se cierra hasta
> que llega el evento `borrado_plantilla`.**

### XII.3 Cómo trata el servidor a quien acaba de salir

El servidor **no rechaza de golpe** una marca de alguien recién dado de baja. La acepta, la señala
con `motivo_revision = persona_inactiva` y la manda a excepciones.

La razón es una asimetría. Un **alta** que el terminal no conoce impide marcar: se nota de inmediato
y alguien avisa. Una **baja** que el terminal no conoce es peor: la persona marca, el aparato acepta,
y el problema aparece hasta sincronizar. La marca es real y el aparato hizo lo correcto con la
información que tenía; rechazarla castigaría al sistema por un desfase administrativo.

---

## XIII. El registro asistido

### XIII.1 Qué es

La vía por la que marca quien **no otorgó consentimiento biométrico**, o quien no logra enrolar por
desgaste del dedo. Es una vía permanente y sin consecuencia alguna para quien la use.

> **No es una excepción rara: es una fuente ordinaria del sistema, y así se modela.**

**No es lo mismo que un ajuste manual.** Un ajuste corrige después un dato que salió mal. El registro
asistido captura **en el momento** una marca que sí está ocurriendo, porque la persona está ahí
parada. La hora es real, no reconstruida.

### XIII.2 Cómo se comporta

| Aspecto | Decisión |
|---|---|
| Dónde se captura | Desde una computadora, no desde el aparato de pared |
| Hora | **La toma el sistema al capturar.** RH no escribe hora a mano |
| `origen` | `captura_manual` |
| `terminal_id` | El identificador del punto de captura |
| `secuencia_local` | **No aplica.** Ese contador es del aparato |
| Idempotencia | Por `evento_id` generado al abrir el formulario. §VIII.2 |
| Quién capturó | `capturista_id`, en la **bitácora**, ligado por `evento_id` |

La hora automática obliga a que RH capture en el momento y no al rato. Es intencional: es lo que
impide que existan horas inventadas.

### XIII.3 Por qué `origen` no rompe la frontera

En el subsistema de Tiempo la marca lleva un valor cerrado de dos opciones, que **no identifica a
nadie**. Eso basta para todo lo que Tiempo necesita: calcular igual, distinguir el peso probatorio
frente a una revisión, y contar cuántas asistidas acumula una persona —porque si son muchas, algo
está diciendo: o hay que reenrolarla con otro dedo, o el módulo está fallando.

**Quién capturó vive fuera**, en el esquema de operación, que ya maneja identidad por definición.
En Tiempo sigue cruzando un solo `persona_id`: el de la persona a la que pertenece la marca. El
subsistema de Tiempo ve un campo de dos valores y ni siquiera se entera de que existe un capturista.

---

## XIV. Convenciones de nombres

| Regla | Valor |
|---|---|
| Idioma | **Español**, en código, esquema y llaves de red |
| Estilo | `minusculas_con_guion_bajo` |
| Acentos y ñ en identificadores | **Nunca** |
| Llaves JSON | **Idénticas** a los nombres de columna |
| Valores de enum | Cortos, sin acentos: `sincronizado`, `captura_manual`, `no_enrolada` |
| Booleanos | Prefijo verbal: `requiere_revision` |
| Timestamps | `momento_` + calificador: `momento_dispositivo`, `momento_recepcion` |
| Identificadores | Sufijo `_id`: `persona_id`, `evento_id`, `terminal_id` |

La consistencia con `persona_id`, que ya está en toda la especificación, vale más que cualquier
argumento a favor del inglés — y evita el híbrido de tabla en español con columnas en inglés.

**Estas convenciones cierran `SCJ-ESP-01 §X` y alimentan el `CONVENCIONES.md` del repositorio.**

---

## XV. Ejemplo completo de intercambio

### Petición — lote de tres eventos

```json
POST /marcas/lote
{
  "terminal_id": "kiosco-01",
  "version_software": "1.0.0",
  "eventos": [
    {
      "evento_id": "3f2a91c4-8b7e-4d1a-9f03-2c5e7a1b8d40",
      "secuencia_local": 4417,
      "flujo": "marca",
      "momento_dispositivo": "2026-08-17T15:03:00Z",
      "desfase_local": "-06:00",
      "estado_reloj": "sincronizado",
      "persona_id": "a1b2c3d4-0000-4000-8000-000000000007",
      "origen": "terminal",
      "requiere_revision": false,
      "motivo_revision": null
    },
    {
      "evento_id": "77c0e5aa-1d34-4c8f-bb21-90f4e6d2a115",
      "secuencia_local": 4418,
      "flujo": "marca",
      "momento_dispositivo": "2026-08-17T15:04:20Z",
      "desfase_local": "-06:00",
      "estado_reloj": "sin_sincronizar",
      "persona_id": null,
      "origen": "terminal",
      "requiere_revision": true,
      "motivo_revision": "plantilla_desconocida"
    },
    {
      "evento_id": "b93d17f2-5e60-4a9c-8d77-11aa4c30e2b8",
      "secuencia_local": 4419,
      "flujo": "evento",
      "momento_dispositivo": "2026-08-17T15:04:20Z",
      "desfase_local": "-06:00",
      "estado_reloj": "sin_sincronizar",
      "tipo_evento": "plantilla_desconocida",
      "plantilla_num": 12,
      "evento_ref": "77c0e5aa-1d34-4c8f-bb21-90f4e6d2a115"
    }
  ]
}
```

### Respuesta — confirmación individual

```json
{
  "momento_recepcion": "2026-08-17T15:31:02Z",
  "resultados": [
    {
      "evento_id": "3f2a91c4-8b7e-4d1a-9f03-2c5e7a1b8d40",
      "estado": "duplicado"
    },
    {
      "evento_id": "77c0e5aa-1d34-4c8f-bb21-90f4e6d2a115",
      "estado": "confirmado",
      "resolucion": "persona_id asignado, en cola de excepciones"
    },
    {
      "evento_id": "b93d17f2-5e60-4a9c-8d77-11aa4c30e2b8",
      "estado": "confirmado"
    }
  ]
}
```

**Cómo se lee.** El primero ya había llegado en un envío anterior cuya confirmación se perdió: el
servidor responde `duplicado` y el terminal lo cierra sin crear nada. El segundo llegó con la caché
desactualizada; el servidor lo resolvió y lo mandó a excepciones. El tercero es su evento de bitácora,
que lleva el `plantilla_num` que la marca no puede llevar. **El retraso de 27 minutos entre
`momento_dispositivo` y `momento_recepcion` no afecta el cálculo: el día es el del terminal.**

---

## XVI. Verificación contra `SCJ-ESP-01`

Correspondencia campo por campo entre lo que este contrato entrega y lo que `SCJ-ESP-01` exige
representar.

| Campo de este contrato | Dónde queda en `SCJ-ESP-01` | Estado |
|---|---|---|
| `evento_id` | §VII.1, §VII.4 | ✓ |
| `desfase_local` | §VII.1, §VII.3 | ✓ |
| `origen` | §IV.2, §VII.1 | ✓ |
| `version_software` | §VII.1 | ✓ |
| `requiere_revision` / `motivo_revision` | §VII.1, §VII.5 | ✓ |
| Idempotencia por `evento_id`, huecos por secuencia | §VII.4 | ✓ |
| Día impar no borra ni invalida marcas | §VI.2 | ✓ |
| Marca tardía sobre día cerrado no reabre | §VI.2 | ✓ |
| Relleno = jornada pactada con vigencia, no constante | §VI.2, §VI.3 | ✓ |
| Tipo derivado de la posición ordinal | §VI.1 | ✓ |
| Hora = UTC + desfase; recepción no calcula | §VII.3 | ✓ |
| `persona_id` nunca nulo dentro de Tiempo | §I.4 regla 5 | ✓ |
| Registro asistido como fuente ordinaria | §IV.2 | ✓ |
| `capturista_id` y `plantilla_num` fuera de Tiempo | §I.4, §VII.2 | ✓ |
| Convenciones de nombres | §X | ✓ |
| Marca nunca se modifica ni elimina | §V.1, §VI.7 | ✓ |

**Conclusión:** `SCJ-ESP-01` incorpora este contrato en su totalidad en lo que toca al subsistema de
Tiempo. Los elementos de este contrato que no aparecen ahí —protocolo de sincronización, cola local
del kiosco, caché de plantillas, bitácora de operación, procesos de alta y baja— quedan **fuera del
alcance** de la especificación por su §II, no por omisión.

---

## XVII. Qué habilita este documento

| Habilita | Qué desbloquea |
|---|---|
| `SCJ-ESP-01` | Los nombres de campo de este contrato son los que usa toda la especificación, sin excepción |
| `CONVENCIONES.md` | Sección de nomenclatura del repositorio |
| Software del kiosco | Formato, cola, protocolo y comportamiento sin red, completos |
| `C1.1` · Modelo lógico | Se sabe exactamente qué recibe el subsistema de Tiempo, antes de modelarlo |
| `E5` · Generador de datos sintéticos | Los casos difíciles del generador (marcas fuera de orden, relojes en deriva, registro asistido) están definidos aquí |

---

## XVIII. Registro de decisiones

Decisiones tomadas en sesión de diseño, con su alternativa descartada.

| # | Decisión | Alternativa descartada |
|---|---|---|
| 1 | El tipo de marca se deriva de la posición ordinal y no se almacena | Campo `tipo = entrada/salida`, que contradice la regla de paridad |
| 2 | El día impar no borra ni invalida marcas; se bloquea el día | Borrar o invalidar los registros a medianoche |
| 3 | El relleno es la jornada pactada con vigencia | Constante de 8 horas diarias |
| 4 | Marca tardía sobre día cerrado no lo reabre; entra a excepción | Recálculo automático |
| 5 | Dos flujos separados, un solo canal y una sola secuencia compartida | Secuencias independientes por flujo |
| 6 | `origen` en Tiempo; `capturista_id` en la bitácora | Meter el capturista en el subsistema de Tiempo |
| 7 | Hora automática en la captura asistida | Que RH escriba la hora |
| 8 | `evento_id` generado al abrir el formulario | Generarlo al guardar, o en el servidor |
| 9 | Rechazo definitivo se aparta, nunca se descarta | Descartar la marca inválida |
| 10 | Alerta a TI en tablero, revisión al día siguiente | Correo inmediato |
| 11 | UTC más desfase | Sólo UTC, o sólo hora local |
| 12 | Español, `snake_case`, sin acentos en identificadores | Inglés, o híbrido |
| 13 | Plantilla desconocida registra marca sin nombre en pantalla | Descartar la lectura no resuelta |
| 14 | La baja nace en el expediente; el borrado de plantilla es tarea pendiente | Que la baja nazca en la terminal |
| 15 | Caché por reemplazo completo con sello de versión | Actualización incremental |

---

## XIX. Pendientes

- [ ] Fijar el valor de producción de la **hora de corte del día** (parámetro)
- [ ] Fijar la **ventana de supresión local** (referencia: 60 s)
- [ ] Fijar la **ventana de tolerancia del reloj** antes de declarar `deriva` (referencia: 6 h)
- [ ] Definir el servidor NTP de referencia
- [ ] Diseñar la pantalla de captura asistida (RH) con la generación de `evento_id` al abrir
- [ ] Diseñar el tablero de excepciones y su revisión diaria
- [ ] Confirmar el **plazo de conservación** de las marcas, conforme a `SCJ-ANO-01`

---

*Contrato de datos de la marca · Distribuidora Central, S.A. de C.V. · Folio SCJ-CDT-01 · V1.1 ·
18 de agosto de 2026*

*Este documento no constituye asesoría legal. Las obligaciones en materia de datos personales y de
conservación de registros deben confirmarse con asesoría legal profesional.*
