// GPU-free smoke for the Story Studio bundle: instantiate under Bun (no DOM,
// no GPU) and let the Swift entry log the compiled story structure. Build first:
//   swift package --swift-sdk 6.3-SNAPSHOT-2026-06-11-a-wasm32-unknown-wasip1-threads \
//     --allow-writing-to-directory js-studio js --use-cdn \
//     --output js-studio --product StoryStudio
import { instantiate } from "../js-studio/instantiate.js";
import { defaultNodeSetup } from "../js-studio/platforms/node.js";

const options = await defaultNodeSetup({});
await instantiate(options);
// Give the JS event loop a beat for the Swift Task (font probe + compile) to run.
await new Promise((resolve) => setTimeout(resolve, 1200));
