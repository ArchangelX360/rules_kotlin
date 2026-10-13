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
"""The wasm-opt and browser toolchains of the Kotlin/WasmJs rules."""

WASM_OPT_TOOLCHAIN_TYPE = "%s" % Label("//kotlin/internal/wasmjs:wasm_opt_toolchain_type")

BROWSER_TOOLCHAIN_TYPE = "%s" % Label("//kotlin/internal/wasmjs:browser_toolchain_type")

# The binaryen release archives and the execution platforms they run on.
_BINARYEN_PLATFORMS = {
    "aarch64-linux": ["@platforms//os:linux", "@platforms//cpu:aarch64"],
    "arm64-macos": ["@platforms//os:macos", "@platforms//cpu:aarch64"],
    "arm64-windows": ["@platforms//os:windows", "@platforms//cpu:aarch64"],
    "x86_64-linux": ["@platforms//os:linux", "@platforms//cpu:x86_64"],
    "x86_64-macos": ["@platforms//os:macos", "@platforms//cpu:x86_64"],
    "x86_64-windows": ["@platforms//os:windows", "@platforms//cpu:x86_64"],
}

def _wasm_opt_toolchain_impl(ctx):
    executables = [f for f in ctx.files.wasm_opt if f.basename in ["wasm-opt", "wasm-opt.exe"]]
    if len(executables) != 1:
        fail("%s: expected exactly one wasm-opt executable among %s" % (ctx.label, ctx.files.wasm_opt))
    return [platform_common.ToolchainInfo(
        wasm_opt = executables[0],
        wasm_opt_files = depset(ctx.files.wasm_opt),
        worker = ctx.attr.worker[DefaultInfo].files_to_run,
    )]

wasm_opt_toolchain = rule(
    doc = """The wasm-opt of binaryen, and the worker that runs it over a linked Kotlin/WasmJs
      directory. The worker and wasm-opt are in one toolchain, so they get the same execution
      platform.""",
    attrs = {
        "wasm_opt": attr.label(
            doc = "The wasm-opt executable, and the files it loads next to it.",
            mandatory = True,
            allow_files = True,
            cfg = "exec",
        ),
        "worker": attr.label(
            doc = "The worker that runs wasm-opt.",
            default = Label("//src/main/kotlin:wasm_opt"),
            executable = True,
            cfg = "exec",
        ),
    },
    implementation = _wasm_opt_toolchain_impl,
)

# The chromium headless shell archives and the target platforms they run on. Playwright publishes
# no arm64 Windows build, so Windows on arm64 runs the x64 build under emulation.
_CHROMIUM_HEADLESS_SHELL_PLATFORMS = {
    "aarch64-linux": ("aarch64-linux", ["@platforms//os:linux", "@platforms//cpu:aarch64"]),
    "arm64-macos": ("arm64-macos", ["@platforms//os:macos", "@platforms//cpu:aarch64"]),
    "arm64-windows": ("x86_64-windows", ["@platforms//os:windows", "@platforms//cpu:aarch64"]),
    "x86_64-linux": ("x86_64-linux", ["@platforms//os:linux", "@platforms//cpu:x86_64"]),
    "x86_64-macos": ("x86_64-macos", ["@platforms//os:macos", "@platforms//cpu:x86_64"]),
    "x86_64-windows": ("x86_64-windows", ["@platforms//os:windows", "@platforms//cpu:x86_64"]),
}

def _browser_toolchain_impl(ctx):
    return [platform_common.ToolchainInfo(
        executable = ctx.file.executable,
        files = depset(ctx.files.files),
    )]

browser_toolchain = rule(
    doc = "The headless browser that kt_wasmjs_test runs the tests in.",
    attrs = {
        "executable": attr.label(
            doc = "The browser executable.",
            mandatory = True,
            allow_single_file = True,
        ),
        "files": attr.label(
            doc = "The executable, and every file it loads from its own directory at startup.",
            mandatory = True,
            allow_files = True,
        ),
    },
    implementation = _browser_toolchain_impl,
)

# buildifier: disable=unnamed-macro
def wasmjs_configure_toolchains():
    """Defines one wasm-opt toolchain per binaryen release archive, and one browser toolchain per
    target platform of the chromium headless shell archives.

    Must be called in kotlin/internal/wasmjs/toolchains.
    """
    if native.package_name() != "kotlin/internal/wasmjs/toolchains":
        fail("wasmjs_configure_toolchains must be called in kotlin/internal/wasmjs/toolchains not %s" % native.package_name())

    for platform, constraints in _BINARYEN_PLATFORMS.items():
        wasm_opt_toolchain(
            name = "wasm_opt_%s_impl" % platform,
            wasm_opt = "@binaryen_%s//:wasm-opt" % platform,
        )
        native.toolchain(
            name = "wasm_opt_%s" % platform,
            exec_compatible_with = constraints,
            toolchain = ":wasm_opt_%s_impl" % platform,
            toolchain_type = WASM_OPT_TOOLCHAIN_TYPE,
        )

    for platform, (archive, constraints) in _CHROMIUM_HEADLESS_SHELL_PLATFORMS.items():
        browser_toolchain(
            name = "browser_%s_impl" % platform,
            executable = "@chromium_headless_shell_%s//:headless-shell" % archive,
            files = "@chromium_headless_shell_%s//:files" % archive,
        )
        native.toolchain(
            name = "browser_%s" % platform,
            target_compatible_with = constraints,
            toolchain = ":browser_%s_impl" % platform,
            toolchain_type = BROWSER_TOOLCHAIN_TYPE,
        )
