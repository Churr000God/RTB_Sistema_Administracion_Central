import "@testing-library/jest-dom/vitest";
import { configure } from "@testing-library/react";

// findBy*/waitFor esperan hasta 3 s (por defecto 1 s): bajo carga de la suite completa 1 s no alcanza.
configure({ asyncUtilTimeout: 3000 });

// jsdom no implementa showModal()/close() de <dialog>. Polyfill mínimo: abrir = atributo `open`,
// cerrar = quitarlo y disparar `close` (lo que el navegador real hace además del foco atrapado).
if (typeof HTMLDialogElement !== "undefined" && !HTMLDialogElement.prototype.showModal) {
  HTMLDialogElement.prototype.showModal = function showModal(this: HTMLDialogElement) {
    this.setAttribute("open", "");
  };
  HTMLDialogElement.prototype.close = function close(this: HTMLDialogElement) {
    this.removeAttribute("open");
    this.dispatchEvent(new Event("close"));
  };
}
