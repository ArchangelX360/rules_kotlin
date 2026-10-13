"""Analysis tests for the Kotlin/WasmJs rules."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("//kotlin:core.bzl", "kt_compiler_plugin", "kt_kotlinc_options")
load("//kotlin:jvm.bzl", "kt_jvm_import")
load(
    "//kotlin:wasmjs.bzl",
    "KtWasmJsBinaryInfo",
    "KtWasmJsInfo",
    "kt_wasmjs_binary",
    "kt_wasmjs_import",
    "kt_wasmjs_library",
)

def _action(env, mnemonic):
    actions = [a for a in analysistest.target_actions(env) if a.mnemonic == mnemonic]
    asserts.equals(env, expected = 1, actual = len(actions), msg = "expected one %s action" % mnemonic)
    return actions[0]

def _value_of(argv, flag):
    for i in range(len(argv) - 1):
        if argv[i] == flag:
            return argv[i + 1]
    return None

def _basenames(files):
    return sorted([f.basename for f in files.to_list()])

def _compile_action_test_impl(ctx):
    env = analysistest.begin(ctx)
    argv = _action(env, "KotlinCompileWasmJs").argv

    for flag in [
        "-Xwasm-target=js",
        "-Xmulti-platform",
        "-Xir-produce-klib-file",
        "-api-version=2.4",
        "-language-version=2.4",
        "-Xwasm-kclass-fqn",
        "-Xir-per-module-output-name=library_module",
    ]:
        asserts.true(env, flag in argv, msg = "expected %s on the KotlinCompileWasmJs action" % flag)
    for flag in argv:
        asserts.false(env, flag.startswith("-Xjdk-release"), msg = "unexpected JVM flag %s" % flag)
        asserts.false(env, flag.startswith("-jvm-target"), msg = "unexpected JVM flag %s" % flag)
    asserts.equals(env, expected = "library_module", actual = _value_of(argv, "-ir-output-name"))

    # The sources follow the `--` line.
    separator = argv.index("--")
    asserts.equals(env, expected = ["Library.kt"], actual = [a.split("/")[-1] for a in argv[separator + 1:]])

    libraries = _value_of(argv, "-libraries").split(":")
    asserts.equals(
        env,
        expected = ["kotlin-stdlib-wasm-js.klib", "test_wasmjs_dep.klib"],
        actual = sorted([l.split("/")[-1] for l in libraries]),
    )
    return analysistest.end(env)

_compile_action_test = analysistest.make(_compile_action_test_impl)

def _fragments_test_impl(ctx):
    env = analysistest.begin(ctx)
    argv = _action(env, "KotlinCompileWasmJs").argv
    for flag in ["-Xfragments=common", "-Xfragments=wasmJs", "-Xfragment-refines=wasmJs:common"]:
        asserts.true(env, flag in argv, msg = "expected %s, got %s" % (flag, argv))
    asserts.true(
        env,
        len([a for a in argv if a.startswith("-Xfragment-sources=common:") and a.endswith("/Library.kt")]) == 1,
        msg = "expected the common fragment sources, got %s" % argv,
    )
    return analysistest.end(env)

_fragments_test = analysistest.make(_fragments_test_impl)

def _link_action_test_impl(ctx):
    env = analysistest.begin(ctx)
    argv = _action(env, "KotlinLinkWasmJs").argv
    target = analysistest.target_under_test(env)

    asserts.true(env, "-Xir-produce-js" in argv)
    asserts.true(env, "-Xir-dce" in argv)
    asserts.true(env, "-source-map" in argv)
    asserts.equals(env, expected = "linked", actual = _value_of(argv, "-ir-output-name"))
    includes = [a for a in argv if a.startswith("-Xinclude=")]
    asserts.equals(env, expected = 1, actual = len(includes))
    asserts.true(env, includes[0].endswith("/library_module.klib"), msg = includes[0])

    libraries = sorted([l.split("/")[-1] for l in _value_of(argv, "-libraries").split(":")])
    asserts.equals(
        env,
        expected = ["kotlin-stdlib-wasm-js.klib", "library_module.klib", "test_wasmjs_dep.klib", "test_wasmjs_runtime_dep.klib"],
        actual = libraries,
    )

    info = target[KtWasmJsBinaryInfo]
    asserts.equals(env, expected = "linked-js", actual = info.dist_directory.basename)
    asserts.equals(env, expected = ["@js-joda/core"], actual = info.npm_packages.keys())
    return analysistest.end(env)

_link_action_test = analysistest.make(_link_action_test_impl)

def _plugin_test_impl(ctx):
    env = analysistest.begin(ctx)
    argv = _action(env, "KotlinCompileWasmJs").argv
    plugin_jars = [a for a in argv if a.startswith("-Xplugin=")]
    asserts.equals(env, expected = 1, actual = len(plugin_jars), msg = "expected one plugin jar, got %s" % argv)
    asserts.equals(env, expected = "plugin:test.wasmjs:mode=strict", actual = _value_of(argv, "-P"))
    return analysistest.end(env)

_plugin_test = analysistest.make(_plugin_test_impl)

def _optimize_on_test_impl(ctx):
    env = analysistest.begin(ctx)
    argv = _action(env, "WasmOptWasmJs").argv
    target = analysistest.target_under_test(env)
    info = target[KtWasmJsBinaryInfo]
    asserts.equals(env, expected = "%s-js-optimized" % target.label.name, actual = info.dist_directory.basename)
    asserts.equals(env, expected = "%s-js-functions-map" % target.label.name, actual = info.functions_map_directory.basename)
    asserts.true(env, "--wasm-opt-arg=--enable-gc" in argv, msg = "expected the binaryen arguments, got %s" % argv)
    return analysistest.end(env)

_optimize_on_test = analysistest.make(_optimize_on_test_impl)

def _optimize_auto_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.equals(
        env,
        expected = [],
        actual = [a for a in analysistest.target_actions(env) if a.mnemonic == "WasmOptWasmJs"],
    )
    info = analysistest.target_under_test(env)[KtWasmJsBinaryInfo]
    asserts.equals(env, expected = None, actual = info.functions_map_directory)
    return analysistest.end(env)

# "auto" optimizes only in `--compilation_mode=opt`.
_optimize_auto_test = analysistest.make(
    _optimize_auto_test_impl,
    config_settings = {"//command_line_option:compilation_mode": "fastbuild"},
)

_optimize_auto_in_opt_test = analysistest.make(
    _optimize_on_test_impl,
    config_settings = {"//command_line_option:compilation_mode": "opt"},
)

def _import_test_impl(ctx):
    env = analysistest.begin(ctx)
    info = analysistest.target_under_test(env)[KtWasmJsInfo]

    # The compile visibility follows the exported deps only, the link visibility the whole closure.
    asserts.equals(env, expected = ["test_wasmjs_dep.klib", "test_wasmjs_import.klib"], actual = _basenames(info.compile_klibs))
    asserts.equals(
        env,
        expected = ["test_wasmjs_dep.klib", "test_wasmjs_import.klib", "test_wasmjs_runtime_dep.klib"],
        actual = _basenames(info.link_klibs),
    )
    return analysistest.end(env)

_import_test = analysistest.make(_import_test_impl)

def _neverlink_test_impl(ctx):
    env = analysistest.begin(ctx)
    info = analysistest.target_under_test(env)[KtWasmJsInfo]
    asserts.equals(env, expected = ["test_wasmjs_dep.klib", "test_wasmjs_import.klib"], actual = _basenames(info.compile_klibs))
    asserts.equals(env, expected = [], actual = _basenames(info.link_klibs))
    asserts.equals(env, expected = [], actual = info.npm_packages.to_list())
    return analysistest.end(env)

_neverlink_test = analysistest.make(_neverlink_test_impl)

def _neverlink_library_test_impl(ctx):
    env = analysistest.begin(ctx)
    info = analysistest.target_under_test(env)[KtWasmJsInfo]
    asserts.equals(env, expected = ["neverlink_library.klib"], actual = _basenames(info.compile_klibs))
    asserts.equals(env, expected = [], actual = _basenames(info.link_klibs))
    asserts.equals(env, expected = [], actual = info.npm_packages.to_list())
    return analysistest.end(env)

_neverlink_library_test = analysistest.make(_neverlink_library_test_impl)

def _neverlink_dependency_test_impl(ctx):
    env = analysistest.begin(ctx)
    actions = analysistest.target_actions(env)
    link = [a for a in actions if a.mnemonic == "KotlinLinkWasmJs"]
    asserts.equals(env, expected = 1, actual = len(link))
    libraries = sorted([l.split("/")[-1] for l in _value_of(link[0].argv, "-libraries").split(":")])
    asserts.equals(
        env,
        expected = ["kotlin-stdlib-wasm-js.klib", "with_neverlink_dep.klib"],
        actual = libraries,
    )
    return analysistest.end(env)

_neverlink_dependency_test = analysistest.make(_neverlink_dependency_test_impl)

def _exclusive_sources_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "srcs and fragment_sources are exclusive")
    return analysistest.end(env)

_exclusive_sources_test = analysistest.make(_exclusive_sources_test_impl, expect_failure = True)

def _conflicting_npm_packages_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "requires the npm package '@js-joda/core' from conflicting targets")
    return analysistest.end(env)

_conflicting_npm_packages_test = analysistest.make(_conflicting_npm_packages_test_impl, expect_failure = True)

def _contents():
    for name in ["test_wasmjs_dep", "test_wasmjs_runtime_dep", "test_wasmjs_import"]:
        write_file(name = name + "_klib", out = name + ".klib", tags = ["manual"])
    for name in ["npm_a", "npm_b"]:
        write_file(name = name, out = name + "/package.json", content = ["{}"], tags = ["manual"])
    write_file(name = "library_source", out = "Library.kt", content = ["fun library() = 1"], tags = ["manual"])

    kt_wasmjs_import(
        name = "dep",
        klib = "test_wasmjs_dep.klib",
        npm_packages = {"@js-joda/core": ":npm_a"},
        tags = ["manual"],
    )
    kt_wasmjs_import(
        name = "runtime_dep",
        klib = "test_wasmjs_runtime_dep.klib",
        tags = ["manual"],
    )
    kt_wasmjs_import(
        name = "imported",
        klib = "test_wasmjs_import.klib",
        deps = [":runtime_dep"],
        exported_deps = [":dep"],
        tags = ["manual"],
    )
    kt_wasmjs_import(
        name = "neverlink_import",
        klib = "test_wasmjs_import.klib",
        deps = [":runtime_dep"],
        exported_deps = [":dep"],
        neverlink = True,
        tags = ["manual"],
    )
    kt_wasmjs_library(
        name = "neverlink_library",
        srcs = [":library_source"],
        ir_output_name = "neverlink_library",
        neverlink = True,
        deps = [":dep"],
        runtime_deps = [":runtime_dep"],
        tags = ["manual"],
    )

    write_file(name = "plugin_jar", out = "test_wasmjs_plugin.jar", tags = ["manual"])
    kt_jvm_import(
        name = "plugin_library",
        jars = ["test_wasmjs_plugin.jar"],
        tags = ["manual"],
    )
    kt_compiler_plugin(
        name = "plugin",
        id = "test.wasmjs",
        options = {"mode": ["strict"]},
        target_embedded_compiler = True,
        deps = [":plugin_library"],
        tags = ["manual"],
    )
    kt_wasmjs_library(
        name = "with_plugin",
        srcs = [":library_source"],
        plugins = [":plugin"],
        tags = ["manual"],
    )

    kt_kotlinc_options(
        name = "wasmjs_options",
        x_jdk_release = "11",
        x_wasm_kclass_fqn = True,
        tags = ["manual"],
    )
    kt_wasmjs_library(
        name = "library",
        srcs = [":library_source"],
        ir_output_name = "library_module",
        kotlinc_opts = ":wasmjs_options",
        deps = [":dep"],
        runtime_deps = [":runtime_dep"],
        tags = ["manual"],
    )
    kt_wasmjs_library(
        name = "fragments",
        fragment_sources = {"common": ":library_source"},
        fragment_refines = {"wasmJs": ["common"]},
        tags = ["manual"],
    )
    kt_wasmjs_library(
        name = "both_sources",
        srcs = [":library_source"],
        fragment_sources = {"common": ":library_source"},
        tags = ["manual"],
    )
    kt_wasmjs_library(
        name = "with_neverlink_dep",
        srcs = [":library_source"],
        ir_output_name = "with_neverlink_dep",
        deps = [":neverlink_import"],
        tags = ["manual"],
    )
    kt_wasmjs_binary(
        name = "with_neverlink_dep_binary",
        module = ":with_neverlink_dep",
        tags = ["manual"],
    )
    kt_wasmjs_binary(
        name = "linked",
        module = ":library",
        tags = ["manual"],
    )
    kt_wasmjs_binary(
        name = "optimized",
        module = ":library",
        optimize = "on",
        tags = ["manual"],
    )
    kt_wasmjs_library(
        name = "conflicting_npm",
        srcs = [":library_source"],
        deps = [":dep"],
        runtime_npm_package_deps = {"@js-joda/core": ":npm_b"},
        tags = ["manual"],
    )
    kt_wasmjs_binary(
        name = "conflicting_npm_binary",
        module = ":conflicting_npm",
        tags = ["manual"],
    )

    _compile_action_test(name = "compile_action_test", target_under_test = ":library")
    _fragments_test(name = "fragments_test", target_under_test = ":fragments")
    _link_action_test(name = "link_action_test", target_under_test = ":linked")
    _import_test(name = "import_test", target_under_test = ":imported")
    _plugin_test(name = "plugin_test", target_under_test = ":with_plugin")
    _optimize_on_test(name = "optimize_on_test", target_under_test = ":optimized")
    _optimize_auto_test(name = "optimize_auto_test", target_under_test = ":linked")
    _optimize_auto_in_opt_test(name = "optimize_auto_in_opt_test", target_under_test = ":linked")
    _neverlink_test(name = "neverlink_import_test", target_under_test = ":neverlink_import")
    _neverlink_dependency_test(name = "neverlink_dependency_test", target_under_test = ":with_neverlink_dep_binary")
    _neverlink_library_test(name = "neverlink_library_test", target_under_test = ":neverlink_library")
    _exclusive_sources_test(name = "exclusive_sources_test", target_under_test = ":both_sources")
    _conflicting_npm_packages_test(name = "conflicting_npm_packages_test", target_under_test = ":conflicting_npm_binary")

def wasmjs_test_suite(name):
    _contents()
    native.test_suite(
        name = name,
        tests = [
            ":compile_action_test",
            ":conflicting_npm_packages_test",
            ":exclusive_sources_test",
            ":fragments_test",
            ":import_test",
            ":link_action_test",
            ":neverlink_dependency_test",
            ":neverlink_import_test",
            ":neverlink_library_test",
            ":optimize_auto_in_opt_test",
            ":optimize_auto_test",
            ":optimize_on_test",
            ":plugin_test",
        ],
    )
