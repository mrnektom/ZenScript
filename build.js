import {build} from "zig-build"

/** @type import(zig-build).Target */
const config = {
    sources: ["src/root.zig"],
    std: "c++17",
}

await build({
    "linux-x64": {
        ...config,
        target: "x86_64-linux-gnu",
        output: "dist/linux-x64/addon.node",
    }
})