// Verifies ⌥-drag alignment snapping in Story Studio:
//  A) ⌥-drag dropped within threshold of the screen centre snaps exactly to centre
//     and shows amber screen-centre guides; B) ⌥-click (no move) still routes to the
//     overlap picker (selects, no move, no guide); C) a plain drag (no ⌥) to the same
//     near-centre spot does NOT snap (snapping is opt-in); D) ⌥-drag aligning the
//     circle's centreX to the Title shows a magenta element guide and lands aligned.
// Each case starts from a fresh document so the circle is isolated at its starter
// spot (after a snap-to-centre it overlaps the Title, and a re-press would hit-test
// the Title on top). Box-centre reads subtract the +2px .stage-selection inset bias.
// Run: `bun bunserver.js` then `bun scripts/verify-altsnap.mjs`.
import puppeteer from "puppeteer-core";

const CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const URL = `http://localhost:${process.env.PORT || 3000}/studio.html`;
const BIAS = 2; // .stage-selection grows 16px but margins back only 12px → centre +2px

const browser = await puppeteer.launch({
  executablePath: CHROME, headless: true,
  args: ["--headless=new", "--use-angle=metal", "--enable-unsafe-webgpu", "--enable-features=Vulkan", "--no-sandbox"],
});
const page = await browser.newPage();
await page.setViewport({ width: 1280, height: 760, deviceScaleFactor: 2 });
const logs = [];
page.on("console", (m) => logs.push(m.text()));
page.on("pageerror", (e) => logs.push("PAGEERROR " + e.message));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

await page.goto(URL, { waitUntil: "networkidle0", timeout: 30000 });
async function freshLoad() {
  await page.evaluate(() => localStorage.clear());
  await page.reload({ waitUntil: "networkidle0", timeout: 30000 });
  await sleep(2600);  // boot MathJax + runtime + first render
}

const results = [];
const check = (name, ok, detail = "") => { results.push({ ok }); console.log(`${ok ? "✅" : "❌"} ${name}${detail ? " — " + detail : ""}`); };

// One synthetic pointer gesture on the canvas, stepped so each move clears the slop.
// Captures the guide DOM while held; returns selection-box centres (un-biased) and
// the guide snapshot. `alt` toggles ⌥.
async function gesture({ from, to, alt }) {
  return await page.evaluate(async ({ from, to, alt, BIAS }) => {
    const canvas = document.querySelector("canvas#main");
    const boxCenter = () => {
      const b = [...document.querySelectorAll(".stage-selection")].find((e) => getComputedStyle(e).display !== "none");
      if (!b) return null;
      const r = b.getBoundingClientRect();
      return { x: (r.left + r.right) / 2 - BIAS, y: (r.top + r.bottom) / 2 - BIAS };
    };
    const ev = (type, x, y) => canvas.dispatchEvent(new PointerEvent(type, {
      clientX: x, clientY: y, altKey: alt, bubbles: true, view: window,
      pointerId: 1, pointerType: "mouse", button: 0, buttons: 1,
    }));
    const nap = (ms) => new Promise((r) => setTimeout(r, ms));

    const before = boxCenter();
    ev("pointerdown", from.x, from.y);
    await nap(30);
    for (let i = 1; i <= 4; i++) {
      ev("pointermove", from.x + (to.x - from.x) * i / 4, from.y + (to.y - from.y) * i / 4);
      await nap(25);
    }
    const guides = [...document.querySelectorAll(".stage-guide")]
      .filter((g) => getComputedStyle(g).display !== "none")
      .map((g) => { const r = g.getBoundingClientRect(); return { screen: g.classList.contains("stage-guide-screen"), w: r.width, h: r.height }; });
    ev("pointerup", to.x, to.y);
    await nap(350);
    const after = boxCenter();
    const guidesAfter = [...document.querySelectorAll(".stage-guide")].filter((g) => getComputedStyle(g).display !== "none").length;
    return { before, after, guides, guidesAfter };
  }, { from, to, alt, BIAS });
}

const selectInList = (name) => page.evaluate((name) => {
  const row = [...document.querySelectorAll("#studio-inspector .elem-row")].find((r) => r.textContent.trim() === name);
  row?.dispatchEvent(new MouseEvent("click", { bubbles: true }));
  return !!row;
}, name);
const boxCenterNow = () => page.evaluate((BIAS) => {
  const b = [...document.querySelectorAll(".stage-selection")].find((e) => getComputedStyle(e).display !== "none");
  if (!b) return null;
  const r = b.getBoundingClientRect();
  return { x: (r.left + r.right) / 2 - BIAS, y: (r.top + r.bottom) / 2 - BIAS };
}, BIAS);
const canvasCenter = () => page.evaluate(() => {
  const r = document.querySelector("canvas#main").getBoundingClientRect();
  return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
});

// Selects the circle and returns the press point (its current box centre).
async function circleStart() { await selectInList("Circle"); await sleep(300); return await boxCenterNow(); }

// ---- A) ⌥-drag snaps to the screen centre + amber guides --------------------
await freshLoad();
const center = await canvasCenter();
let c = await circleStart();
const A = await gesture({ from: { x: c.x + BIAS, y: c.y + BIAS }, to: { x: center.x + 5, y: center.y + 5 }, alt: true });
const Aoff = Math.hypot(A.after.x - center.x, A.after.y - center.y);
check("A1 ⌥-drop near centre snaps box centre onto the screen centre (<1.5px)", Aoff < 1.5, `off=${Aoff.toFixed(2)}px`);
check("A2 amber screen-centre guide(s) shown while dragging", A.guides.length > 0 && A.guides.every((g) => g.screen), `guides=${JSON.stringify(A.guides)}`);
check("A3 guides cleared on pointer-up", A.guidesAfter === 0, `after=${A.guidesAfter}`);

// ---- B) ⌥-click (no move) selects via the picker, does not move -------------
await freshLoad();
c = await circleStart();
const B = await gesture({ from: { x: c.x + BIAS, y: c.y + BIAS }, to: { x: c.x + BIAS, y: c.y + BIAS }, alt: true });
const Bmoved = Math.hypot(B.after.x - c.x, B.after.y - c.y);
check("B1 ⌥-click does not move the element", Bmoved < 1.0, `moved=${Bmoved.toFixed(2)}px`);
check("B2 ⌥-click shows no guides", B.guides.length === 0, `guides=${B.guides.length}`);

// ---- C) plain drag to the same near-centre spot does NOT snap (opt-in) ------
await freshLoad();
const center2 = await canvasCenter();
c = await circleStart();
const C = await gesture({ from: { x: c.x + BIAS, y: c.y + BIAS }, to: { x: center2.x + 5, y: center2.y + 5 }, alt: false });
const Coff = Math.hypot(C.after.x - center2.x, C.after.y - center2.y);
check("C1 plain drop near centre does NOT snap (stays off)", Coff > 2.5, `off=${Coff.toFixed(2)}px`);
check("C2 plain drag shows no guides", C.guides.length === 0, `guides=${C.guides.length}`);

// ---- D) ⌥-drag aligns circle centreX to the Title → magenta element guide ---
await freshLoad();
await selectInList("Title");
await sleep(300);
const titleC = await boxCenterNow();
c = await circleStart();
const D = await gesture({ from: { x: c.x + BIAS, y: c.y + BIAS }, to: { x: titleC.x + 4, y: c.y }, alt: true });
const Dx = Math.abs(D.after.x - titleC.x);
check("D1 ⌥-drag snaps circle centreX onto the Title centreX (<1.5px)", Dx < 1.5, `dx=${Dx.toFixed(2)}px`);
check("D2 a magenta element-align guide is shown", D.guides.some((g) => !g.screen), `guides=${JSON.stringify(D.guides)}`);

// ---- E) overlap picker still works (deferred to ⌥-click-no-move) ------------
// Plain-drag the circle onto the Title so they overlap, then ⌥-click the stack and
// confirm the radial picker rises — guards that moving the picker trigger from
// pointer-down to pointer-up-no-move didn't kill it.
await freshLoad();
await selectInList("Title");
await sleep(300);
const titleC2 = await boxCenterNow();
c = await circleStart();
await gesture({ from: { x: c.x + BIAS, y: c.y + BIAS }, to: { x: titleC2.x + BIAS, y: titleC2.y + BIAS }, alt: false }); // overlap
await sleep(300);
const ring = await page.evaluate(async ({ titleC2, BIAS }) => {
  const canvas = document.querySelector("canvas#main");
  const ev = (type) => canvas.dispatchEvent(new PointerEvent(type, {
    clientX: titleC2.x + BIAS, clientY: titleC2.y + BIAS, altKey: true, bubbles: true, view: window,
    pointerId: 1, pointerType: "mouse", button: 0, buttons: 1,
  }));
  ev("pointerdown"); await new Promise((r) => setTimeout(r, 30)); ev("pointerup");
  await new Promise((r) => setTimeout(r, 250));
  const scrim = document.querySelector(".stage-radial-scrim");
  const chips = document.querySelectorAll(".stage-radial-item:not(.stage-radial-more)").length;
  return { shown: scrim && getComputedStyle(scrim).display !== "none", chips };
}, { titleC2, BIAS });
check("E1 ⌥-click on an overlap raises the radial picker", ring.shown, `shown=${ring.shown}`);
check("E2 picker lists both overlapping elements", ring.chips >= 2, `chips=${ring.chips}`);

console.log("\n--- page errors ---");
console.log(logs.filter((l) => /pageerror/i.test(l)).slice(-6).join("\n") || "(none)");
const passed = results.filter((r) => r.ok).length;
console.log(`\nRESULT: ${passed}/${results.length} checks passed`);
await browser.close();
process.exit(passed === results.length ? 0 : 1);
