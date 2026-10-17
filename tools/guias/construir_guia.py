"""Construye la versión HTML autocontenida de una guía de uso a partir de su .md.

Uso (desde la raíz del repo):
    uv run --no-project --with markdown-it-py python tools/guias/construir_guia.py docs/07-procesos/GUIA_ASIGNAR_PUESTO.md

Escribe el .html junto al .md, con la identidad de RTB (la misma de GUIA_ALTA_PERSONA_Y_USUARIO.html) y todas las
imágenes incrustadas en base64, para que el archivo se pueda mandar solo (correo, USB) sin la carpeta de capturas.
Las imágenes se resuelven relativas al .md. El primer `# Título` del .md pasa a la portada.
"""

import base64
import html
import mimetypes
import re
import sys
from pathlib import Path

from markdown_it import MarkdownIt

MARCA = Path(__file__).resolve().parents[2] / "docs/07-procesos/guia_alta/marca"

CSS = """
@import url('https://fonts.googleapis.com/css2?family=Great+Vibes&family=Inter:wght@400;500;600&family=Playfair+Display:wght@600;700&display=swap');
:root{--teal:#159895;--teal-light:#57C5B6;--blanco:#fff;--superficie:#EEF8F7;--navy-medio:#1A5F7A;--navy:#002B5B;--oro:#AD9551;--linea:rgba(0,43,91,.12);
--font-display:'Great Vibes',cursive;--font-title:'Playfair Display',Georgia,serif;--font-body:'Inter',system-ui,-apple-system,'Segoe UI',sans-serif;
--mascota:url(__MASCOTA__)}
*{box-sizing:border-box}
html{scroll-behavior:smooth}
body{margin:0;background:var(--blanco);color:var(--navy);font:16px/1.65 var(--font-body)}
.hero{position:relative;overflow:hidden;background:radial-gradient(120% 90% at 50% -10%,rgba(87,197,182,.55) 0%,rgba(21,152,149,.18) 45%,rgba(255,255,255,0) 75%),var(--blanco);padding:36px 24px 54px;border-bottom:1px solid var(--linea)}
.hero-in{max-width:900px;margin:0 auto;display:grid;grid-template-columns:1fr auto;gap:12px;align-items:center}
.hero img.logo{width:84px;height:84px;display:block;margin-bottom:10px;border:0;box-shadow:none;border-radius:0}
.kicker{letter-spacing:.18em;font-size:.72rem;font-weight:600;color:var(--oro);text-transform:uppercase}
.empresa{font-family:var(--font-display);font-size:clamp(2rem,6vw,3.2rem);line-height:1.05;color:var(--navy);margin:2px 0 4px}
.hero h1{font-family:var(--font-title);font-weight:700;font-size:clamp(1.5rem,4.4vw,2.2rem);line-height:1.2;margin:.5em 0 0;color:var(--navy)}
.hero .mascota{width:clamp(120px,24vw,210px);height:auto;border:0;box-shadow:none;border-radius:0;filter:drop-shadow(0 6px 10px rgba(0,43,91,.18));animation:flota 5s ease-in-out infinite}
@keyframes flota{0%,100%{transform:translateY(0)}50%{transform:translateY(-6px)}}
.onda{position:absolute;left:0;right:0;bottom:-1px;height:22px;background:radial-gradient(60px 14px at 30px 22px,var(--blanco) 98%,transparent 100%) 0 0/60px 22px repeat-x}
main{max-width:860px;margin:0 auto;padding:30px 22px 70px}
h2{font-family:var(--font-title);font-weight:700;font-size:1.5rem;margin:2.2em 0 .6em;padding-bottom:.35em;border-bottom:3px solid var(--oro);color:var(--navy)}
h2::before{content:"";display:inline-block;width:.55em;height:.55em;border-radius:50%;background:var(--teal);margin-right:.5em;vertical-align:.08em}
h3{font-family:var(--font-title);font-weight:600;color:var(--navy-medio);margin-top:1.6em}
a{color:var(--teal)}strong{color:var(--navy)}
img{max-width:100%;height:auto;display:block;margin:.8em 0;border:1px solid var(--linea);border-radius:14px;box-shadow:0 2px 10px rgba(0,43,91,.07)}
table{border-collapse:separate;border-spacing:0;width:100%;margin:1em 0;background:var(--blanco);border:1px solid var(--linea);border-radius:14px;overflow:hidden;font-size:.95rem}
th{background:var(--superficie);color:var(--navy);text-align:left;font-weight:600}
th,td{padding:.6em .8em;border-bottom:1px solid var(--linea);vertical-align:top}tr:last-child td{border-bottom:0}
code{background:var(--superficie);border:1px solid var(--linea);border-radius:6px;padding:.05em .4em;font-size:.9em;color:var(--navy-medio)}
blockquote{position:relative;margin:1.2em 0;padding:1em 1.2em 1em 5.4em;background:var(--superficie);border-left:5px solid var(--teal);border-radius:0 14px 14px 0;min-height:4.6em}
blockquote::before{content:"";position:absolute;left:.7em;top:.8em;width:3.6em;height:3.6em;background:var(--mascota) center/contain no-repeat}
blockquote p{margin:.35em 0}blockquote ul{margin:.35em 0;padding-left:1.2em}
hr{border:0;border-top:1px solid var(--linea);margin:2.2em 0}
em{color:var(--navy-medio)}
footer{max-width:860px;margin:0 auto;padding:24px 22px 40px;border-top:3px solid var(--oro);display:flex;gap:16px;align-items:center;color:var(--navy-medio);font-size:.85rem}
footer img{width:64px;height:64px;margin:0;border:0;box-shadow:none;border-radius:0}
@media (max-width:640px){.hero-in{grid-template-columns:1fr}.hero .mascota{justify-self:center}}
@media print{.hero{background:#fff}.hero .mascota{animation:none}img{break-inside:avoid}blockquote{break-inside:avoid}}
@media (prefers-reduced-motion:reduce){.hero .mascota{animation:none}}
"""


def data_uri(ruta: Path) -> str:
    tipo = mimetypes.guess_type(ruta.name)[0] or "application/octet-stream"
    return f"data:{tipo};base64,{base64.b64encode(ruta.read_bytes()).decode()}"


def construir(ruta_md: Path) -> Path:
    texto = ruta_md.read_text(encoding="utf-8")
    titulo_match = re.match(r"#\s+(.+)\n", texto)
    if not titulo_match:
        sys.exit(f"{ruta_md}: falta el '# Título' en la primera línea")
    titulo = titulo_match.group(1).strip()
    cuerpo_md = texto[titulo_match.end():]
    # Los comentarios HTML (marcadores de captura pendiente) no se publican.
    cuerpo_md = re.sub(r"<!--.*?-->", "", cuerpo_md, flags=re.S)

    md = MarkdownIt("commonmark").enable("table")
    cuerpo = md.render(cuerpo_md)

    def incrustar(m: re.Match) -> str:
        src = html.unescape(m.group(1))
        if src.startswith(("data:", "http:", "https:")):
            return m.group(0)
        ruta_img = (ruta_md.parent / src).resolve()
        if not ruta_img.is_file():
            sys.exit(f"{ruta_md}: no existe la imagen {src}")
        return f'src="{data_uri(ruta_img)}"'

    cuerpo = re.sub(r'src="([^"]+)"', incrustar, cuerpo)

    mascota = data_uri(MARCA / "mascota_rtb.png")
    logo = data_uri(MARCA / "logo_rtb.png")
    titulo_html = html.escape(titulo)
    pagina = f"""<!doctype html><html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>{titulo_html} · RTB</title><style>{CSS.replace("__MASCOTA__", mascota)}</style></head><body>
<header class="hero"><div class="hero-in"><div>
<img class="logo" alt="Logotipo de Refacciones Tomás Badillo" src="{logo}">
<div class="kicker">Sistema de Administración Central · Guía de uso</div>
<div class="empresa">Refacciones Tomás Badillo</div>
<h1>{titulo_html}</h1></div>
<img class="mascota" alt="Mascota de Refacciones Tomás Badillo" src="{mascota}"></div><div class="onda"></div></header>
<main>{cuerpo}</main>
<footer><img alt="" src="{mascota}"><div><strong>Refacciones Tomás Badillo, S.A. de C.V.</strong><br>Control de jornada · Sistema de Administración Central<br>Ante cualquier duda, avisa a Recursos Humanos o a Sistemas.</div></footer>
</body></html>
"""
    salida = ruta_md.with_suffix(".html")
    salida.write_text(pagina, encoding="utf-8")
    return salida


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    for arg in sys.argv[1:]:
        print(construir(Path(arg)))
