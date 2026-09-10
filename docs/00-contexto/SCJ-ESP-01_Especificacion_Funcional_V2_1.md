
# Especificación funcional — Subsistema de Tiempo

**Distribuidora Central, S.A. de C.V. · Sistema de Control de Jornada (SCJ)**
Folio SCJ-ESP-01 · Versión 2.1 · 5 de septiembre de 2026 · Ciudad de México

Documento de entrada del proyecto. Define **qué debe poder representar el modelo de datos**, sin
prescribir cómo. Junto con `SCJ-CTX-01`, `SCJ-CDT-01` y `SCJ-FRO-01` es todo lo que hace falta para
empezar `C1.1`.

> **Este documento no contiene datos reales.** Ni nombres, ni CURP, RFC, NSS o salarios, ni
> políticas internas, ni información de negocio. Todos los valores numéricos que aparecen son
> **ejemplos y parámetros**, no valores de operación. Las reglas de anonimización están en
> `SCJ-ANO-01`.

> **Cambio de versión (V1.0 → V2.0, mayor):** el valor de `origen` para el registro asistido pasa
> de `asistido` a **`captura_manual`**, para que coincida con `SCJ-CDT-01 V2.0` y con `SCJ-MOD-02`/
> el DDL, que ya usaban ese nombre sin que este documento se hubiera actualizado. `origen` sigue
> siendo exactamente 2 valores — se descarta cualquier tercer valor (`contingencia`) que había
> aparecido en el modelo lógico sin respaldo aquí. Ver bitácora 2026-09-05.

> **Cambio de versión (V2.0 → V2.1, menor):** se precisa §VI.2 — un día `bloqueado` no entra al
> corte quincenal hasta pasar a `revisado`. El relleno de "jornada pactada" ya descrito era
> provisional; esto sólo hace explícito que el corte quincenal no debe tratarlo como definitivo
> mientras el día siga sin revisión humana. No contradice nada ya escrito. `SCJ-PRO-12`.

---

## I. Contexto y frontera

### I.1 El sistema

Sistema de registro y cálculo de jornada laboral para una pequeña empresa de **ocho empleados** en
México. Sustituye un control que hoy se lleva de forma verbal, sin registro.

Volumen esperado: ocho personas × cuatro marcas diarias ≈ **32 eventos al día**. El volumen no es
una restricción de diseño; la **integridad temporal** sí.

### I.2 Los tres esquemas

| Esquema | Contenido | Alcance de este documento |
|---|---|---|
| **Personas** | Identidad, expediente, puestos, usuarios, permisos, compensación | Fuera |
| **Tiempo** | Marcas, jornadas, saldos, ausencias, correcciones, excepciones | **Este documento** |
| **Operación** | Bitácora del terminal: lecturas fallidas, enrolamientos, borrados, arranques, ajustes de reloj | Fuera |

El esquema de **Operación** aparece aquí sólo para declarar que existe y que **nada de él entra al
cálculo de jornada**. No se modela, no se consulta y no hace falta saber qué contiene más allá de
esta línea.

Implementación: esquemas separados en PostgreSQL. El subsistema de Tiempo recibe un stub
`persona(id)` y nada más.

### I.3 La frontera

El subsistema de Tiempo referencia a las personas **exclusivamente por un identificador opaco**
(`persona_id`).

> **Ninguna tabla del subsistema de Tiempo contiene nombre, CURP, RFC, NSS, salario ni ningún otro
> atributo de identidad.** Si un requisito parece necesitarlo, el requisito está mal planteado.

**`persona_id` es opaco por definición:** es un UUID sin significado, sin orden, sin información
derivable. No codifica antigüedad, puesto, área ni fecha de alta. Dos marcas del mismo
`persona_id` sólo dicen que son de la misma persona; nada más.

### I.4 Reglas de separación entre Personas y Tiempo

Estas siete reglas son duras. Una violación de cualquiera de ellas es un defecto, no una decisión de
diseño.

1. **`persona_id` es el único valor que cruza la frontera**, salvo la excepción documentada en
   `SCJ-FRO-01 §V` (`fecha_ingreso`, de sólo lectura, resuelta el 29 de agosto de 2026). Ningún
   otro atributo de identidad entra al subsistema de Tiempo, en ninguna forma, ni siquiera
   desnormalizado "para conveniencia de reportes".
2. **Ningún dato biométrico cruza.** Ni huella, ni plantilla, ni imagen, ni derivado. Las plantillas
   viven dentro del chip del módulo lector y no llegan a la base. Las plantillas nunca salen del chip del módulo.
3. **`plantilla_num` no existe en Tiempo.** Es un identificador interno del módulo lector; vive en
   Operación.
4. **No hay un segundo identificador de persona.** `capturista_id` —quién de RH capturó un registro
   asistido— vive en Operación, ligado por `evento_id`. Meterlo en Tiempo introduciría una segunda
   referencia a persona y rompería la frontera.
5. **`persona_id` nunca es nulo dentro de Tiempo.** Una marca cuya persona no se puede resolver
   queda apartada en Operación hasta que RH la resuelva; se inserta en Tiempo después, con el mismo
   `evento_id`. Esta regla es la que mantiene limpio el subsistema.
6. **Tiempo no escribe en Personas.** La relación es de sólo lectura y por referencia.
7. **La frontera no se cruza "temporalmente".** No hay vista, materialización, ni tabla de apoyo que
   junte identidad con marcas dentro del alcance de este subsistema.

---

## II. Alcance del subsistema de Tiempo

| Dentro | Fuera |
|---|---|
| Marcas de asistencia (`flujo = marca`) | Bitácora del terminal (`flujo = evento`) |
| Emparejamiento por paridad y tramos trabajados | Identificación biométrica y su hardware |
| Jornada asignada con vigencia y patrón semanal | Expediente, puesto, contrato, compensación |
| Topes legales con vigencia anual | Cálculo de nómina y timbrado |
| Clasificación del tiempo trabajado | Autenticación de usuarios y permisos |
| Banco de horas y sus saldos | Protocolo de sincronización y cola del kiosco |
| Correcciones y su historia | Caché de plantillas del terminal |
| Ausencias y su autorización | Enrolamiento y borrado de plantillas |
| Cola de excepciones de la marca | Tablero de alertas a TI |
| Parámetros de configuración del cálculo | Parámetros del dispositivo (supresión, NTP) |

**Regla de lectura de esta tabla:** lo que está fuera existe y funciona, pero no se modela aquí y no
condiciona el modelo. El subsistema de Tiempo recibe marcas ya formadas y trabaja con ellas.

---

## III. Modelo conceptual despersonalizado

Lo que sigue son **conceptos que el modelo debe poder representar**, no tablas. Atributos, claves,
cardinalidades y normalización son el entregable `C1.1`; este documento no los
prescribe.

### III.1 Entidades

| Concepto | Qué representa | Notas de frontera |
|---|---|---|
| **persona** | Stub. Sólo `persona_id` | Único punto de contacto con Personas |
| **marca** | Un instante registrado de identificación. Sin tipo | Ver §VII para el contenido exacto |
| **día** | El conjunto de marcas de una persona en una fecha, con su estado | Debe poder **bloquearse**. Ver §IX.5 |
| **tramo** | El intervalo entre una marca impar y la par siguiente | Puede ser derivado. Ver §IX.2 |
| **jornada_asignada** | Qué jornada tuvo esa persona, de qué fecha a qué fecha | Registro con vigencia, no atributo |
| **patrón_semanal** | Qué días se trabaja, con qué horario y qué pausas | Colgado de la jornada asignada |
| **tope_legal** | Máximo de horas semanales y de horas extra por vigencia | Tabla de vigencias, nunca constante |
| **clasificación_de_tiempo** | Ordinario, reposición o extra, sobre una porción de tiempo | Revisable sin perder historia |
| **saldo** | La deuda de horas de una persona y su antigüedad | Ver §IX.3 |
| **movimiento_de_saldo** | Cubrir, arrastrar, descontar o condonar, con motivo y autor | Permanente |
| **corrección** | Registro nuevo que apunta a un registro anterior | Nunca modifica el original |
| **ausencia** | Periodo no trabajado, con su naturaleza y su autorización | Uno o varios días |
| **excepción** | Marca o día apartado para revisión humana | Ver §VII.4 y §IX.6 |
| **parámetro** | Cualquier valor de regla de negocio | Ver §VI.9 |

### III.2 Relaciones

```
persona (stub, esquema Personas)
   │
   ├──< jornada_asignada [vigencia] ──< patrón_semanal
   │            │
   │            └── validada contra ── tope_legal [vigencia]
   │
   ├──< marca ──> día ──< tramo ──> clasificación_de_tiempo
   │      │        │                        │
   │      │        └──> excepción           └──> saldo ──< movimiento_de_saldo
   │      │
   │      └──< corrección (apunta a marca; nunca la altera)
   │
   └──< ausencia
```

**Cómo se lee.** La marca es el hecho primario y no se toca nunca. Todo lo demás —tramos, jornada
del día, clasificación, saldo— es consecuencia calculada de las marcas más los parámetros vigentes.
La corrección y la excepción son ramas laterales que registran intervención humana sin alterar el
hecho.

### III.3 Lo que el modelo conceptual no incluye, deliberadamente

- **No hay entidad "tipo de marca".** Ver §VI.1.
- **No hay entidad "pausa" ni "comida".** La pausa es el hueco entre tramos.
- **No hay "saldo a favor".** Ver §VI.6.
- **No hay entidad "capturista", "plantilla" ni "dispositivo con dueño".** Ver §I.4.

---

## IV. Origen de los datos

El subsistema de Tiempo recibe marcas de **dos fuentes ordinarias**. Las dos producen el mismo
registro y se calculan igual.

### IV.1 Terminal de registro (`origen = terminal`)

Un terminal montado en pared identifica por huella digital y produce marcas. El terminal:

- Opera **sin conexión** y sincroniza después. Las marcas pueden llegar **fuera de orden y con
  retraso** — retrasos de horas o días son normales, no anómalos
- Mantiene un **reloj propio** por hardware, que puede estar desincronizado
- Asigna a cada evento un **número de secuencia local monotónico**, que nunca reinicia ni reutiliza
- **Nunca elimina ni edita una marca.** Su cola local es sólo-agregar
- **Reintenta indefinidamente.** Una misma marca puede llegar al servidor varias veces

### IV.2 Registro asistido (`origen = captura_manual`)

La vía por la que marca **quien no otorgó consentimiento biométrico**, o quien no logra enrolar por
desgaste del dedo. Es una **vía permanente y sin consecuencia alguna** para quien la use.

> **No es una excepción rara: es una fuente ordinaria del sistema, y así se modela.**

No es lo mismo que un ajuste manual. Un ajuste corrige después un dato que salió mal; el registro
asistido captura **en el momento** una marca que sí está ocurriendo, porque la persona está ahí
parada. La hora es real, no reconstruida — la toma el sistema al capturar, nunca la escribe RH.

**Consecuencias para el modelo:**

- El campo `origen` viaja en la marca. Es un valor cerrado de dos opciones que **no identifica a
  nadie**
- `secuencia_local` **es nulo** cuando `origen = captura_manual`. Ese contador es del aparato
- El sistema debe poder **contar cuántas marcas asistidas acumula una persona en un periodo**. Si
  son muchas, algo está diciendo: o hay que reenrolarla, o el módulo está fallando

---

## V. Principios que gobiernan los datos

Cinco reglas que atraviesan todo lo demás. Si una decisión futura contradice alguna, la decisión
está mal.

1. **Nada se borra y nada se modifica.** Una marca registrada es evidencia permanente. Las
   correcciones son registros nuevos que apuntan al original.
2. **La marca no tiene tipo.** La posición ordinal lo dice todo.
3. **La hora del dispositivo es el dato; la hora de llegada es evidencia.**
4. **La evidencia nunca se pierde por un error del sistema.** Un dato irresoluble se aparta para
   intervención humana; nunca se descarta.
5. **Ningún dato biométrico ni de identidad cruza.** Sólo `persona_id`.

---

## VI. El modelo de tiempo

### VI.1 Regla de paridad

**Las marcas no tienen tipo.** No existe "marca de salida a comer" ni campo `entrada`/`salida`.
Sólo hay marcas, ordenadas cronológicamente dentro de un día. El sistema las empareja: **la impar
abre, la par cierra.**

Cada par forma un **tramo trabajado**. La suma de los tramos es la jornada del día.

**Consecuencia:** las pausas (comida, ausencias intermedias) no se registran como eventos — son
**el hueco entre tramos**. Por eso el mismo modelo sirve para pausas de treinta minutos y para
interrupciones de seis horas.

| Caso | Marcas | Tramos |
|---|---|---|
| Jornada continua | 2 | 1 |
| Jornada con una pausa | 4 | 2 |
| Jornada con dos pausas | 6 | 3 |

**Invariante: el número de marcas de un día cerrado siempre es par.**

> **El tipo se deriva, no se almacena.** El kiosco sí calcula la palabra que muestra en pantalla
> —*"Entrada registrada · 9:03"*— contando las marcas del día que tiene en su caché local, pero ese
> cálculo es **de presentación y se descarta**: no viaja, no se guarda y no obliga a nada. **El
> servidor vuelve a derivar el tipo al calcular, y su derivación manda siempre.** Si difiere de lo
> que mostró la pantalla, significa que el terminal tenía marcas sin sincronizar, no que haya un
> conflicto que reconciliar.

### VI.2 Día con número impar de marcas

**No se descarta nada.** Si a la **hora de corte** —que es parámetro, no medianoche fija— el día tiene número impar de
marcas:

1. **Ninguna marca se borra ni se invalida.** Se señala el **día**, no las marcas
2. El día queda **bloqueado** para procesamiento posterior
3. El día se registra con la **jornada pactada de esa persona ese día**, tomada del registro de
   jornada con vigencia
4. El caso entra a la **cola de excepciones** para revisión humana

Funciona igual si falta la primera marca, la última, o una intermedia.

> **Restricción de diseño:** el valor de relleno **no es una constante de ocho horas**. Es la
> jornada pactada de esa persona ese día, que sale del modelo de jornadas con vigencia (§VI.3).

**Un día `bloqueado` no entra al corte quincenal hasta que se revisa.** El relleno de §VI.2.3 es
provisional, no autoritativo: el corte quincenal excluye del cálculo cualquier día que siga
`bloqueado` (no cuenta como trabajado ni como deuda) y sólo lo toma en cuenta una vez que pasa a
`revisado`, con el valor que haya quedado tras la revisión humana. Sin esta regla, un día que
todavía no se resuelve podría generarle a alguien una deuda o un pago mal calculado en una quincena
que después hay que corregir. Confirmado 2026-09-05, `SCJ-PRO-12`.

**Marca tardía sobre día cerrado.** Una marca que llegue después de que el día quedó cerrado **no lo
reabre automáticamente**. Entra con `motivo_revision = dia_cerrado` y RH decide si procede
recalcular. Sin esta regla, el saldo de una quincena ya validada podría moverse solo.

**Requisito adicional:** el sistema debe poder contar los días bloqueados **por persona y por
periodo**, para detectar patrones.

### VI.3 Jornada asignada con vigencia

Cada persona tiene una **jornada semanal asignada**, que **no es un atributo fijo**: es un registro
con vigencia. *De tal fecha a tal fecha, esta persona tuvo esta jornada.*

Cada cambio abre un renglón nuevo y cierra el anterior.

**Requisito duro:** el cálculo de cualquier periodo pasado debe dar **el mismo resultado
indefinidamente**, aunque la jornada de la persona haya cambiado varias veces desde entonces.

Además, la jornada define el **patrón semanal**: qué días se trabaja, con qué horario y con qué
pausas. Debe poder representar:

- Jornadas uniformes de lunes a viernes con un día distinto
- Jornadas personalizadas con horario diferente por día
- Jornadas partidas en varios bloques dentro del mismo día
- Jornadas sin pausa registrada

### VI.4 Topes legales con vigencia anual

La legislación mexicana establece un **máximo de horas semanales que cambia en fecha fija**. Ejemplo
del calendario vigente:

| Vigencia | Máximo semanal | Máximo de horas extra semanales |
|---|---:|---:|
| Hasta 2026 | 48 h | 9 h |
| Desde 2027 | 46 h | 9 h |
| Desde 2028 | 44 h | 10 h |
| Desde 2029 | 42 h | 11 h |
| Desde 2030 | 40 h | 12 h |

**Requisitos:**
- Los topes viven en una **tabla de vigencias**, nunca como constantes
- El sistema **impide asignar** una jornada por encima del tope vigente en la fecha de inicio
- Un cálculo histórico usa el tope que estaba vigente **entonces**, no el actual

### VI.5 Tipos de tiempo

Todo tiempo trabajado se clasifica en uno de tres tipos:

| Tipo | Definición | Efecto |
|---|---|---|
| **Ordinario** | Dentro de la jornada pactada | Neutro |
| **Reposición** | Salda una deuda previa | Neutro — reduce el saldo |
| **Extra** | Por encima de la jornada, sin deuda previa | Genera obligación de pago |

**Regla de asignación automática:** si la persona tiene deuda, el tiempo excedente es **reposición**;
si no la tiene, es **extra**.

**Restricción:** la clasificación **no ocurre en el momento de la marca**. El terminal sólo sabe que
alguien se identificó. El tipo se determina después, y puede ser **revisado y corregido**. El modelo
debe soportar que una misma porción de tiempo cambie de clasificación sin perder su historia.

### VI.6 Banco de horas

Cuando una persona trabaja menos que su jornada asignada, acumula **deuda**. La deuda debe saldarse
dentro de una **ventana de tiempo configurable** (ejemplo: seis meses).

**Salidas posibles de un saldo:**

| Salida | Efecto en el saldo | Efecto en la compensación |
|---|---|---|
| **Cubrir** | Disminuye al trabajar las horas | Ninguno |
| **Arrastrar** | Pasa al periodo siguiente | Ninguno |
| **Descontar** | Se cancela | Ajuste a la baja |
| **Condonar** | Se cancela | Ninguno |

**Requisitos:**
- Descontar y condonar exigen **motivo escrito y autor**, conservados de forma permanente
- El modelo debe soportar un **nivel de autorización configurable** por tipo de salida. Quién
  autoriza cada una es política interna y **no se codifica aquí**
- El sistema calcula **umbrales de alerta como porcentaje de la jornada semanal de cada persona**, no
  como número fijo (ejemplo: aviso al 100%, escalamiento al 200%)
- También alerta por **antigüedad del saldo** dentro de la ventana, no sólo por magnitud
- **No existe saldo a favor.** El excedente sin deuda previa se resuelve como tiempo extra en el
  momento; no se acumula como crédito

### VI.7 Correcciones

Una marca registrada **nunca se modifica ni se elimina**.

Una corrección es un **registro nuevo que apunta a la marca original** y contiene: el valor
corregido, el motivo, el autor y el momento de la corrección.

**Requisito:** debe poder reconstruirse el estado del registro **tal como era en cualquier momento
del pasado**, junto con la cadena completa de correcciones aplicadas.

### VI.8 Ausencias

El modelo debe representar ausencias de distintas naturalezas, con efectos distintos sobre el
cálculo de jornada y sobre la compensación:

- Vacaciones
- Permiso con goce
- Permiso sin goce
- Incapacidad médica
- Falta

**Requisitos:**
- Una ausencia puede abarcar **uno o varios días**
- Debe soportar un **flujo de autorización de varios pasos**, configurable
- El saldo de vacaciones se calcula a partir de la **antigüedad de la persona**, con una tabla de
  correspondencia configurable *(ejemplo: 12 días el primer año, creciendo hasta un tope)*
- Debe poder detectarse el **traslape de ausencias** entre personas de un mismo grupo

### VI.9 Parámetros de configuración

**Ninguna regla de negocio se codifica.** Todas viven en una tabla de parámetros consultable y
editable.

Ejemplos de lo que debe ser parámetro: tolerancia antes de considerar retardo, **hora de corte del
día**, duración de la ventana del banco de horas, umbrales de alerta, tabla de días de vacaciones
por antigüedad, descuento fijo de pausa cuando no se registra.

> **Este requisito es el que permite que el modelo se construya antes de que las políticas estén
> decididas.** Es una restricción de arquitectura, no una comodidad.

**Los parámetros del dispositivo son otra cosa** —ventana de supresión local, tolerancia del reloj,
frecuencia de sincronización, tamaño de lote. Viven en Operación y **no forman parte de este
modelo**.

---

## VII. Integridad temporal — contrato de datos de la marca

En un sistema de jornada, **la hora es el dato**. Esta sección incorpora `SCJ-CDT-01` y **cierra los
nombres de campo**: los que aparecen aquí son los que se usan en el esquema, en las llaves JSON y en
el repositorio académico, sin excepción.

### VII.1 Campos que recibe el subsistema de Tiempo

| Campo | Tipo | Obligatorio | Descripción |
|---|---|---|---|
| `evento_id` | UUID v4 | Sí | Identificador único global. **Se genera en el origen**, nunca en el servidor |
| `persona_id` | UUID | Sí | Referencia opaca. **Lo único que cruza la frontera.** Nunca nulo aquí dentro |
| `momento_dispositivo` | timestamp UTC | Sí | Instante en que ocurrió, según el reloj del origen |
| `desfase_local` | texto `±HH:MM` | Sí | Desfase respecto de UTC vigente en ese instante |
| `momento_recepcion` | timestamp UTC | Sí | Cuándo llegó. Lo agrega el servidor. **No se usa para calcular** |
| `estado_reloj` | enum | Sí | `sincronizado` \| `deriva` \| `sin_sincronizar` |
| `terminal_id` | texto (≤32) | Sí | Identifica el aparato o el punto de captura |
| `secuencia_local` | entero \| nulo | No | Contador monotónico del terminal. **Nulo si `origen = captura_manual`** |
| `origen` | enum | Sí | `terminal` \| `captura_manual` |
| `requiere_revision` | booleano | Sí | Verdadero si la marca entra señalada |
| `motivo_revision` | enum \| nulo | Condicional | Obligatorio si `requiere_revision` es verdadero |
| `version_software` | texto (≤16) | Sí | Versión del software que generó el evento |

Valores de `motivo_revision`: `reloj_no_sincronizado`, `plantilla_desconocida`, `persona_inactiva`,
`fuera_de_horario`, `dia_cerrado`.

> **Sobre el campo `flujo`.** El contrato de transporte lleva un discriminador `flujo` con valores
> `marca` y `evento`. **Es un campo de transporte, no de modelo:** dentro del subsistema de Tiempo
> todo es `marca` por construcción. No se modela.

### VII.2 Lo que la marca NO lleva

| No lleva | Razón |
|---|---|
| Tipo de evento (entrada / salida) | Se deriva de la posición ordinal. §VI.1 |
| `plantilla_num` | Identificador del módulo lector. Vive en Operación |
| `capturista_id` | Segundo identificador de persona. Rompería la frontera |
| `tipo_evento`, `evento_ref`, `detalle` | Campos del flujo de bitácora. Vive en Operación |
| Nombre, foto, cualquier atributo de identidad | §I.3. Si un requisito parece necesitarlo, el requisito está mal planteado |
| Plantilla, imagen o cualquier derivado de la huella | La plantilla no sale del chip del módulo lector |

### VII.3 Cómo se representa la hora

**Instante en UTC más el desfase vigente en ese momento.** La hora local no se almacena: se
reconstruye sumando el desfase.

```
momento_dispositivo : 2026-08-17T15:03:00Z
desfase_local       : -06:00
hora local reconstruida: 2026-08-17 09:03
```

Guardar las dos piezas es lo que lo hace útil. Sólo UTC pierde el contexto de qué hora vio la persona
en la pared; sólo hora local vuelve incomparables dos marcas de zonas distintas. Hoy en México el
desfase será siempre `-06:00` porque ya no hay horario de verano — pero eso puede cambiar por
decreto, o puede aparecer una segunda sucursal, y el dato ya está ahí sin migrar nada.

**Los tres estados del reloj:**

| Estado | Significado | Efecto |
|---|---|---|
| `sincronizado` | Sincronizó dentro de la ventana de tolerancia | Ninguno |
| `deriva` | Sincronizó, pero hace más de la ventana | Marca señalada |
| `sin_sincronizar` | No ha sincronizado desde el arranque | Marca señalada |

**Reglas duras:**

- Toda marca con estado distinto de `sincronizado` entra con `requiere_revision = true` y
  `motivo_revision = reloj_no_sincronizado`
- **El orden de llegada no determina el orden de los eventos.** Ese lo fija `momento_dispositivo`, y
  en caso de empate, `secuencia_local`
- **`momento_recepcion` nunca entra al cálculo.** Sólo mide retraso de sincronización
- El día al que pertenece una marca es el del **origen**, no el de la recepción. Un retraso de
  veintisiete minutos —o de tres días— no cambia a qué día pertenece

### VII.4 Identidad, idempotencia y huecos

Deduplicar por la pareja terminal + secuencia no funciona: el registro asistido no tiene secuencia.
El contrato separa el problema en **dos llaves con dos propósitos distintos**:

| Llave | Alcance | Para qué |
|---|---|---|
| `evento_id` | Global, ambos orígenes | **Idempotencia.** Es la llave que hace seguro reintentar |
| `terminal_id` + `secuencia_local` | Sólo `origen = terminal` | **Detección de huecos.** Si llegan 1, 2 y 4, se perdió el 3 |

- El `evento_id` **nace siempre en el origen**, nunca en el servidor. En el terminal, al generar el
  evento; en la captura asistida, **al abrir el formulario**, no al dar guardar
- Un evento que llega dos veces se responde como `duplicado` y **no crea nada**
- Ambas llaves son únicas en el servidor

> **Por qué importa la captura asistida.** RH llena el formulario, da guardar, no ve respuesta y
> vuelve a dar guardar. Sin identificador estable esa persona termina con dos marcas a la misma hora
> — y como las marcas se emparejan por paridad, eso corre el día entero.

### VII.5 La marca señalada y la cola de excepciones

Una marca puede entrar **señalada** sin dejar de ser válida. `requiere_revision` no significa
"dudosa": significa que **alguien tiene que verla**.

| `motivo_revision` | Qué ocurrió |
|---|---|
| `reloj_no_sincronizado` | El reloj del origen no estaba confiable |
| `plantilla_desconocida` | El módulo devolvió un número que la caché no resolvió |
| `persona_inactiva` | La persona ya estaba de baja o suspendida al marcar |
| `fuera_de_horario` | La marca cae fuera del patrón esperado |
| `dia_cerrado` | Llegó sobre un día ya cerrado. §VI.2 |

**Requisitos del modelo:**

- La marca señalada **se guarda y se calcula igual**; la señal es información, no un rechazo
- Debe poder listarse la cola de excepciones **por persona, por periodo y por motivo**
- La resolución de una excepción **es un registro nuevo** con motivo, autor y momento. No borra la
  señal original
- El sistema debe poder contar excepciones por persona y periodo, para detectar patrones

---

## VIII. Alcance de acceso a datos

### VIII.1 Entorno

Repositorio propio, instancia PostgreSQL propia, y un stub `persona(id)` con nada más.
**Sin credenciales de ningún entorno operativo. Sin acceso a producción. Sin ninguna ruta técnica de
acceso a datos reales.** El entorno de trabajo se entrega junto con este documento.

### VIII.2 Qué sí ve

| Ve | Detalle |
|---|---|
| El esquema de Tiempo completo | Todo lo de §III.1 |
| Marcas del `flujo = marca` | Los doce campos de §VII.1 |
| `persona_id` | Como UUID opaco, sin nada detrás |
| Datos sintéticos | Ocho personas ficticias, generadas por `E5` |
| Este documento y `SCJ-CDT-01` | Son los documentos de entrada del proyecto |

### VIII.3 Qué no ve nunca

| No ve | Por qué |
|---|---|
| Nombres, CURP, RFC, NSS, salarios | §I.3 |
| Cualquier dato biométrico o derivado | No existen en el subsistema de Tiempo |
| El esquema de Operación | Ni siquiera necesita saber qué contiene |
| El flujo de bitácora del terminal | No entra al cálculo, y sale del alcance |
| Valores reales de política y de parámetros | Se cargan en el despliegue, fuera del repositorio |
| El entorno operativo y sus credenciales | Restricción de trabajo, §XI.2 |

**Consecuencia buscada:** `C1.1` puede empezar el mismo día en que se recibe este documento, sin
esperar accesos, sin firmar nada adicional y sin que exista ninguna ruta técnica por la que un dato
real pudiera alcanzar el repositorio.

---

## IX. Preguntas abiertas — entregable `C1.2`

Ocho preguntas. **Todas exigen respuesta por escrito, con argumentos de los dos lados**, en el
formato de `SCJ-DEC-00`. Un archivo por decisión.

**IX.1 · Paridad.** ¿La restricción de paridad se valida con constraint, con trigger o en la
aplicación?

**IX.2 · Saldo.** ¿El saldo del banco de horas se calcula al vuelo sobre las marcas, o se materializa
y se actualiza incrementalmente? Hay argumentos válidos de los dos lados.

**IX.3 · Corrección.** ¿Cómo se modela la corrección sin alterar el registro original — versionado,
tabla de auditoría, o registro de eventos?

**IX.4 · Vigencias.** ¿Cómo se representan las vigencias temporales, y cómo se garantiza que no se
traslapen?

**IX.5 · El día.** ¿El día es una **entidad materializada** con estado propio, o un **estado
derivado** de sus marcas? El requisito que fuerza la pregunta es que un día debe poder quedar
*bloqueado* (§VI.2), y un derivado puro no tiene dónde guardar ese estado.

**IX.6 · La excepción.** ¿`requiere_revision` y `motivo_revision` viven **como atributos de la
marca**, o como una **entidad de excepción** con su propio ciclo de vida? La segunda opción permite
que una marca acumule más de un motivo y que la resolución tenga su propia historia; la primera es
más simple y más rápida de consultar.

**IX.7 · La llave de la marca.** ¿`evento_id` es la **clave primaria** de la marca, o una clave
única alterna junto a una subrogada? El contrato exige que `evento_id` nazca en el origen y sea
único globalmente; eso no obliga a que sea la primaria, pero lo permite.

**IX.8 · Unicidad parcial.** La pareja `terminal_id` + `secuencia_local` es única **sólo cuando
`origen = terminal`**; en captura_manual, `secuencia_local` es nulo. ¿Se resuelve con un índice único
parcial, con una restricción condicional, o de otro modo?

| Pregunta | Archivo |
|---|---|
| IX.1 · Paridad | `SCJ-DEC-01` |
| IX.2 · Saldo | `SCJ-DEC-02` |
| IX.3 · Corrección | `SCJ-DEC-03` |
| IX.4 · Vigencias | `SCJ-DEC-04` |
| IX.5 · El día | `SCJ-DEC-06` |
| IX.6 · La excepción | `SCJ-DEC-07` |
| IX.7 · La llave de la marca | `SCJ-DEC-08` |
| IX.8 · Unicidad parcial | `SCJ-DEC-09` |

> `SCJ-DEC-05` —flujo de autorización de pasos variables— no nace de esta lista sino del trabajo de
> `C3.1`, y por eso conserva su número.

> **El apartado de revisión posterior a la implementación es el que da peso a la entrega.** Una
> decisión tomada en papel y revertida al construir, documentada con el motivo, vale más que cinco
> que salieron bien a la primera. Se llena en `C3.3`, no en `C1.2`.

---

## X. Convenciones de nombres

Cerradas por `SCJ-CDT-01`. Aplican en código, esquema y llaves de red, **sin excepción**.

| Regla | Valor |
|---|---|
| Idioma | **Español** |
| Estilo | `minusculas_con_guion_bajo` |
| Acentos y ñ en identificadores | **Nunca** |
| Llaves JSON | **Idénticas** a los nombres de columna |
| Valores de enum | Cortos, sin acentos: `sincronizado`, `captura_manual`, `dia_cerrado` |
| Booleanos | Prefijo verbal: `requiere_revision` |
| Timestamps | `momento_` + calificador: `momento_dispositivo`, `momento_recepcion` |
| Identificadores | Sufijo `_id`: `persona_id`, `evento_id`, `terminal_id` |

> **La palabra `tipo` está reservada y prohibida como nombre de campo discriminador.** Nombrar así a
> un campo invitaría, tarde o temprano, a que alguien meta ahí `entrada` y `salida` — y eso rompe la
> regla de paridad, que es la base del modelo. El discriminador de transporte se llama `flujo`
> justamente por esto.

---

## XI. Entregables y restricciones de trabajo

### XI.1 Entregables

**E1 · Modelo conceptual — `SCJ-MOD-01`.** Diagrama entidad-relación del sistema completo, incluyendo las entidades
del subsistema de Personas como cajas con sus atributos. *Trabajo conjunto.* La §III de este
documento es el punto de partida.

**E2 · Modelo lógico del subsistema de Tiempo — `C1.1`, en `SCJ-MOD-02`.** Entidades, atributos, claves,
cardinalidades, y **normalización justificada** — incluyendo dónde se decide no normalizar y por qué.

**E3 · Modelo físico — `SCJ-MOD-03`.** DDL de PostgreSQL: tipos, restricciones, índices, y las reglas activas que se
decidan implementar en la base.

**E4 · Decisiones de diseño — `C1.2`, en `SCJ-DEC-01` a `SCJ-DEC-09`.** Las ocho preguntas de §IX, por escrito y con
argumentos de ambos lados.

**E5 · Generador de datos sintéticos — `SCJ-GEN-01`.** Programa que produce **ocho personas ficticias con seis meses
de marcas verosímiles**, incluyendo deliberadamente los casos difíciles:

- Días con número impar de marcas, y días bloqueados
- Marcas tardías que llegan sobre un día ya cerrado
- Jornadas personalizadas con horario partido
- Deuda acumulada y episodios de reposición
- Marcas que llegan fuera de orden, y con retraso de días
- Marcas con `estado_reloj` en `deriva` y en `sin_sincronizar`
- Marcas con `origen = captura_manual`, sin `secuencia_local`
- Marcas señaladas con cada uno de los cinco valores de `motivo_revision`
- Huecos en la secuencia local de un terminal
- Correcciones aplicadas sobre marcas existentes
- Ausencias de cada tipo, incluyendo traslapes

> Los datos sintéticos son el **único** conjunto de datos con el que se trabaja. Nombres inventados,
> identificadores arbitrarios.

**E6 · Consultas de validación — `SCJ-CVA-01`.** Consultas que demuestren que el modelo responde correctamente a:
horas trabajadas en un periodo, saldo del banco de horas a una fecha dada, días bloqueados, tiempo
por tipo, cola de excepciones por motivo, huecos de secuencia por terminal, y reconstrucción del
estado histórico de un registro corregido.

### XI.2 Restricciones

- **Sin acceso a datos reales.** Únicamente datos sintéticos generados por `E5`
- **Sin acceso al entorno de producción**
- **Las políticas internas no forman parte del alcance.** Los valores de este documento son ejemplos;
  los reales se cargan como parámetros en el despliegue
- Todo nombre de persona que aparezca en datos o ejemplos es **ficticio**, conforme a `SCJ-ANO-01`

---

## XII. Verificación contra `SCJ-CDT-01`

Correspondencia campo por campo entre lo que el contrato de datos entrega y lo que esta
especificación exige representar.

| Elemento del contrato | Dónde queda en esta especificación | Estado |
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

**Conclusión:** esta especificación incorpora `SCJ-CDT-01` en su totalidad en lo que toca al
subsistema de Tiempo. Los elementos del contrato que no aparecen aquí —protocolo de sincronización, cola local del
kiosco, caché de plantillas, bitácora de operación, procesos de alta y baja— quedan **fuera del
alcance** por §II, no por omisión.

---

## XIII. Documentos relacionados

| Documento | Relación |
|---|---|
| `SCJ-CTX-01` | Contexto y alcance. Define la empresa, su tamaño y el problema que resuelve el sistema |
| `SCJ-CDT-01` | Contrato de datos del terminal. Define **qué llega**; esta especificación define **qué se hace con ello** |
| `SCJ-FRO-01` | Contrato de frontera. Desarrolla las reglas de la §I.4 y qué hacer si aparece un requisito que parece necesitar más |
| `SCJ-ANO-01` | Reglas de anonimización y checklist previo a cada entrega |
| `SCJ-MOD-01` | Modelo conceptual acordado. Parte de la §III de este documento |
| `SCJ-MOD-02` | Modelo lógico. Entregable `C1.1` |
| `SCJ-DEC-01` a `SCJ-DEC-09` | Las decisiones de diseño de la §IX, una por archivo |
| `SCJ-PRA-01` | Lista viva de preguntas abiertas, con estado y fecha de resolución |
| `CONVENCIONES.md` | Recoge la §X y la extiende a commits y estructura del repositorio |

---

*Especificación funcional · Subsistema de Tiempo · Distribuidora Central, S.A. de C.V. ·
Folio SCJ-ESP-01 · V1.0 · 18 de agosto de 2026*

*Este documento no constituye asesoría legal. Las obligaciones en materia de datos personales, de
jornada y de conservación de registros deben confirmarse con asesoría legal profesional.*
