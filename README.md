# Sistema de Control de Jornada — SCJ

**Diseño de base de datos · Subsistema de Tiempo**
Proyecto académico · Caso de estudio: *Distribuidora Central, S.A. de C.V.*

Diseño e implementación del modelo de datos de un sistema de registro y cálculo de jornada
laboral para una empresa distribuidora de ocho empleados en México.

---

## Qué es esto

Una empresa pequeña lleva hoy el control de asistencia de forma verbal, sin registro. A partir del
1 de enero de 2027 la legislación mexicana le exigirá un registro electrónico de jornada. Este
proyecto diseña la base de datos que lo sostiene.

El sistema completo se compone de dos subsistemas separados por una frontera explícita:

| Subsistema | Contenido | En este repositorio |
|---|---|---|
| **Personas** | Identidad, expediente, puestos, usuarios, permisos | Sólo como referencia |
| **Tiempo** | Marcas, jornadas, saldos, ausencias | **Todo el trabajo** |

La frontera está documentada en [`SCJ-FRO-01`](docs/00-contexto/SCJ-FRO-01_Contrato_de_Frontera_V1_0.md):
el subsistema de Tiempo referencia a las personas **exclusivamente por un identificador opaco**.

> **Todos los datos de este repositorio son sintéticos.** Empresa ficticia, personas inventadas,
> identificadores arbitrarios. Ver [`SCJ-ANO-01`](docs/00-contexto/SCJ-ANO-01_Reglas_de_Anonimizacion_V1_0.md).

---

## Por dónde empezar a leer

1. [`SCJ-CTX-01`](docs/00-contexto/SCJ-CTX-01_Contexto_y_Alcance_V1_0.md) — el caso y su alcance
2. [`SCJ-ESP-01`](docs/00-contexto/SCJ-ESP-01_Especificacion_Funcional_V2_1.md) — **qué debe poder representar el modelo**
3. [`SCJ-MOD-01`](docs/01-analisis/SCJ-MOD-01_Modelo_Conceptual_V1_0.md) — modelo conceptual
4. [`SCJ-MOD-02`](docs/02-modelo/SCJ-MOD-02_Modelo_Logico_V1_0.md) — modelo lógico
5. [`docs/03-decisiones/`](docs/03-decisiones/) — **las nueve decisiones de diseño** *(lo más sustancioso del proyecto)*
6. [`SCJ-TRZ-01`](docs/01-analisis/SCJ-TRZ-01_Matriz_de_Trazabilidad_V1_0.md) — requisito → tabla → consulta que lo demuestra

---

## Cómo levantar el proyecto

La base de datos vive en **Supabase** (Postgres administrado). No hay Postgres local ni
contenedor de base de datos: el DDL corre contra el proyecto de Supabase, directo. Backend y
frontend sí se pueden levantar en contenedores.

### Requisitos

- Una cuenta y un proyecto de Supabase (gratis para desarrollo), **propio de este proyecto** — no
  se comparte con ningún entorno operativo
- Python 3.11 o superior, gestionado con `uv` *(sólo para el generador de datos sintéticos y para
  correr el backend manualmente)*
- Docker + Docker Compose *(vía A, recomendada)*, o Node.js 22+ *(vía B, manual)*

### 0. Configurar la conexión

```bash
cp .env.example .env
cp frontend/.env.example frontend/.env
```

Llena `DATABASE_URL` con la cadena de conexión del proyecto (Dashboard → Project Settings →
Database → Connection string), las dos llaves de API (Project Settings → API) en `.env`, y las
mismas llaves con prefijo `VITE_` en `frontend/.env`. Ambos `.env` ya están en `.gitignore`.

`frontend/.env` también trae `VITE_CONTACTO_RH_CORREO`, `VITE_CONTACTO_SISTEMAS_CORREO`,
`VITE_CONTACTO_ADMINISTRACION_CORREO` y `VITE_CONTACTO_DIRECCION_CORREO` — los correos de contacto
que la app muestra en login/2FA/recuperación/cuenta suspendida, uno por destinatario. Son
variables sólo de frontend (el backend no envía correos, delega 100% en Supabase Auth). En dev se
leen de `frontend/.env`; en prod son de **build** (van como build arg, igual que las demás
`VITE_*`) — cambiar el valor exige `--build`, no basta reiniciar el contenedor.

### Vía A — Docker (recomendada, un comando)

```bash
./scripts/desplegar.sh dev levantar
```

Levanta backend (`http://localhost:8000`, hot reload) y frontend (`http://localhost:5173`, hot
reload). Sin base de datos local — los dos contenedores le hablan a Supabase remoto con las
credenciales del paso 0. Otras acciones: `bajar`, `reconstruir`, `registros`, `pruebas`, `estado`.
Para producción (nginx sirviendo el build en `:8080`): `./scripts/desplegar.sh prod levantar` — las
`VITE_*` son variables de *build*, cambiarlas exige `--build`, no basta reiniciar. `prod pruebas` no
existe (la imagen prod no tiene pytest ni npm) — las pruebas siempre corren con `dev pruebas`. Detalle
completo en `CLAUDE.md` §"Stack y cómo correrlo".

### Vía B — manual, sin Docker

```bash
cd backend && uv run uvicorn app.main:app --reload --port 8000    # terminal 1
cd frontend && npm install && npm run dev                          # terminal 2
```

### 1. Crear los esquemas

```bash
source .env    # o exporta DATABASE_URL a mano
psql "$DATABASE_URL" -f db/ddl/00_esquemas.sql
psql "$DATABASE_URL" -f db/ddl/01_persona_stub.sql
psql "$DATABASE_URL" -f db/ddl/02_tiempo.sql
psql "$DATABASE_URL" -f db/indices/01_indices.sql
```

Alternativa sin `psql`: pegar cada archivo, en el mismo orden, en el **SQL Editor** del dashboard
de Supabase.

### 2. Cargar parámetros de ejemplo

```bash
psql "$DATABASE_URL" -f db/ddl/03_parametros_ejemplo.sql
```

> Los valores son **de ejemplo**. Las políticas reales se cargan como parámetros en el despliegue y
> no forman parte del alcance de este proyecto.

### 3. Crear el esquema `personas` y Estructura Organizacional

```bash
psql "$DATABASE_URL" -f db/ddl/04_personas.sql
psql "$DATABASE_URL" -f db/ddl/05_personas_estructura.sql
psql "$DATABASE_URL" -f db/ddl/06_personas_rls.sql
psql "$DATABASE_URL" -f db/ddl/07_personas_storage.sql
psql "$DATABASE_URL" -f db/ddl/08_personas_permisos.sql
psql "$DATABASE_URL" -f db/ddl/09_personas_bitacora_inmutable.sql
psql "$DATABASE_URL" -f db/ddl/10_personas_area.sql
psql "$DATABASE_URL" -f db/ddl/11_area_migracion_inicial.sql
psql "$DATABASE_URL" -f db/ddl/12_personas_departamento.sql
psql "$DATABASE_URL" -f db/ddl/13_departamento_migracion_inicial.sql
psql "$DATABASE_URL" -f db/ddl/14_personas_puesto.sql
psql "$DATABASE_URL" -f db/ddl/15_estructura_placeholders_direccion.sql
psql "$DATABASE_URL" -f db/ddl/16_puesto_migracion_inicial.sql
psql "$DATABASE_URL" -f db/ddl/17_personas_asignacion.sql
psql "$DATABASE_URL" -f db/ddl/18_asignacion_trigger_baja_definitiva.sql
psql "$DATABASE_URL" -f db/ddl/19_asignacion_fn_cambiar_puesto.sql
psql "$DATABASE_URL" -f db/ddl/20_asignacion_fn_revoca_execute_public.sql
psql "$DATABASE_URL" -f db/ddl/21_personas_permiso.sql
psql "$DATABASE_URL" -f db/ddl/22_personas_puesto_permiso.sql
psql "$DATABASE_URL" -f db/ddl/23_personas_bitacora_puesto_permiso.sql
psql "$DATABASE_URL" -f db/ddl/24_puesto_permiso_trigger.sql
psql "$DATABASE_URL" -f db/ddl/25_permiso_migracion_inicial.sql
psql "$DATABASE_URL" -f db/ddl/26_puesto_permiso_bootstrap_admin_generico.sql
psql "$DATABASE_URL" -f db/ddl/27_puesto_permiso_mapeo_inicial.sql
psql "$DATABASE_URL" -f db/ddl/28_bitacora_puesto_permiso_revoca_update_delete.sql
```

`10`–`28` cierran el módulo Estructura Organizacional (`area`, `departamento`, `puesto`,
`asignacion`, `permiso`/`puesto_permiso`, ver `CLAUDE.md`). `15` agrega una 6ª área ("Dirección
General") y 6 departamentos placeholder que no son estructura real del organigrama — sólo existen
para que los puestos de dirección tengan dónde colgar (`departamento_id` es `NOT NULL`); ver el
comentario de cabecera del archivo. `18` es el primer `CREATE OR REPLACE FUNCTION` del proyecto —
reemplaza el cuerpo de `personas.fn_bitacora_sincroniza_persona()` (creada en `05`) para que una
baja definitiva también cierre las asignaciones vigentes de la persona; el trigger que la dispara
no cambia. `19` es el primer RPC del proyecto (`personas.fn_asignacion_cambiar_puesto`),
`SECURITY INVOKER`, para cerrar+abrir una asignación en una sola transacción; `20` revoca el
`EXECUTE` que Postgres le otorga a `PUBLIC` por default en todo `CREATE FUNCTION` (hallazgo de
auditoría de seguridad). `23` nace inmutable (sólo `SELECT`+`INSERT`, sin `UPDATE`/`DELETE`) desde
el arranque, a diferencia de `09` que tuvo que parchear esa falta después. `26` siembra un puesto
de bootstrap genérico ("Gerente o Encargado de TI") con los 16 permisos completos, independiente
del organigrama real — funciona aunque `11`/`13`/`15`/`16` no estén aplicados; **no** crea
`personas.usuario` (necesita un `auth.users` real, eso vive en `scripts/desplegar.sh`, sesión
`devops`). `27` es el mapeo real de permisos sobre los puestos ya sembrados del organigrama
(Responsable de Recursos Humanos, Encargado de TI, Gerente General).

### 4. Generar datos sintéticos

**Pendiente.** `tools/generador/` está vacío — es el entregable `E5` (`SCJ-GEN-01`), programado para
el 8 de septiembre. Una vez escrito, se invoca con `uv run python`, no con `python3` directo:

```bash
cd tools/generador
uv run python generar.py --personas 8 --meses 6 --semilla 42 --salida ../../db/seeds/
psql "$DATABASE_URL" -f ../../db/seeds/datos_sinteticos.sql
```

La semilla fija hace el conjunto reproducible: la misma semilla produce siempre los mismos datos.

### 5. Correr las consultas de validación

```bash
for f in db/consultas/validacion/*.sql; do echo "== $f"; psql "$DATABASE_URL" -f "$f"; done
```

---

## Estructura del repositorio

```
docs/00-contexto/    Documentos de entrada: el problema, la especificación, la frontera
docs/01-analisis/    Modelo conceptual, trazabilidad, preguntas abiertas
docs/02-modelo/      Modelo lógico, físico, normalización, diccionario de datos
docs/03-decisiones/  Un archivo por decisión de diseño, con las opciones descartadas
docs/04-pruebas/     Generador, consultas de validación y reporte, volumen, índices
docs/05-entrega/     Documento final, traspaso, retrospectiva, glosario
docs/06-actas/       Actas de las sesiones conjuntas
bitacora/            Una nota por sesión de trabajo
db/                  DDL, migraciones, consultas e índices
tools/generador/     Generador de datos sintéticos
diagramas/           Fuente en texto (Mermaid/PlantUML) e imágenes exportadas
backend/             API en FastAPI (módulo Personas y Usuarios implementado, ver CLAUDE.md)
frontend/            Interfaz web en Vite + React + TypeScript (módulo Personas y Usuarios)
diseno_paginas/      Diseño de pantallas ("Kairos"), referencia visual del frontend
scripts/             desplegar.sh — levanta backend + frontend con Docker Compose
```

> Este repositorio documenta la vía de diseño de base de datos y ahora también el backend y
> frontend que la exponen. La base de datos sigue siendo Supabase remoto — no hay servicio de
> base de datos local que levantar, ni en Docker ni fuera de él.

---

## Estado

| Hito | Fecha | Estado |
|---|---|---|
| Modelo conceptual y frontera acordados | 22 ago 2026 | **Vencido, sin evidencia registrada** — bitácora y `SCJ-ACT-01` sin llenar |
| Modelo lógico y decisiones de diseño | 28 ago 2026 | Pendiente — bloqueado por el hito anterior |
| Módulo Personas y Usuarios (backend + frontend) | — | Entregado 3 sep 2026 — **QA manual contra los 14 mockups pendiente** |
| Modelo físico y generador de datos | 8 sep 2026 | Pendiente |
| Consultas de validación | 11 sep 2026 | Pendiente |
| Vacaciones, reporte, volumen, índices | 25 sep 2026 | Pendiente |
| **Congelamiento del esquema** | 25 sep 2026 | Pendiente |
| Entrega final y traspaso | 2 oct 2026 | Pendiente |
