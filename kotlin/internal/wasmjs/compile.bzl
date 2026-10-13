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
"""Kotlin/WasmJs compile and link actions."""

load("//kotlin/internal:defs.bzl", _KtJvmInfo = "KtJvmInfo", _TOOLCHAIN_TYPE = "TOOLCHAIN_TYPE")
load("//kotlin/internal:opts.bzl", "KotlincOptions", "kotlinc_options_to_wasmjs_flags")
load("//kotlin/internal/jvm:compile.bzl", _jvm_compile = "compile")
load("//kotlin/internal/utils:utils.bzl", _utils = "utils")
load(":providers.bzl", "KtWasmJsInfo")

# The compile and the link actions share one worker pool: the same worker handles both requests.
_WORKER_KEY_MNEMONIC = "KotlinCompileWasmJs"

def npm_package_entries(npm_package_attr):
    """Converts an npm package attribute into the entries of `KtWasmJsInfo.npm_packages`.

    Args:
        npm_package_attr: dict of bare import specifier to npm package files target.

    Returns:
        list of struct(specifier, label, files).
    """
    return [
        struct(
            specifier = specifier,
            label = target.label,
            files = target[DefaultInfo].files,
        )
        for specifier, target in npm_package_attr.items()
    ]

def merged_npm_packages(entries, owner):
    """Merges npm package entries into a dict keyed by specifier.

    The npm packages of a linked binary live in a single flat `/node_modules/`, so a specifier
    that two different targets provide fails.

    Args:
        entries: list of struct(specifier, label, files).
        owner: the label to report in the failure.

    Returns:
        dict of specifier to struct(specifier, label, files).
    """
    merged = {}
    for entry in entries:
        existing = merged.get(entry.specifier)
        if existing != None and existing.label != entry.label:
            fail("%s requires the npm package '%s' from conflicting targets: %s and %s" % (
                owner,
                entry.specifier,
                existing.label,
                entry.label,
            ))
        merged[entry.specifier] = entry
    return merged

def _kotlinc_options(ctx, toolchain):
    if ctx.attr.kotlinc_opts:
        return ctx.attr.kotlinc_opts[KotlincOptions]
    return toolchain.kotlinc_options

def _common_args(ctx, toolchain, ir_output_name):
    kotlinc_options = _kotlinc_options(ctx, toolchain)

    args = ctx.actions.args()
    args.set_param_file_format("multiline")
    args.use_param_file("--flagfile=%s", use_always = True)
    args.add("-Xwasm-target=js")
    args.add("-Xmulti-platform")

    # The kotlinc options override the toolchain-wide versions.
    if not getattr(kotlinc_options, "api_version", None):
        args.add("-api-version=%s" % toolchain.api_version)
    if not getattr(kotlinc_options, "language_version", None):
        args.add("-language-version=%s" % toolchain.language_version)
    args.add_all(kotlinc_options_to_wasmjs_flags(kotlinc_options))

    args.add("-ir-output-name", ir_output_name)

    # The file name of the module in a multimodule link. Without it, the linker derives an escaped
    # name from the klib unique name. The Kotlin Gradle plugin sets the same flag.
    args.add("-Xir-per-module-output-name=%s" % ir_output_name)
    return args

def _run_builder(ctx, toolchain, mnemonic, inputs, outputs, args, progress_message):
    ctx.actions.run(
        mnemonic = mnemonic,
        inputs = inputs,
        outputs = outputs,
        tools = [toolchain.wasmjs_builder.files_to_run],
        executable = toolchain.wasmjs_builder.files_to_run.executable,
        execution_requirements = _utils.add_dicts(
            toolchain.execution_requirements,
            {
                "supports-worker-cancellation": "1",
                "worker-key-mnemonic": _WORKER_KEY_MNEMONIC,
            },
        ),
        arguments = [args],
        progress_message = progress_message,
        toolchain = _TOOLCHAIN_TYPE,
    )

def _stdlib_infos(toolchain):
    return [target[KtWasmJsInfo] for target in toolchain.wasmjs_stdlibs]

def _sources(ctx):
    """Returns the source files and the fragment arguments of the compilation."""
    if ctx.attr.srcs and ctx.attr.fragment_sources:
        fail("%s: srcs and fragment_sources are exclusive" % ctx.label)

    fragment_args = []
    fragments = {}
    for fragment, refined in ctx.attr.fragment_refines.items():
        fragments[fragment] = True
        for r in refined:
            fragment_args.append("-Xfragment-refines=%s:%s" % (fragment, r))
    sources = list(ctx.files.srcs)
    for fragment, target in ctx.attr.fragment_sources.items():
        fragments[fragment] = True
        for f in target.files.to_list():
            sources.append(f)
            fragment_args.append("-Xfragment-sources=%s:%s" % (fragment, f.path))
    for fragment in fragments:
        fragment_args.append("-Xfragments=%s" % fragment)
    return sources, fragment_args

def _plugin_args(args, plugins):
    for plugin in plugins.plugins:
        if "compile" not in plugin.phases:
            continue
        args.add_all(plugin.classpath, format_each = "-Xplugin=%s")
        for option in plugin.options:
            args.add("-P", "plugin:%s:%s=%s" % (plugin.id, option.key, option.value))

def wasmjs_ir_output_name(ctx):
    """Returns the `-ir-output-name` of the target: the klib unique name."""
    return ctx.attr.ir_output_name or _utils.derive_module_name(ctx)

def wasmjs_compile_actions(ctx):
    """Registers the KotlinCompileWasmJs action of a library target.

    Args:
        ctx: the rule context of a kt_wasmjs_library.

    Returns:
        the providers of the library.
    """
    toolchain = ctx.toolchains[_TOOLCHAIN_TYPE]
    stdlibs = _stdlib_infos(toolchain)
    deps = ctx.attr.exports + ctx.attr.deps

    compile_exported_klibs = depset(transitive = [d[KtWasmJsInfo].compile_klibs for d in ctx.attr.exports])
    compile_klibs = depset(transitive = [s.compile_klibs for s in stdlibs] + [d[KtWasmJsInfo].compile_klibs for d in deps])
    link_klibs = depset(transitive = [d[KtWasmJsInfo].link_klibs for d in deps + ctx.attr.runtime_deps])
    neverlink = ctx.attr.neverlink

    exported_compiler_plugins = _jvm_compile.collect_plugins_for_export([], ctx.attr.exports)

    # npm packages follow the runtime (link) closure, like link_klibs.
    npm_packages = depset(
        npm_package_entries(ctx.attr.runtime_npm_package_deps),
        transitive = [d[KtWasmJsInfo].npm_packages for d in deps + ctx.attr.runtime_deps],
    )

    runfiles = ctx.runfiles(files = ctx.files.data)
    sources, fragment_args = _sources(ctx)
    if not sources:
        return [
            KtWasmJsInfo(
                compile_klibs = compile_exported_klibs,
                link_klibs = depset() if neverlink else link_klibs,
                klib = None,
                source_jar = None,
                npm_packages = depset() if neverlink else npm_packages,
            ),
            _KtJvmInfo(exported_compiler_plugins = exported_compiler_plugins),
            DefaultInfo(runfiles = runfiles),
        ]

    ir_output_name = wasmjs_ir_output_name(ctx)
    klib = ctx.actions.declare_file("%s.klib" % ir_output_name)

    args = _common_args(ctx, toolchain, ir_output_name)
    args.add("-ir-output-dir", klib.dirname)
    args.add("-Xir-produce-klib-file")
    args.add_all(fragment_args)
    args.add_joined("-libraries", compile_klibs, join_with = ctx.configuration.host_path_separator, omit_if_empty = True)
    plugins = _jvm_compile.new_plugins_from(ctx.attr.plugins + _jvm_compile.exported_plugins(deps))
    _plugin_args(args, plugins)
    args.add("--")
    args.add_all(sources)

    _run_builder(
        ctx,
        toolchain,
        mnemonic = "KotlinCompileWasmJs",
        inputs = depset(sources, transitive = [compile_klibs, plugins.classpath, plugins.data]),
        outputs = [klib],
        args = args,
        progress_message = "Compiling Kotlin/WasmJs %%{label} { kt: %d }" % len(sources),
    )

    return [
        KtWasmJsInfo(
            compile_klibs = depset([klib], transitive = [compile_exported_klibs]),
            # A neverlink library, its runtime closure and its npm packages never reach a link.
            link_klibs = depset() if neverlink else depset([klib], transitive = [link_klibs]),
            klib = klib,
            source_jar = None,
            npm_packages = depset() if neverlink else npm_packages,
        ),
        _KtJvmInfo(exported_compiler_plugins = exported_compiler_plugins),
        DefaultInfo(files = depset([klib]), runfiles = runfiles),
    ]

def wasmjs_link_action(ctx, ir_output_name, module_klib, link_klibs):
    """Registers the KotlinLinkWasmJs action linking `module_klib` against `link_klibs`.

    Args:
        ctx: the rule context. It needs the `kotlinc_opts`, `source_maps`, `source_map_base_dirs`
            and `source_map_prefix` attributes.
        ir_output_name: the `-ir-output-name` of the link.
        module_klib: the klib that is the entry point of the link (`-Xinclude`).
        link_klibs: the klibs of the link. They contain `module_klib`, as
            `KtWasmJsInfo.link_klibs` does.

    Returns:
        the declared linked output directory, `<ir_output_name>-js`.
    """
    toolchain = ctx.toolchains[_TOOLCHAIN_TYPE]
    libraries = depset(transitive = [s.link_klibs for s in _stdlib_infos(toolchain)] + [link_klibs])

    output = ctx.actions.declare_directory("%s-js" % ir_output_name)
    args = _common_args(ctx, toolchain, ir_output_name)
    args.add("-ir-output-dir", output.path)
    args.add("-Xir-produce-js")
    args.add("-Xinclude=%s" % module_klib.path)
    args.add("-Xir-dce")
    if ctx.attr.source_maps:
        args.add("-source-map")
        if ctx.attr.source_map_prefix:
            # A prefix makes the compiler write the paths relative to the source roots, and not to
            # the link output. Every path the compiler sees is relative to the exec root, hence the
            # `.` default of `source_map_base_dirs`. The worker resolves the roots.
            args.add_joined(
                "-source-map-base-dirs",
                ctx.attr.source_map_base_dirs,
                join_with = ctx.configuration.host_path_separator,
                omit_if_empty = True,
            )
            args.add("-source-map-prefix", ctx.attr.source_map_prefix)
    args.add_joined("-libraries", libraries, join_with = ctx.configuration.host_path_separator, omit_if_empty = True)

    _run_builder(
        ctx,
        toolchain,
        mnemonic = "KotlinLinkWasmJs",
        inputs = libraries,
        outputs = [output],
        args = args,
        progress_message = "Linking Kotlin/WasmJs %{label}",
    )
    return output
