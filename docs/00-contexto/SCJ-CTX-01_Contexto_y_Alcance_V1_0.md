# Contexto y alcance

**Sistema de Control de Jornada · Caso de estudio**
Folio SCJ-CTX-01 · Versión 1.0 · Agosto de 2026

Define el caso sobre el que trabaja el proyecto, su alcance y lo que queda deliberadamente fuera.
**Es el único documento que describe la empresa.** Todos los demás la referencian.

---

## I. La empresa del caso

**Distribuidora Central, S.A. de C.V.**

| | |
|---|---|
| Giro | Distribución de refacciones industriales |
| Plantilla | 8 empleados |
| Sede | Una sola, en la Ciudad de México |
| Jurisdicción laboral | México — Ley Federal del Trabajo |

> **Empresa ficticia.** El caso conserva el tamaño, el giro y la jurisdicción porque son lo que
> justifica las decisiones de diseño. Todo lo demás es inventado. Ver `SCJ-ANO-01`.

### Las ocho posiciones

Se nombran por función, nunca por persona:

| Id | Posición | Particularidad relevante para el modelo |
|---|---|---|
| `P01` | Dirección | Horario irregular |
| `P02` | Administración y finanzas | Jornada uniforme |
| `P03` | Encargada de almacén | Jornada uniforme, sábado corto |
| `P04` | Auxiliar de almacén | Jornada uniforme, sábado corto |
| `P05` | Auxiliar administrativo | Jornada uniforme |
| `P06` | Chofer | **Pausa en ruta, no se registra** — descuento fijo |
| `P07` | Recursos humanos | **Jornada partida por estudios** — el caso más exigente |
| `P08` | Sistemas | Jornada uniforme |

**`P06` y `P07` son las que rompen cualquier modelo ingenuo.** Una tiene una pausa que nunca se
marca; la otra tiene un horario distinto cada día y acumula deuda que repone en otros bloques.

---

## II. El problema

El control de asistencia se lleva hoy **de forma verbal, sin registro**. Nadie sabe cuántas horas
trabajó nadie. Las llegadas tarde, las salidas temprano y las horas de más se recuerdan, se
discuten y se olvidan.

Tres consecuencias:

1. **No hay base para calcular la incidencia de nómina.** Lo que se paga se acuerda de palabra
2. **No hay forma de detectar patrones.** Nadie puede decir si alguien llegó tarde tres veces este mes
3. **No hay evidencia ante una autoridad laboral.** La palabra de una parte contra la de la otra

A partir del **1 de enero de 2027**, la legislación mexicana exigirá un registro electrónico de la
jornada. El sistema deja de ser una mejora administrativa y se vuelve una obligación.

---

## III. Qué hace el sistema

Un **terminal montado en pared** identifica a la persona y registra una **marca**. El servidor
recibe las marcas, las empareja, calcula la jornada, clasifica el tiempo, lleva el saldo de horas y
produce los insumos para la nómina.

**Lo que el sistema entrega:** horas ordinarias, faltas, retardos, horas extra por tipo, días de
vacaciones tomados, incapacidades y saldo del banco de horas, por persona y por periodo.

**Lo que el sistema no hace:** no calcula nómina. No calcula retenciones, cuotas ni timbra
comprobantes fiscales. Eso lo sigue haciendo un despacho externo con los insumos que el sistema
produce.

---

## IV. Alcance de este proyecto

### Dentro

- **Diseño completo del modelo de datos del subsistema de Tiempo:** conceptual, lógico y físico
- Implementación en PostgreSQL: DDL, restricciones, índices
- Generador de datos sintéticos con los casos difíciles
- Consultas de validación y de reporte
- Pruebas de volumen y justificación de índices
- Documentación de las decisiones de diseño, incluidas las descartadas

### Fuera

| Fuera del alcance | Por qué |
|---|---|
| El subsistema de Personas | Lo diseña la otra mitad del equipo. Ver `SCJ-FRO-01` |
| El software del terminal | Ya existe. Su salida está descrita en `SCJ-CDT-01` |
| La interfaz de usuario | El proyecto es de diseño de datos |
| El cálculo fiscal de la nómina | Lo hace un tercero |
| **Las políticas reales de la empresa** | Son parámetros de despliegue, no del modelo |
| Los datos reales de las personas | Sólo se trabaja con datos sintéticos |

---

## V. Por qué el caso es interesante

Con ocho personas y 32 eventos diarios, **el volumen es trivial**. Un archivo de texto bastaría
para guardarlos. Lo que no es trivial es la **integridad temporal**:

- Un cálculo de marzo debe dar el mismo resultado en octubre, aunque la jornada de la persona haya
  cambiado tres veces desde entonces
- Una marca registrada nunca se modifica, pero debe poder corregirse
- Los topes legales cambian en fecha fija, y un cálculo histórico usa el que estaba vigente entonces
- El terminal opera sin conexión: las marcas llegan tarde, fuera de orden, y a veces con el reloj mal

**El problema de diseño no es el tamaño. Es el tiempo.**

---

*Contexto y alcance · Folio SCJ-CTX-01 · V1.0*
