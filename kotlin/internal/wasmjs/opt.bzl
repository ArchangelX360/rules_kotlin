# Copyright 2026 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
"""The wasm-opt action of kt_wasmjs_binary."""

load("//kotlin/internal:defs.bzl", _TOOLCHAIN_TYPE = "TOOLCHAIN_TYPE")
load("//kotlin/internal/utils:utils.bzl", _utils = "utils")
load(":toolchains.bzl", "WASM_OPT_TOOLCHAIN_TYPE")

# The default wasm-opt arguments of the Kotlin Gradle plugin: BinaryenConfig.binaryenCommonArgs
# and binaryenMultimoduleArgs. The plugin selects these when the link gives more than one wasm
# module, the closed-world multimodule case. They come from kotlin-gradle-plugin 2.4.10-RC2. Keep
# them on the compiler release, as the binaryen version in versions.bzl.
_KGP_BINARYEN_MULTIMODULE_ARGS = [
    "--enable-gc",
    "--enable-reference-types",
    "--enable-exception-handling",
    "--enable-bulk-memory",
    "--enable-nontrapping-float-to-int",
    "--no-inline=kotlin.wasm.internal.throwValue",
    "--no-inline=kotlin.wasm.internal.getKotlinException",
    "--no-inline=kotlin.wasm.internal.jsToKotlinStringAdapter",
    "--inline-functions-with-loops",
    "--traps-never-happen",
    "--fast-math",
    "-O3",
    "-O3",
    "-O3",
]

def wasm_opt_action(ctx, linked_dir, output_prefix):
    """Registers the WasmOptWasmJs action running binaryen's wasm-opt over every .wasm file of `linked_dir`.

    Args:
        ctx: the rule context. The rule must declare the wasm-opt toolchain type.
        linked_dir: the output directory of the link.
        output_prefix: the prefix of the declared output directories.

    Returns:
        struct(
            optimized_directory: `<output_prefix>-optimized`, the linked directory with every .wasm
                optimized, and the other files copied through.
            functions_map_directory: `<output_prefix>-functions-map`, the symbol map of each wasm
                file (wasm-opt --symbolmap), named `<wasm basename without extension>.txt`.
        )
    """
    toolchain = ctx.toolchains[WASM_OPT_TOOLCHAIN_TYPE]
    if toolchain == None:
        fail("%s: no wasm-opt toolchain matches the execution platform. Set optimize = \"off\", or register a wasm_opt_toolchain." % ctx.label)

    optimized_dir = ctx.actions.declare_directory("%s-optimized" % output_prefix)
    functions_map_dir = ctx.actions.declare_directory("%s-functions-map" % output_prefix)

    args = ctx.actions.args()
    args.set_param_file_format("multiline")
    args.use_param_file("--flagfile=%s", use_always = True)
    args.add("--input-directory=%s" % linked_dir.path)
    args.add("--output-directory=%s" % optimized_dir.path)
    args.add("--functions-map-directory=%s" % functions_map_dir.path)
    args.add("--wasm-opt=%s" % toolchain.wasm_opt.path)
    args.add_all(_KGP_BINARYEN_MULTIMODULE_ARGS, format_each = "--wasm-opt-arg=%s")

    ctx.actions.run(
        mnemonic = "WasmOptWasmJs",
        inputs = [linked_dir],
        outputs = [optimized_dir, functions_map_dir],
        tools = [toolchain.worker, toolchain.wasm_opt_files],
        executable = toolchain.worker.executable,
        execution_requirements = _utils.add_dicts(
            ctx.toolchains[_TOOLCHAIN_TYPE].execution_requirements,
            {
                "supports-worker-cancellation": "1",
                "worker-key-mnemonic": "WasmOptWasmJs",
            },
        ),
        arguments = [args],
        progress_message = "Optimizing Kotlin/WasmJs modules %{label}",
        toolchain = WASM_OPT_TOOLCHAIN_TYPE,
    )

    return struct(
        optimized_directory = optimized_dir,
        functions_map_directory = functions_map_dir,
    )
