// Headless-WebGPU screenshots of example0.html (the wave-interference story).
// Run: `bun bunserver.js` then `bun scripts/shot-example0.mjs`.
import puppeteer from "puppeteer-core";
import { mkdirSync } from "node:fs";

const CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const URL = "http://localhost:3000/example0.html";
const OUT = "/tmp/physica-ex0-shots";
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
  await new Promise((r) => setTimeout(r, 1700));
  const caption = await page.$eval("#story-caption", (e) => e.textContent).catch(() => "");
  const hud = await page.$eval("#story-hud", (e) => e.textContent).catch(() => "");
  await page.screenshot({ path: `${OUT}/${name}.png` });
  console.log(`shot ${name}: hud="${hud}" caption="${caption}"`);
}

// ArrowDown jumps to the next slide's fully-built state, but tweens to get there
// (slow for long slides). Press, then poll the HUD until it names the target slide
// before settling and shooting.
async function downTo(name, expectSlide) {
  await page.keyboard.press("ArrowDown");
  for (let i = 0; i < 60; i++) {
    const hud = await page.$eval("#story-hud", (e) => e.textContent).catch(() => "");
    if (hud.includes(expectSlide)) break;
    await new Promise((r) => setTimeout(r, 200));
  }
  await new Promise((r) => setTimeout(r, 1800)); // settle tween + in-slide draws
  await shot(name);
}

await page.bringToFront();
await page.mouse.click(500, 40);
await new Promise((r) => setTimeout(r, 400));
await shot("0-start");
await downTo("1-title", "Title");
await downTo("2-string", "The string");
await downTo("3-grid", "The grid");
await downTo("4-twoD", "Two dimensions");
await downTo("5-interference", "Interference");

console.log("\n--- console (filtered) ---");
console.log(logs.filter((l) => /Physica|error|webGPU|story|size/i.test(l)).slice(-25).join("\n"));
await browser.close();
