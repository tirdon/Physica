// Physica dev server — static files with the headers SwiftWasm threads need.
// wasip1-threads uses SharedArrayBuffer, which requires crossOriginIsolated === true,
// hence the COOP/COEP headers on every response.
//
// Run: bun bunserver.js   →   http://localhost:3000

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".json": "application/json",
  ".wasm": "application/wasm",
  ".css": "text/css; charset=utf-8",
  ".ttf": "font/ttf",
  ".otf": "font/otf",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".map": "application/json",
};

let port = parseInt(process.env.PORT || 3000);
let server;

while (true) {
  try {
    server = Bun.serve({
      port,
      async fetch(req) {
        let path = decodeURIComponent(new URL(req.url).pathname);
        if (path === "/") path = "/index.html";
        if (path.includes("..")) return new Response("Forbidden", { status: 403 });

        const file = Bun.file(import.meta.dir + path);
        if (!(await file.exists())) return new Response("Not found: " + path, { status: 404 });

        const ext = path.slice(path.lastIndexOf("."));
        return new Response(file, {
          headers: {
            "Content-Type": MIME[ext] ?? "application/octet-stream",
            "Cross-Origin-Opener-Policy": "same-origin",
            "Cross-Origin-Embedder-Policy": "require-corp",
            "Cross-Origin-Resource-Policy": "cross-origin",
            "Cache-Control": "no-store",
          },
        });
      },
    });
    break;
  } catch (err) {
    if (err.code === "EADDRINUSE") {
      port++;
    } else {
      throw err;
    }
  }
}

console.log(`Physica dev server: http://localhost:${server.port}`);
