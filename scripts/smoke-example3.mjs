// GPU-free smoke for the Example3 article bundle: instantiate under Bun (no DOM,
// no GPU) and assert the Swift entry logged the article outline. With no DOM the
// renderer no-ops and the `@main` prints the outline, then exits cleanly. Build
// the bundle first:
//   swift package --swift-sdk 6.3-SNAPSHOT-2026-06-11-a-wasm32-unknown-wasip1-threads \
//     --allow-writing-to-directory js-example3 js --use-cdn \
//     --output js-example3 --product Example3
import { instantiate } from "../js-example3/instantiate.js";
import { defaultNodeSetup } from "../js-example3/platforms/node.js";

// WASI stdout is line-buffered onto console.log by the node platform shim, so
// capture there to assert on the printed outline.
let captured = "";
const origLog = console.log.bind(console);
console.log = (...args) => {
  captured += args.join(" ") + "\n";
  origLog(...args);
};

const options = await defaultNodeSetup({});
await instantiate(options);
// Give the JS event loop a beat for the Swift Task (build + print) to run.
await new Promise((resolve) => setTimeout(resolve, 1200));

console.log = origLog;

const expected = [
  "Physics · Rigid bodies — article outline",
  "Title: A rigid body, integrated the Hamiltonian way",
  "§1 Chapter: The state you actually store",
  "math(equation) (1) tag=velocities",
  "procedure: Procedure 1",
  "presentation: 3 slides",
  "Footer (2 lines)",
];
const missing = expected.filter((needle) => !captured.includes(needle));
if (missing.length > 0) {
  console.error("smoke-example3: FAIL — outline missing:", JSON.stringify(missing));
  process.exit(1);
}
console.log("smoke-example3: OK — article outline printed (all markers present).");
