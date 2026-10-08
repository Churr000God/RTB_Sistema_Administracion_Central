import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

export default defineConfig({
  plugins: [react()],
  test: {
    environment: "jsdom",
    globals: true,
    setupFiles: ["./src/setupTests.ts"],
    // Con la suite completa en paralelo los timeouts por defecto (5 s por prueba) se quedaban cortos
    // en equipos cargados y producían flakes (TemporizadorTotp, publicar consentimiento).
    testTimeout: 20_000,
    hookTimeout: 20_000,
    coverage: {
      provider: "v8",
      reporter: ["text", "html"],
    },
  },
});
