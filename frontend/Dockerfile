# Frontend SCJ — Vite + React + TypeScript.
#
# Tres targets: `dev` (servidor de Vite con hot reload), `build` (compila el
# bundle estático) y `prod` (nginx sirviendo ese bundle). El compose de dev usa
# `dev`; el override de producción usa `prod` (que depende de `build`).
#
# Las variables VITE_* son de BUILD, no de runtime -- Vite las incrusta en el
# bundle al compilar. En `prod` llegan como --build-arg desde
# docker-compose.prod.yml; cambiar una exige reconstruir la imagen, no basta
# reiniciar el contenedor.

FROM node:22-alpine AS base
WORKDIR /app

# --- dev -----------------------------------------------------------------
FROM base AS dev
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
EXPOSE 5173
# El compose de dev monta ./frontend:/app encima de la imagen y guarda
# node_modules en un volumen nombrado aparte -- nace vacío la primera vez, así
# que hay que repetir `npm install` al arrancar (idempotente si ya está listo).
CMD ["sh", "-c", "npm install && npm run dev -- --host 0.0.0.0"]

# --- build (compila el bundle estático) -------------------------------------
FROM base AS build
ARG VITE_SUPABASE_URL
ARG VITE_SUPABASE_ANON_KEY
ARG VITE_API_URL
ENV VITE_SUPABASE_URL=$VITE_SUPABASE_URL \
    VITE_SUPABASE_ANON_KEY=$VITE_SUPABASE_ANON_KEY \
    VITE_API_URL=$VITE_API_URL
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
RUN npm run build

# --- prod (nginx sirviendo el bundle) ---------------------------------------
FROM nginx:alpine AS prod
COPY --from=build /app/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 80
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -qO- http://localhost/ || exit 1
