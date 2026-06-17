// Headless-WebGPU screenshots of studio.html (the Story Studio stage).
// Run: `bun bunserver.js` then `bun scripts/shot-studio.mjs`.
import puppeteer from "puppeteer-core";
import { mkdirSync } from "node:fs";

const CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const PORT = process.env.PORT || 3000;
const URL = `http://localhost:${PORT}/studio.html`;
const OUT = "/tmp/physica-studio-shots";
mkdirSync(OUT, { recursive: true });

const browser = await puppeteer.launch({
  executablePath: CHROME,
  headless: true,
  args: ["--headless=new", "--use-angle=metal", "--enable-unsafe-webgpu", "--enable-features=Vulkan", "--no-sandbox"],
});
const page = await browser.newPage();
await page.setViewport({ width: 1000, height: 640, deviceScaleFactor: 2 });

const logs = [];
page.on("console", (m) => logs.push(m.text()));
page.on("pageerror", (e) => logs.push("PAGEERROR " + e.message));

await page.goto(URL, { waitUntil: "networkidle0", timeout: 30000 });
for (let i = 0; i < 60; i++) {
  if (logs.some((l) => /story runtime running|renderer unavailable/.test(l))) break;
  await new Promise((r) => setTimeout(r, 250));
}
await new Promise((r) => setTimeout(r, 1800));

async function shot(name) {
  await new Promise((r) => setTimeout(r, 1200));
  const hud = await page.$eval("#story-hud", (e) => e.textContent).catch(() => "");
  const caption = await page.$eval("#story-caption", (e) => e.textContent).catch(() => "");
  await page.screenshot({ path: `${OUT}/${name}.png` });
  console.log(`shot ${name}: hud="${hud}" caption="${caption}"`);
}

await page.bringToFront();
await page.evaluate(() => localStorage.clear());

async function clickSel(sel, nth = 0) {
  await page.evaluate((s, n) => {
    const els = document.querySelectorAll(s);
    if (els[n]) els[n].click();
  }, sel, nth);
  await new Promise((r) => setTimeout(r, 800));
}

await shot("0-start");
// Toolbar groups (button DOM order): Geometry[0 Tri,1 Circle,2 Rect], Text[3 Text,4 Math], Actions[Play Undo Redo Export].
await clickSel("#studio-toolbar button", 4);         // +ƒ Math → Euler's identity
await new Promise((r) => setTimeout(r, 1500));        // MathJax render + recompile
await shot("1-math");                                // formula rendered on the stage
// Move it to clear space so it reads cleanly, via the inspector.
await page.evaluate(() => {
  const props = [...document.querySelectorAll("#studio-inspector .prop")];
  const setNum = (label, val) => {
    const f = props.find((p) => p.querySelector("span") && p.querySelector("span").textContent === label);
    const i = f && f.querySelector("input");
    if (i) { i.value = val; i.dispatchEvent(new Event("change", { bubbles: true })); }
  };
  setNum("Y", "-1.6");
});
await new Promise((r) => setTimeout(r, 900));
await shot("2-math-moved");

console.log("\n--- console (filtered) ---");
console.log(logs.filter((l) => /Physica|error|webGPU|story|size/i.test(l)).slice(-25).join("\n"));
await browser.close();
