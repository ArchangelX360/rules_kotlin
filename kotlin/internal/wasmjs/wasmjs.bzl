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
"""Kotlin/WasmJs rule definitions."""

load(
    "//kotlin/internal:defs.bzl",
    _KtCompilerPluginInfo = "KtCompilerPluginInfo",
    _KtJvmInfo = "KtJvmInfo",
    _KtPluginConfiguration = "KtPluginConfiguration",
    _TOOLCHAIN_TYPE = "TOOLCHAIN_TYPE",
)
load("//kotlin/internal:opts.bzl", "KotlincOptions")
load(
    ":compile.bzl",
    "merged_npm_packages",
    "npm_package_entries",
    "wasmjs_compile_actions",
    "wasmjs_link_action",
)
load(":opt.bzl", "wasm_opt_action")
load(":providers.bzl", "KtWasmJsBinaryInfo", "KtWasmJsInfo")
load(":toolchains.bzl", "WASM_OPT_TOOLCHAIN_TYPE")

_KOTLINC_OPTS_ATTR = attr.label(
    doc = """Kotlin compiler options for this target. Without it, the target uses the
      `kotlinc_options` of the toolchain. The options that only the Kotlin/JVM compiler accepts
      are left out.""",
    providers = [KotlincOptions],
)

def _kt_wasmjs_library_impl(ctx):
    return wasmjs_compile_actions(ctx)

kt_wasmjs_library = rule(
    doc = """Compiles Kotlin sources into a Kotlin/WasmJs klib. `kt_wasmjs_binary` links it.

The sources come from `srcs`, or from `fragment_sources` for a multiplatform compilation with
fragments. The two attributes are exclusive.""",
    attrs = {
        "data": attr.label_list(
            doc = "The files needed by this target at runtime.",
            allow_files = True,
        ),
        "deps": attr.label_list(
            doc = "The libraries on the compiler library path of this target.",
            providers = [KtWasmJsInfo],
        ),
        "exports": attr.label_list(
            doc = """Exported libraries. They are on the compiler library path of the direct
              dependents, as if the dependents depended on them.""",
            providers = [KtWasmJsInfo],
        ),
        "fragment_refines": attr.string_list_dict(
            doc = "Maps fragment names to the fragments they refine (`-Xfragment-refines`).",
        ),
        "fragment_sources": attr.string_keyed_label_dict(
            doc = "Maps fragment names to their source files (`-Xfragment-sources`).",
            allow_files = [".kt"],
        ),
        "ir_output_name": attr.string(
            doc = """The `-ir-output-name` of the compiler: the klib unique name, which determines
              the per-module file names of a multimodule link. Defaults to the module name.""",
        ),
        "kotlinc_opts": _KOTLINC_OPTS_ATTR,
        "module_name": attr.string(
            doc = """The name of the module. Without it, the name derives from the label: for
              example `//some/package/path:label_name` gives `some_package_path-label_name`.""",
        ),
        "neverlink": attr.bool(
            doc = """Whether this target is only on the compiler library path. A neverlink target,
              its runtime closure and its npm packages never reach a link. Use it for a library
              that the runtime host of the binary supplies.""",
            default = False,
        ),
        "plugins": attr.label_list(
            doc = "The Kotlin compiler plugins of this compilation.",
            cfg = "exec",
            providers = [[_KtPluginConfiguration], [_KtCompilerPluginInfo]],
        ),
        "runtime_deps": attr.label_list(
            doc = "Libraries on the link path of the binaries only, not on the compiler library path.",
            providers = [KtWasmJsInfo],
        ),
        "runtime_npm_package_deps": attr.string_keyed_label_dict(
            doc = """Bare import specifier to npm package files, for the npm packages that this
              library needs at runtime. They reach the linked binaries transitively. For example
              `{"@js-joda/core": "@js_joda_core//:package"}`.""",
            allow_files = True,
        ),
        "srcs": attr.label_list(
            doc = "The Kotlin source files of a compilation without fragments.",
            allow_files = [".kt"],
        ),
    },
    toolchains = [_TOOLCHAIN_TYPE],
    implementation = _kt_wasmjs_library_impl,
    provides = [KtWasmJsInfo, _KtJvmInfo],
)

def _kt_wasmjs_import_impl(ctx):
    deps = ctx.attr.deps + ctx.attr.exported_deps
    return [
        KtWasmJsInfo(
            # The compile visibility follows the exported deps only.
            compile_klibs = depset([ctx.file.klib], transitive = [d[KtWasmJsInfo].compile_klibs for d in ctx.attr.exported_deps]),
            # The link visibility follows the full runtime closure, unless the target is neverlink.
            link_klibs = depset() if ctx.attr.neverlink else depset([ctx.file.klib], transitive = [d[KtWasmJsInfo].link_klibs for d in deps]),
            klib = ctx.file.klib,
            source_jar = ctx.file.source_jar,
            npm_packages = depset() if ctx.attr.neverlink else depset(
                npm_package_entries(ctx.attr.npm_packages),
                transitive = [d[KtWasmJsInfo].npm_packages for d in deps],
            ),
        ),
        _KtJvmInfo(exported_compiler_plugins = depset(ctx.attr.exported_compiler_plugins)),
        DefaultInfo(files = depset([ctx.file.klib])),
    ]

kt_wasmjs_import = rule(
    doc = "Imports a prebuilt Kotlin/WasmJs klib.",
    attrs = {
        "deps": attr.label_list(
            doc = "Dependencies of the klib. They reach the link path of the dependents transitively.",
            providers = [KtWasmJsInfo],
        ),
        "exported_compiler_plugins": attr.label_list(
            doc = "Compiler plugins that apply to the direct dependents of this target.",
            cfg = "exec",
            providers = [[_KtCompilerPluginInfo]],
        ),
        "exported_deps": attr.label_list(
            doc = """Dependencies of the klib that are also on the compiler library path of the
              direct dependents. They reach the link path of the dependents transitively.""",
            providers = [KtWasmJsInfo],
        ),
        "klib": attr.label(
            doc = "The klib. It is on the compiler library path of the direct dependents.",
            allow_single_file = True,
            mandatory = True,
        ),
        "neverlink": attr.bool(
            doc = """Whether this target is only on the compiler library path. A neverlink target,
              its runtime closure and its npm packages never reach a link. Use it for a library
              that the runtime host of the binary supplies.""",
            default = False,
        ),
        "npm_packages": attr.string_keyed_label_dict(
            doc = """Bare import specifier to npm package files, for the npm packages that the
              klib needs at runtime, as its embedded `package.json` declares. The npm packages of
              the dependencies propagate automatically.""",
            allow_files = True,
        ),
        "source_jar": attr.label(
            doc = "The sources of the klib.",
            allow_single_file = True,
        ),
    },
    implementation = _kt_wasmjs_import_impl,
    provides = [KtWasmJsInfo, _KtJvmInfo],
)

def _kt_wasmjs_binary_impl(ctx):
    module_info = ctx.attr.module[KtWasmJsInfo]
    if module_info.klib == None:
        fail("%s does not produce a klib (no sources?); kt_wasmjs_binary needs a klib to link via -Xinclude" % ctx.attr.module.label)

    ir_output_name = ctx.attr.ir_output_name or ctx.attr.module_name or ctx.label.name
    linked_dir = wasmjs_link_action(ctx, ir_output_name, module_info.klib, module_info.link_klibs)

    # With optimize = "auto", wasm-opt follows the build configuration: `--compilation_mode=opt`
    # ships the binaryen-optimized directory and its symbol maps. Every other mode ships the plain
    # linked output and never pays for wasm-opt.
    optimize = ctx.attr.optimize == "on" or (ctx.attr.optimize == "auto" and ctx.var["COMPILATION_MODE"] == "opt")
    if optimize:
        opt = wasm_opt_action(ctx, linked_dir, "%s-js" % ir_output_name)
        dist_dir = opt.optimized_directory
        functions_map_dir = opt.functions_map_directory
    else:
        dist_dir = linked_dir
        functions_map_dir = None

    return [
        DefaultInfo(files = depset([dist_dir] + ([functions_map_dir] if functions_map_dir else []))),
        KtWasmJsBinaryInfo(
            dist_directory = dist_dir,
            functions_map_directory = functions_map_dir,
            npm_packages = merged_npm_packages(module_info.npm_packages.to_list(), ctx.label),
        ),
    ]

kt_wasmjs_binary = rule(
    doc = """Links a `kt_wasmjs_library` and its transitive klibs into a Kotlin/WasmJs application
      directory. binaryen's wasm-opt can optimize the result, see the `optimize` attribute.""",
    attrs = {
        "ir_output_name": attr.string(
            doc = """The `-ir-output-name` of the compiler: the per-module JS and Wasm file names of
              the link. Defaults to `module_name`, then to the name of the target.""",
        ),
        "kotlinc_opts": _KOTLINC_OPTS_ATTR,
        "module": attr.label(
            doc = """The library whose klib is the entry point of the link (`-Xinclude`). Its
              transitive `link_klibs` are the `-libraries` of the link.""",
            mandatory = True,
            providers = [KtWasmJsInfo],
        ),
        "module_name": attr.string(
            doc = "The name of the linked module. It names the output files.",
        ),
        "optimize": attr.string(
            doc = """Whether the output is the wasm-opt-optimized directory ("on") or the plain
              linked one ("off"). "auto" follows the build configuration: optimized in
              `--compilation_mode=opt` builds only.""",
            default = "auto",
            values = ["auto", "on", "off"],
        ),
        "source_map_base_dirs": attr.string_list(
            doc = """The `-source-map-base-dirs` of the compiler: the roots that the `sources`
              entries of the source maps are relative to. The first match wins, and a source under
              no root becomes its bare file name. The roots are relative to the exec root. The
              default `.` is the exec root, the only root that matches every source path. The
              link passes the roots only with `source_map_prefix`.""",
            default = ["."],
        ),
        "source_map_prefix": attr.string(
            doc = """The `-source-map-prefix` of the compiler, prepended to every `sources` entry of
              the source maps. It also makes those paths relative to `source_map_base_dirs`, and
              not to the link output directory. That keeps `..` out of them.""",
        ),
        "source_maps": attr.bool(
            doc = "Whether the link emits source maps (`-source-map`).",
            default = True,
        ),
    },
    toolchains = [
        _TOOLCHAIN_TYPE,
        config_common.toolchain_type(WASM_OPT_TOOLCHAIN_TYPE, mandatory = False),
    ],
    implementation = _kt_wasmjs_binary_impl,
    provides = [KtWasmJsBinaryInfo],
)
