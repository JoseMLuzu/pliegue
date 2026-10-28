"use strict";

const $ = (id) => document.getElementById(id);
const state = { files: [], busy: false, job: null, generation: 0, upload: null, nextId: 1, videoAvailable: null, engineIssue: "" };
const number = new Intl.NumberFormat("es", { maximumFractionDigits: 1 });
const count = new Intl.NumberFormat("es");
const SESSION_KEY = "pliegue-job";

function currentMode() { return document.querySelector('input[name="mode"]:checked').value; }
function setMode(mode) {
  document.querySelector(`input[name="mode"][value="${mode === "video" ? "video" : "zip"}"]`).checked = true;
  updateMode();
}
function updateMode() {
  const video = currentMode() === "video";
  $("settings-eyebrow").textContent = video ? "02 / CALIDAD VISUAL" : "02 / A TU RITMO";
  $("level-help").textContent = video ? "Más detalle puede ocupar más." : "La calidad siempre es la misma.";
  $("mode-description").textContent = video
    ? "H.265 · Misma resolución · Audio original. La recodificación de video tiene pérdida."
    : "Cualquier archivo · Datos idénticos al extraer. Los MP4 y JPG pueden no reducirse.";
  const titles = video ? ["Más ahorro", "Alta calidad", "Máximo detalle"] : ["Rápida", "Equilibrada", "Máxima"];
  const descriptions = video ? ["Más compresión", "Recomendado", "Menos compresión"] : ["Menos tiempo", "Lo mejor de ambos", "Busca más ahorro"];
  document.querySelectorAll(".level-option").forEach((option, index) => {
    option.querySelector(".level-title").firstChild.textContent = titles[index] + " ";
    option.querySelector(".level-description").textContent = descriptions[index];
  });
  $("drop-title").textContent = video ? "Arrastra un video aquí" : "Arrastra tus archivos aquí";
  $("drop-hint").textContent = video ? "MP4, MOV, M4V, MKV, WebM o AVI. Un video por tarea." : "Fotos, videos, documentos… todos son bienvenidos.";
  $("file-input").multiple = !video;
  $("file-input").accept = video ? ".mp4,.mov,.m4v,.mkv,.webm,.avi" : "";
  $("output-extension").textContent = video ? ".mp4 / .mkv" : ".zip";
  $("engine-note").hidden = !video || state.videoAvailable !== false;
  if (state.engineIssue) $("engine-note").textContent = state.engineIssue;
  $("hero-quality").textContent = video ? "Gran detalle." : "Todo intacto.";
  $("idle-title").replaceChildren(video ? "Tu video." : "Todo lo tuyo.", document.createElement("br"), video ? "Con menos peso." : "En un solo ZIP.");
  $("idle-description").textContent = video ? "Recodificación H.265 con calidad visual alta, conservando la resolución. El ahorro depende del video." : "Reúne tus archivos en un ZIP sin alterar sus datos. El ahorro depende del contenido.";
  $("idle-verification").textContent = video ? "Misma resolución. Audio original." : "100% del contenido original";
  $("idle-verification-detail").textContent = video ? "Comprobamos que el resultado se decodifica." : "Verificado mediante SHA-256 antes de descargar.";
  if (["mis-archivos", "mi-video-reducido"].includes($("archive-name").value)) $("archive-name").value = video ? "mi-video-reducido" : "mis-archivos";
  setBusy(state.busy);
  updateFormatWarning();
}

function updateFormatWarning() {
  const hasVideo = state.files.some(({ file }) => fileKind(file) === "video");
  $("format-warning").hidden = !hasVideo || currentMode() === "video";
  $("format-warning").textContent = "Un ZIP probablemente no reducirá estos videos, incluso en nivel Máxima. Para recodificar un video con calidad visual alta, selecciona solo ese archivo y elige Reducir video.";
}

function formatSize(bytes) {
  if (!bytes) return "0 B";
  const units = ["B", "KB", "MB", "GB", "TB"];
  const index = Math.min(Math.floor(Math.log(bytes) / Math.log(1024)), units.length - 1);
  return `${number.format(bytes / 1024 ** index)} ${units[index]}`;
}

function icon(name) {
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.classList.add("icon");
  svg.setAttribute("aria-hidden", "true");
  const use = document.createElementNS("http://www.w3.org/2000/svg", "use");
  use.setAttribute("href", `#i-${name}`);
  svg.append(use);
  return svg;
}

function fileKind(file) {
  const extension = file.name.split(".").pop().toLowerCase();
  if (file.type.startsWith("image/") || /^(png|jpe?g|webp|gif|heic|avif|svg|tiff?|raw)$/.test(extension)) return "image";
  if (file.type.startsWith("video/") || /^(mp4|mov|webm|mkv|avi|m4v)$/.test(extension)) return "video";
  if (file.type.startsWith("audio/") || /^(mp3|wav|flac|aac|ogg|m4a)$/.test(extension)) return "audio";
  return "file";
}

function announce(message) { $("announcer").textContent = message; }
function showError(message) {
  $("error-message").textContent = message;
  $("error-message").hidden = !message;
}
function remember(id) {
  try { if (id) sessionStorage.setItem(SESSION_KEY, id); else sessionStorage.removeItem(SESSION_KEY); } catch { /* Storage is optional. */ }
}

async function api(path, options = {}) {
  const response = await fetch(path, { ...options, cache: "no-store" });
  const result = await response.json();
  if (!response.ok) throw new Error(result.error || "No se pudo completar la operación.");
  return result;
}

function releaseJob(id) {
  if (id) fetch(`/api/jobs/${encodeURIComponent(id)}`, { method: "DELETE", keepalive: true }).catch(() => {});
}

function showResult(view) {
  for (const name of ["idle", "progress", "done"]) $("result-" + name).hidden = name !== view;
}

function setBusy(busy) {
  state.busy = busy;
  $("dropzone").disabled = busy;
  $("file-input").disabled = busy;
  $("settings").disabled = busy;
  $("mode-settings").disabled = busy;
  $("clear-button").disabled = busy;
  const video = currentMode() === "video";
  $("compress-button").disabled = busy || state.files.length === 0 || (video && state.videoAvailable !== true);
  $("compress-button").querySelector("span").textContent = busy ? "Procesando…" : video ? "Reducir video" : "Comprimir en ZIP";
  document.querySelectorAll(".file-remove").forEach((button) => { button.disabled = busy; });
}

function resetResult() {
  releaseJob(state.job);
  state.job = null;
  remember(null);
  showResult("idle");
  $("result-status").textContent = "Elige tus archivos y el modo que necesitas.";
}

function renderFiles() {
  const list = $("file-list");
  const fragment = document.createDocumentFragment();
  for (const entry of state.files) {
    const { file, id } = entry;
    const li = document.createElement("li");
    li.className = "file-item";
    const kind = fileKind(file);
    const typeIcon = document.createElement("span");
    typeIcon.className = `file-type-icon ${kind}`;
    typeIcon.append(icon(kind));
    const meta = document.createElement("div");
    meta.className = "file-meta";
    const name = document.createElement("span");
    name.className = "file-name";
    name.textContent = file.name;
    name.title = file.name;
    const size = document.createElement("span");
    size.className = "file-size";
    size.textContent = formatSize(file.size);
    meta.append(name, size);
    const remove = document.createElement("button");
    remove.className = "icon-button file-remove";
    remove.setAttribute("aria-label", `Quitar ${file.name}`);
    remove.title = `Quitar ${file.name}`;
    remove.disabled = state.busy;
    remove.append(icon("close"));
    remove.addEventListener("click", () => {
      if (state.busy) return;
      state.files = state.files.filter((item) => item.id !== id);
      resetResult();
      renderFiles();
      announce(`${file.name} eliminado de la selección.`);
      $("dropzone").focus();
    });
    li.append(typeIcon, meta, remove);
    fragment.append(li);
  }
  list.replaceChildren(fragment);
  $("files-section").hidden = state.files.length === 0;
  $("file-count").textContent = `${count.format(state.files.length)} ${state.files.length === 1 ? "archivo" : "archivos"}`;
  $("total-size").textContent = formatSize(state.files.reduce((sum, entry) => sum + entry.file.size, 0));
  updateFormatWarning();
  setBusy(state.busy);
}

function addFiles(files) {
  if (state.busy || !files.length) return;
  if (state.files.length + files.length > 10000) {
    showError("Puedes seleccionar hasta 10.000 archivos en una tarea.");
    return;
  }
  // Keep same-name files: the server will assign a unique name inside the ZIP.
  state.files.push(...Array.from(files, (file) => ({ id: state.nextId++, file })));
  resetResult();
  setMode(state.files.length === 1 && fileKind(state.files[0].file) === "video" ? "video" : "zip");
  showError("");
  renderFiles();
  announce(`${files.length} ${files.length === 1 ? "archivo añadido" : "archivos añadidos"}.`);
}

function updateProgress(percent, label, current = "") {
  percent = Math.max(0, Math.min(100, percent));
  $("progress-fill").style.width = `${percent}%`;
  $("progress-track").setAttribute("aria-valuenow", Math.floor(percent));
  $("progress-percent").textContent = `${Math.floor(percent)}%`;
  $("progress-label").textContent = label;
  $("current-file").textContent = current;
  $("current-file").title = current;
}

function uploadFile(jobId, index, file, onProgress) {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    state.upload = xhr;
    xhr.open("PUT", `/api/jobs/${jobId}/files/${index}`);
    xhr.setRequestHeader("Content-Type", "application/octet-stream");
    xhr.upload.addEventListener("progress", (event) => { if (event.lengthComputable) onProgress(event.loaded); });
    xhr.addEventListener("load", () => {
      state.upload = null;
      if (xhr.status >= 200 && xhr.status < 300) resolve();
      else {
        let message = "No se pudo transferir el archivo al compresor local.";
        try { message = JSON.parse(xhr.responseText).error || message; } catch { /* Use fallback. */ }
        reject(new Error(message));
      }
    });
    xhr.addEventListener("error", () => { state.upload = null; reject(new Error("No hay conexión con Pliegue. Comprueba que la aplicación sigue abierta.")); });
    xhr.addEventListener("abort", () => { state.upload = null; reject(new DOMException("Cancelado", "AbortError")); });
    xhr.send(file);
  });
}

function renderDone(job) {
  if (job.mode === "video") { renderVideoDone(job); return; }
  setMode("zip");
  const saved = job.total - job.outputSize;
  const percentage = job.total > 0 ? saved / job.total * 100 : 0;
  const smaller = saved > 0;
  showResult("done");
  $("result-done").classList.toggle("no-savings", !smaller);
  $("result-icon").replaceChildren(icon(smaller ? "check" : "info"));
  $("result-outcome").textContent = smaller ? "03 / COMPRESIÓN COMPLETADA" : "03 / SIN REDUCCIÓN DE TAMAÑO";
  $("result-title").replaceChildren();
  if (smaller) {
    $("result-title").append("Más espacio.", document.createElement("br"), "La misma calidad.");
  } else {
    $("result-title").append("Este archivo", document.createElement("br"), "no se redujo.");
  }
  const value = smaller ? number.format(percentage) : formatSize(job.outputSize);
  $("saving-number").textContent = value;
  if (smaller) {
    const percent = document.createElement("span");
    percent.textContent = "%";
    $("saving-number").append(percent);
  }
  $("saving-caption").textContent = smaller ? `${formatSize(saved)} menos en tu equipo` : "tamaño real del ZIP";
  $("original-size").textContent = formatSize(job.total);
  $("compressed-size").textContent = formatSize(job.outputSize);
  $("output-label").textContent = "Tu ZIP";
  $("verified-note").replaceChildren(icon("shield"), "Integridad SHA-256 verificada");
  $("result-note").textContent = smaller
    ? "Cada archivo conserva todos sus datos. Extrae el ZIP para recuperar los originales."
    : `El ZIP ocupa ${formatSize(Math.max(0, -saved))} más que el original. El nivel Máxima no puede garantizar una reducción: los MP4 y otros formatos ya están comprimidos. Este ZIP solo sirve para empaquetarlos.`;
  const renamed = job.files.some((file, index) => state.files[index] && file.name !== state.files[index].file.name);
  if (renamed) $("result-note").append(" Algunos nombres se ajustaron para evitar duplicados o caracteres incompatibles.");
  $("download-button").href = `/api/jobs/${job.id}/download`;
  $("download-button").setAttribute("download", job.archiveName);
  $("download-button").replaceChildren(icon("download"), smaller ? "Descargar ZIP" : "Descargar ZIP sin ahorro");
  $("result-status").textContent = smaller
    ? `${count.format(job.files.length)} ${job.files.length === 1 ? "archivo verificado" : "archivos verificados"}. Cero detalles perdidos.`
    : "No se consiguió reducir el tamaño. Tus originales siguen intactos.";
  setBusy(false);
  announce(smaller ? "Compresión terminada. Integridad verificada. Tu ZIP está listo para descargar." : "No se consiguió reducir el tamaño. El ZIP ocupa lo mismo o más que el original.");
}

function renderVideoDone(job) {
  setMode("video");
  const saved = job.total - job.outputSize;
  const smaller = saved > 0 && !job.originalUsed;
  showResult("done");
  $("result-done").classList.toggle("no-savings", !smaller);
  $("result-icon").replaceChildren(icon(smaller ? "check" : "info"));
  $("result-outcome").textContent = smaller ? "03 / VIDEO REDUCIDO" : "03 / SIN AHORRO · ORIGINAL CONSERVADO";
  $("result-title").replaceChildren(smaller ? "Menos peso." : "Este video", document.createElement("br"), smaller ? "Gran detalle." : "no se redujo.");
  $("saving-number").textContent = smaller ? number.format(saved / job.total * 100) : formatSize(job.total);
  if (smaller) { const percent = document.createElement("span"); percent.textContent = "%"; $("saving-number").append(percent); }
  $("saving-caption").textContent = smaller ? `${formatSize(saved)} menos en tu equipo` : "se conserva el archivo original";
  $("original-size").textContent = formatSize(job.total);
  $("compressed-size").textContent = formatSize(job.outputSize);
  $("output-label").textContent = smaller ? "Tu video H.265" : "Original";
  const details = job.videoDetails;
  $("result-note").textContent = smaller
    ? `${details.width} × ${details.height} · Misma resolución y orientación. ${details.audio.length ? "Audio copiado sin recodificar. " : "Sin pista de audio. "}La imagen se recodificó con pérdida; revisa el resultado antes de sustituir el original. Necesitas un reproductor compatible con H.265.`
    : "Esta configuración no consiguió un archivo menor. Se descartó la recodificación y puedes descargar el original intacto. Puedes probar Más ahorro; puede afectar más al detalle visual.";
  $("verified-note").replaceChildren(icon("shield"), smaller ? "Decodificación comprobada · " + (details.audio.length ? "audio SHA-256 verificado" : "sin audio") : "Se entrega el original sin modificar");
  $("download-button").href = `/api/jobs/${job.id}/download`;
  $("download-button").setAttribute("download", job.archiveName);
  $("download-button").replaceChildren(icon("download"), smaller ? `Descargar ${job.archiveName.endsWith(".mkv") ? "MKV" : "MP4"}` : "Descargar original");
  $("result-status").textContent = smaller ? "Video comprobado. Tu original sigue intacto en tu equipo." : "Sin reducción de tamaño. No se entrega un video mayor.";
  setBusy(false);
  announce(smaller ? "Video reducido. El resultado está listo para descargar." : "No hubo ahorro. Se conserva el archivo original.");
}

async function pollJob(jobId, generation) {
  while (generation === state.generation) {
    const job = await api(`/api/jobs/${jobId}`);
    if (generation !== state.generation) return;
    if (job.state === "done") { renderDone(job); return; }
    if (job.state === "error") throw new Error(job.error);
    if (job.state === "cancelled") throw new Error("Esta tarea se canceló. Puedes comenzar de nuevo.");
    if (job.mode === "video") {
      const checking = job.state === "verifying";
      $("progress-step").textContent = checking ? "COMPROBANDO EL VIDEO" : job.phase === "analyzing" ? "ANALIZANDO TU VIDEO" : "REDUCIENDO EL VIDEO";
      $("progress-title").textContent = checking ? "Que todo funcione." : "Más detalle. Menos peso.";
      $("progress-description").textContent = checking
        ? job.phase === "audio" ? "Comparando el audio con el original mediante SHA-256." : "Decodificando el resultado y comprobando su resolución, orientación y duración."
        : job.phase === "analyzing" ? "Revisando el formato y las pistas del archivo." : "Recodificando la imagen en H.265. Conservamos la resolución y copiamos el audio. Un video grande puede tardar bastante.";
      const percent = checking ? job.phase === "audio" ? 99 : 85 + job.videoProgress * 13 : job.phase === "analyzing" ? 17 : 20 + job.videoProgress * 65;
      updateProgress(percent, checking ? "Verificando video" : "Recodificando", job.currentFile);
      $("result-status").textContent = "Tu original permanece intacto en tu equipo.";
      await new Promise((resolve) => setTimeout(resolve, 600));
      continue;
    }
    if (job.state === "verifying") {
      $("progress-step").textContent = "COMPROBANDO CADA DETALLE";
      $("progress-title").textContent = "Todo en su lugar.";
      $("progress-description").textContent = "Leemos el ZIP y comparamos cada archivo con su original mediante SHA-256.";
      updateProgress(80 + (job.total ? job.verified / job.total * 20 : 20), "Verificando integridad", job.currentFile);
      $("result-status").textContent = "La confianza también se comprueba.";
    } else {
      $("progress-step").textContent = "HACIENDO UN POCO DE ESPACIO";
      $("progress-title").textContent = "Cada byte cuenta.";
      $("progress-description").textContent = "Comprimiendo tus archivos sin modificar su contenido. Los archivos grandes pueden tardar unos minutos.";
      updateProgress(25 + (job.total ? job.processed / job.total * 55 : 0), "Comprimiendo", job.currentFile);
      $("result-status").textContent = "Menos peso. El mismo contenido.";
    }
    await new Promise((resolve) => setTimeout(resolve, 400));
  }
}

async function startCompression() {
  if (state.busy || state.files.length === 0) return;
  const mode = currentMode();
  if (mode === "video" && (state.files.length !== 1 || fileKind(state.files[0].file) !== "video")) {
    showError("Selecciona un solo video para este modo. Para varios archivos, elige ZIP sin pérdida."); return;
  }
  const archiveName = $("archive-name").value.trim().replace(/\.(zip|mp4|mkv)$/i, "");
  if (!archiveName) { showError("Escribe un nombre para el resultado."); $("archive-name").focus(); return; }
  resetResult();
  showError("");
  const generation = ++state.generation;
  setBusy(true);
  showResult("progress");
  $("progress-step").textContent = "PREPARANDO TUS ARCHIVOS";
  $("progress-title").textContent = "Ya estamos en ello.";
  $("progress-description").textContent = "Copiando tus archivos al compresor en tu propio equipo. No se envían a la nube.";
  $("result-status").textContent = "Todo sucede aquí, en tu equipo.";
  updateProgress(0, "Preparando");
  if (matchMedia("(max-width: 680px)").matches) $("result-progress").scrollIntoView({ block: "center", behavior: "smooth" });
  let jobId = null;
  try {
    const job = await api("/api/jobs", {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ name: archiveName, mode, level: document.querySelector('input[name="level"]:checked').value,
        files: state.files.map(({ file }) => ({ name: file.name, size: file.size, modified: file.lastModified })) }),
    });
    jobId = job.id;
    if (generation !== state.generation) { releaseJob(jobId); return; }
    state.job = jobId;
    remember(jobId);
    let transferred = 0;
    const total = state.files.reduce((sum, { file }) => sum + file.size, 0);
    for (const [index, { file }] of state.files.entries()) {
      if (generation !== state.generation) return;
      const baseline = transferred;
      await uploadFile(jobId, index, file, (loaded) => {
        if (generation === state.generation) updateProgress(total ? (baseline + loaded) / total * (mode === "video" ? 15 : 25) : 0,
          `Preparando ${index + 1} de ${state.files.length}`, file.name);
      });
      transferred += file.size;
    }
    if (generation !== state.generation) return;
    await api(`/api/jobs/${jobId}/start`, { method: "POST" });
    if (generation !== state.generation) return;
    await pollJob(jobId, generation);
  } catch (error) {
    if (generation !== state.generation) return;
    handleFailure(error, jobId);
  }
}

function handleFailure(error, jobId) {
  releaseJob(jobId);
  state.job = null;
  remember(null);
  setBusy(false);
  showResult("idle");
  const message = error instanceof TypeError ? "No hay conexión con Pliegue. Comprueba que server.py sigue abierto y vuelve a intentarlo." : error.message;
  showError(message || "No se pudo completar la compresión. Inténtalo de nuevo.");
  $("result-status").textContent = "Tus originales siguen intactos. Puedes volver a intentarlo.";
  announce("La compresión se interrumpió. Revisa el mensaje de error.");
}

function cancelCompression() {
  ++state.generation;
  state.upload?.abort();
  resetResult();
  setBusy(false);
  showError("");
  announce("Proceso cancelado. Tus archivos originales siguen intactos.");
}

$("dropzone").addEventListener("click", () => $("file-input").click());
$("file-input").addEventListener("change", (event) => { addFiles(event.target.files); event.target.value = ""; });
let dragDepth = 0;
document.addEventListener("dragover", (event) => {
  if (event.dataTransfer?.types.includes("Files")) event.preventDefault();
});
document.addEventListener("drop", (event) => {
  if (event.dataTransfer?.types.includes("Files")) event.preventDefault();
  dragDepth = 0;
  $("dropzone").classList.remove("dragging");
});
$("dropzone").addEventListener("dragenter", (event) => {
  event.preventDefault();
  if (!state.busy && event.dataTransfer?.types.includes("Files")) { dragDepth++; $("dropzone").classList.add("dragging"); }
});
$("dropzone").addEventListener("dragleave", () => {
  dragDepth = Math.max(0, dragDepth - 1);
  if (!dragDepth) $("dropzone").classList.remove("dragging");
});
$("dropzone").addEventListener("drop", (event) => {
  event.preventDefault();
  if (state.busy) return;
  const items = Array.from(event.dataTransfer.items || []);
  const directories = items.some((item) => item.webkitGetAsEntry?.()?.isDirectory);
  if (directories) { showError("Selecciona los archivos dentro de la carpeta. Esta versión recibe archivos individuales."); return; }
  addFiles(event.dataTransfer.files);
});
$("clear-button").addEventListener("click", () => {
  if (state.busy) return;
  state.files = [];
  resetResult();
  renderFiles();
  showError("");
  announce("Selección vacía.");
});
$("compress-button").addEventListener("click", startCompression);
$("cancel-button").addEventListener("click", cancelCompression);
$("restart-button").addEventListener("click", () => {
  state.files = [];
  resetResult();
  renderFiles();
  showError("");
  $("dropzone").focus();
});
$("download-button").addEventListener("click", async (event) => {
  event.preventDefault();
  const id = state.job;
  if (!id || $("download-button").getAttribute("aria-busy") === "true") return;
  $("download-button").setAttribute("aria-busy", "true");
  try {
    // Check expiry without loading a potentially large ZIP into browser memory.
    const job = await api(`/api/jobs/${encodeURIComponent(id)}`);
    if (state.job !== id) return;
    if (job.state !== "done") throw new Error("Este resultado ya no está disponible. Vuelve a procesar tus archivos.");
    const link = document.createElement("a");
    link.href = `/api/jobs/${encodeURIComponent(id)}/download`;
    link.download = job.archiveName;
    document.body.append(link);
    link.click();
    link.remove();
    announce(currentMode() === "video" ? "Descarga del video iniciada." : "Descarga iniciada. Extrae el ZIP para recuperar tus archivos.");
  } catch (error) {
    if (state.job === id) {
      showError(error instanceof TypeError ? "No hay conexión con Pliegue. Comprueba que la aplicación sigue abierta." : error.message);
      announce("No se pudo iniciar la descarga. Revisa el mensaje de error.");
    }
  } finally {
    $("download-button").removeAttribute("aria-busy");
  }
});
$("how-button").addEventListener("click", () => $("how-dialog").showModal());
$("close-dialog").addEventListener("click", () => $("how-dialog").close());
$("how-dialog").addEventListener("click", (event) => {
  const rect = $("how-dialog").getBoundingClientRect();
  if (event.clientX < rect.left || event.clientX > rect.right || event.clientY < rect.top || event.clientY > rect.bottom) $("how-dialog").close();
});

// Reconnect to compression or a completed ZIP after a page refresh.
async function restoreSession() {
  let id;
  try { id = sessionStorage.getItem(SESSION_KEY); } catch { return; }
  if (!id) return;
  const generation = ++state.generation;
  state.job = id;
  setBusy(true);
  try {
    const job = await api(`/api/jobs/${encodeURIComponent(id)}`);
    if (generation !== state.generation) return;
    setMode(job.mode || "zip");
    if (job.state === "done") { renderDone(job); return; }
    if (["compressing", "verifying"].includes(job.state)) {
      showResult("progress");
      await pollJob(id, generation);
      return;
    }
    resetResult();
    setBusy(false);
    showError("La selección se interrumpió al recargar. Selecciona de nuevo tus archivos para continuar.");
  } catch (error) {
    if (generation !== state.generation) return;
    resetResult();
    setBusy(false);
    showError("El resultado de la sesión anterior ya no está disponible. Selecciona tus archivos para comenzar de nuevo.");
  }
}

document.querySelectorAll('input[name="mode"]').forEach((input) => input.addEventListener("change", () => {
  resetResult(); updateMode(); showError("");
}));
updateMode();
renderFiles();
restoreSession();
api("/api/capabilities").then((result) => { state.videoAvailable = result.video === true; updateMode(); }).catch(() => {
  state.videoAvailable = false;
  state.engineIssue = "Reinicia Pliegue para activar el motor de video: cierra el servidor anterior con Ctrl+C, ejecuta python3 server.py y recarga esta página.";
  updateMode();
});
