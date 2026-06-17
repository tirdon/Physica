// End-to-end verification of the Story Studio editor additions:
// toolbar groups · ⌘ multi-select · Shift disables debug overlay ·
// camera zoom (Cmd +/-/0) · double-click-empty adds text · Shift+Enter newline ·
// hold-H help sheet. Run: `bun bunserver.js` then `bun scripts/verify-studio-features.mjs`.
import puppeteer from "puppeteer-core";
import { mkdirSync } from "node:fs";

const CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const PORT = process.env.PORT || 3000;
const URL = `http://localhost:${PORT}/studio.html`;
const OUT = "/tmp/physica-studio-shots";
mkdirSync(OUT, { recursive: true });

const browser = await puppeteer.launch({
  executablePath: CHROME, headless: true,
  args: ["--headless=new", "--use-angle=metal", "--enable-unsafe-webgpu", "--enable-features=Vulkan", "--no-sandbox"],
});
const page = await browser.newPage();
await page.setViewport({ width: 1280, height: 760, deviceScaleFactor: 2 });
const logs = [];
page.on("console", (m) => logs.push(m.text()));
page.on("pageerror", (e) => logs.push("PAGEERROR " + e.message));

await page.goto(URL, { waitUntil: "networkidle0", timeout: 30000 });
await page.evaluate(() => localStorage.clear());
await page.reload({ waitUntil: "networkidle0", timeout: 30000 });
for (let i = 0; i < 60; i++) {
  if (logs.some((l) => /story runtime running|renderer unavailable/.test(l))) break;
  await new Promise((r) => setTimeout(r, 250));
}
await new Promise((r) => setTimeout(r, 1800));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const results = [];
const check = (name, ok, detail = "") => { results.push({ name, ok }); console.log(`${ok ? "✅" : "❌"} ${name}${detail ? " — " + detail : ""}`); };

// 1) Toolbar groups
const toolbar = await page.evaluate(() => {
  const labels = [...document.querySelectorAll("#studio-toolbar .studio-group-label")].map((e) => e.textContent);
  const btns = [...document.querySelectorAll("#studio-toolbar button")].map((b) => b.textContent.trim());
  return { labels, btns };
});
check("toolbar groups labelled Geometry/Text/Actions",
  JSON.stringify(toolbar.labels) === JSON.stringify(["Geometry", "Text", "Actions"]), toolbar.labels.join(","));
check("geometry order Tri,Circle,Rect then Text,Math",
  /Tri/.test(toolbar.btns[0]) && /Circle/.test(toolbar.btns[1]) && /Rect/.test(toolbar.btns[2])
  && /Text/.test(toolbar.btns[3]) && /Math/.test(toolbar.btns[4]));
await page.screenshot({ path: `${OUT}/feat-0-toolbar.png` });

// 2) Hold-H help sheet
const help = await page.evaluate(() => {
  window.dispatchEvent(new KeyboardEvent("keydown", { key: "h", bubbles: true }));
  const shown = document.querySelector("#help-sheet").classList.contains("show");
  return { shown };
});
await sleep(150);
await page.screenshot({ path: `${OUT}/feat-1-help.png` });
const helpHidden = await page.evaluate(() => {
  window.dispatchEvent(new KeyboardEvent("keyup", { key: "h", bubbles: true }));
  return !document.querySelector("#help-sheet").classList.contains("show");
});
check("hold H shows help sheet", help.shown);
check("release H hides help sheet", helpHidden);

// 3) Multi-select via the inspector list (⌘ toggles)
const multi = await page.evaluate(() => {
  const rows = [...document.querySelectorAll("#studio-inspector .elem-row")];
  const circle = rows.find((r) => r.textContent.trim() === "Circle");
  const title = rows.find((r) => r.textContent.trim() === "Title");
  circle.dispatchEvent(new MouseEvent("click", { bubbles: true }));                // plain → just Circle
  title.dispatchEvent(new MouseEvent("click", { bubbles: true, metaKey: true }));  // ⌘ → add Title
  return true;
});
await sleep(500);
const multiState = await page.evaluate(() => {
  const boxes = [...document.querySelectorAll(".stage-selection")].filter((b) => getComputedStyle(b).display !== "none");
  const note = [...document.querySelectorAll("#studio-inspector .panel-empty, #studio-inspector .inspector-sub")]
    .map((e) => e.textContent).join(" | ");
  return { boxes: boxes.length, note };
});
check("⌘-click selects 2 → two selection boxes", multiState.boxes === 2, `boxes=${multiState.boxes}`);
check("inspector shows multi count", /2 elements selected/.test(multiState.note), multiState.note);
await page.screenshot({ path: `${OUT}/feat-2-multiselect.png` });
// plain click collapses back to one
const single = await page.evaluate(() => {
  const circle = [...document.querySelectorAll("#studio-inspector .elem-row")].find((r) => r.textContent.trim() === "Circle");
  circle.dispatchEvent(new MouseEvent("click", { bubbles: true }));
  return true;
});
await sleep(400);
const singleBoxes = await page.evaluate(() =>
  [...document.querySelectorAll(".stage-selection")].filter((b) => getComputedStyle(b).display !== "none").length);
check("plain click collapses to 1 box", singleBoxes === 1, `boxes=${singleBoxes}`);

// 4) Shift no longer raises the framework debug overlay (the reported drag bug is moot)
const overlayCount = await page.evaluate(async () => {
  window.dispatchEvent(new KeyboardEvent("keydown", { key: "Shift", shiftKey: true, bubbles: true }));
  await new Promise((r) => setTimeout(r, 250));
  const n = document.querySelectorAll(".overlay-label").length;
  window.dispatchEvent(new KeyboardEvent("keyup", { key: "Shift", bubbles: true }));
  return n;
});
check("holding Shift shows NO debug overlay (repurposed for move-drag)", overlayCount === 0, `labels=${overlayCount}`);

// 5) Camera zoom (Cmd +/-/0) — visual; capture before/after
await page.screenshot({ path: `${OUT}/feat-3a-zoom-default.png` });
await page.evaluate(() => {
  for (let i = 0; i < 3; i++) window.dispatchEvent(new KeyboardEvent("keydown", { key: "=", metaKey: true, bubbles: true }));
});
await sleep(500);
await page.screenshot({ path: `${OUT}/feat-3b-zoom-in.png` });
await page.evaluate(() => window.dispatchEvent(new KeyboardEvent("keydown", { key: "0", metaKey: true, bubbles: true })));
await sleep(500);
await page.screenshot({ path: `${OUT}/feat-3c-zoom-reset.png` });
check("camera zoom shortcuts dispatched without error", !logs.some((l) => /PAGEERROR/.test(l)));

// 6) Double-click empty space adds a text element + opens editor
const beforeCount = await page.evaluate(() => document.querySelectorAll("#studio-inspector .elem-row").length);
const dcAdd = await page.evaluate(() => {
  const canvas = document.querySelector("canvas#main");
  const r = canvas.getBoundingClientRect();
  // lower-left quadrant — clear of the centre elements, toolbar, and caption band.
  const cx = r.left + r.width * 0.22, cy = r.top + r.height * 0.30;
  canvas.dispatchEvent(new MouseEvent("dblclick", { clientX: cx, clientY: cy, bubbles: true, view: window }));
  const ed = document.querySelector(".stage-text-editor");
  return { editorOpen: ed && getComputedStyle(ed).display !== "none", value: ed ? ed.value : null };
});
await sleep(600);
const dcCommitted = await page.evaluate(() => {
  const ed = document.querySelector(".stage-text-editor");
  ed.focus(); ed.value = "Added!";
  ed.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
  return true;
});
await sleep(1200);
const afterCount = await page.evaluate(() => document.querySelectorAll("#studio-inspector .elem-row").length);
check("double-click empty space opens a text editor", dcAdd.editorOpen, `value="${dcAdd.value}"`);
check("…and commits a new element", afterCount === beforeCount + 1, `${beforeCount}→${afterCount}`);
await page.screenshot({ path: `${OUT}/feat-4-dblclick-add.png` });

// 7) Shift+Enter inserts a newline (editor stays open); plain Enter commits a 2-line value
const shiftEnter = await page.evaluate(async () => {
  // Re-open the editor on the new "Added!" text by double-clicking its selection box.
  const added = [...document.querySelectorAll("#studio-inspector .elem-row")].find((r) => /Text/.test(r.textContent));
  added.dispatchEvent(new MouseEvent("click", { bubbles: true }));
  await new Promise((r) => setTimeout(r, 300));
  const box = document.querySelector(".stage-selection");
  const canvas = document.querySelector("canvas#main");
  const b = box.getBoundingClientRect();
  canvas.dispatchEvent(new MouseEvent("dblclick", { clientX: (b.left + b.right) / 2, clientY: (b.top + b.bottom) / 2, bubbles: true, view: window }));
  await new Promise((r) => setTimeout(r, 300));
  const ed = document.querySelector(".stage-text-editor");
  if (!ed || getComputedStyle(ed).display === "none") return { ok: false, why: "editor didn't open" };
  ed.focus();
  ed.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", shiftKey: true, bubbles: true }));
  const stillOpen = getComputedStyle(ed).display !== "none";
  // Put a real two-line value in and commit with plain Enter.
  ed.value = "Two\nLines";
  ed.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
  return { ok: true, stillOpen };
});
await sleep(1000);
const editorGone = await page.evaluate(() => {
  const ed = document.querySelector(".stage-text-editor");
  return !ed || getComputedStyle(ed).display === "none";
});
check("Shift+Enter keeps the editor open (newline, not commit)", shiftEnter.ok && shiftEnter.stillOpen, JSON.stringify(shiftEnter));
check("plain Enter then commits and closes the editor", editorGone);
await page.screenshot({ path: `${OUT}/feat-5-multiline.png` });

console.log("\n--- console errors ---");
console.log(logs.filter((l) => /error|pageerror|unavailable/i.test(l)).slice(-12).join("\n") || "(none)");
const passed = results.filter((r) => r.ok).length;
console.log(`\nRESULT: ${passed}/${results.length} checks passed`);
await browser.close();
process.exit(passed === results.length ? 0 : 1);
