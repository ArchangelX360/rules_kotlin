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
"""The browser toolchains of the Kotlin/WasmJs rules."""

BROWSER_TOOLCHAIN_TYPE = "%s" % Label("//kotlin/internal/wasmjs:browser_toolchain_type")

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
    """Defines one browser toolchain per target platform of the chromium headless shell archives.

    Must be called in kotlin/internal/wasmjs/toolchains.
    """
    if native.package_name() != "kotlin/internal/wasmjs/toolchains":
        fail("wasmjs_configure_toolchains must be called in kotlin/internal/wasmjs/toolchains not %s" % native.package_name())

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
