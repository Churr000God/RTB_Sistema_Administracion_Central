# Reglas de anonimización

**Sistema de Control de Jornada**
Folio SCJ-ANO-01 · Versión 1.0 · Agosto de 2026

Qué nunca entra a este repositorio, cómo se nombran las entidades ficticias, y el checklist que se
corre antes de cada entrega.

> **El repositorio es anónimo por construcción, no por edición al final.** La forma barata de
> cumplir es que nunca entre lo que después habría que quitar. La forma cara —y la que falla— es
> anonimizar a tres días de la entrega, buscando nombres en veinte archivos.

---

## I. Lo que nunca entra

| No entra | Ni siquiera |
|---|---|
| El nombre real de la empresa | En un comentario, en un commit, en un nombre de archivo |
| El nombre de una persona real | En datos de prueba, en un ejemplo, en una captura de pantalla |
| CURP, RFC, NSS, domicilio, teléfono, correo reales | Aunque sean inventados por analogía con uno real |
| **Los valores reales de política** — tolerancia de retardo, umbrales, tabla de vacaciones | En el repositorio van valores de ejemplo, marcados como tales |
| Datos biométricos, en cualquier forma | No existen en el subsistema de Tiempo. Nunca cruzan la frontera |
| Documentos con folio ajeno a `SCJ-` | Un folio de otra organización la identifica |
| Credenciales, cadenas de conexión, direcciones de red internas | Van en variables de entorno, y el `.env` está en `.gitignore` |
| Salarios, montos, información comercial | Fuera del subsistema y fuera del alcance |

---

## II. Cómo se nombra lo ficticio

| Entidad | Convención | Ejemplo |
|---|---|---|
| La empresa | Una sola, definida en `SCJ-CTX-01` | Distribuidora Central, S.A. de C.V. |
| Las posiciones | Por función, con clave `Pnn` | `P06` — Chofer |
| Las personas en datos sintéticos | Nombres inventados por el generador, de una lista fija | `Rosa Delgado`, `Iván Peña` |
| Identificadores de persona | Arbitrarios, sin relación con nada | `persona_id = 1..8` |
| Terminales | `TERM-01`, `TERM-02` | |
| Fechas | Reales, del calendario del proyecto | No hay riesgo en una fecha |

**El generador usa una semilla fija.** Los mismos datos sintéticos se reproducen siempre, y nadie
tiene que preguntarse si un renglón raro es real.

---

## III. La regla de las capturas de pantalla

Es por donde se escapan los datos con más frecuencia.

- Ninguna captura de una herramienta conectada a un entorno real
- Toda captura sale de la base con datos sintéticos
- Antes de pegar una captura: leer la barra de título, las pestañas del navegador y el nombre de la
  conexión de la base

---

## IV. Checklist previo a cada entrega

**Se corre antes de cada entrega parcial, no sólo al final.**

| # | Verificación | |
|---|---|---|
| 1 | `grep -ri` de las palabras prohibidas sobre todo el repositorio, incluido el historial | |
| 2 | Ningún archivo con folio distinto de `SCJ-` | |
| 3 | Ningún `.env`, `.pgpass` ni archivo de credenciales versionado | |
| 4 | Los valores de parámetros están marcados como *ejemplo* | |
| 5 | Las capturas de pantalla no muestran nombres de conexión ni pestañas | |
| 6 | El historial de commits no menciona nombres reales | |
| 7 | Los datos sintéticos se regeneraron con la semilla documentada | |

### Lista de palabras a buscar

Se mantiene **fuera del repositorio**, en un archivo local del que la ejecuta. Escribir la lista de
palabras prohibidas dentro del repositorio las introduce en el repositorio.

```bash
# El archivo palabras.txt vive fuera del repositorio
grep -rniIf ~/palabras.txt . && echo "REVISAR" || echo "limpio"
git log --all --format='%s %b' | grep -niIf ~/palabras.txt
```

---

## V. Qué hacer si algo se escapó

**Si un dato real entró y ya se subió:** no basta con borrarlo en un commit nuevo. Queda en el
historial. Se reescribe el historial, o —más simple y más seguro— **se crea el repositorio de nuevo
y se copia el árbol limpio de archivos**, sin el historial.

Es incómodo. Por eso el checklist se corre antes de subir, no después.

---

*Reglas de anonimización · Folio SCJ-ANO-01 · V1.0*
