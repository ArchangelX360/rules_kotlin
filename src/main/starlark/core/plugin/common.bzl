"""Utilities for resolving compiler plugin configurations."""

load("@rules_java//java/common:java_common.bzl", "java_common")
load("@rules_java//java/common:java_info.bzl", "JavaInfo")
load("//src/main/starlark/core/compile:common.bzl", "KtJvmInfo")
load(":providers.bzl", "KtCompilerPluginInfo", "KtCompilerPluginOption", "KtPluginConfiguration")

def _resolve_plugin_cfg(info, options, deps, expand_location, data = depset()):
    """Resolves a plugin config.

    Args:
        info: KtCompilerPluginInfo of the plugin configuration.
        options: Dict[str, List[str]] of options from kt_plugin_cfg
        deps: List[Target] from kt_plugin_cfg
        expand_location: Callable[str]str to expand any target references, from ctx.expand_location
        data: Depset[File] from kt_plugin_cfg: the data files and the runfiles of the data targets.
    Return:
        List[Provider] of providers.
    """
    ji = java_common.merge([dep[JavaInfo] for dep in deps if JavaInfo in dep])
    classpath = depset(ji.runtime_output_jars, transitive = [ji.transitive_runtime_jars])

    # The compilation gets the data depset and the runfiles of the dependencies as inputs.
    data_files = depset(transitive = [data] + [dep[DefaultInfo].default_runfiles.files for dep in deps])
    return [
        KtPluginConfiguration(
            id = info.id,
            options = _resolve_plugin_options(options, expand_location),
            classpath = classpath,
            data = data_files,
        ),
    ]

def _merge_plugin_cfgs(info, cfgs):
    classpath = depset(transitive = [cfg.classpath for cfg in cfgs])
    options = [o for cfg in cfgs for o in cfg.options]
    return KtPluginConfiguration(
        id = info.id,
        options = options,
        classpath = classpath,
        data = depset(transitive = [cfg.data for cfg in cfgs]),
    )

def _resolve_plugin_options(string_list_dict, expand_location):
    """
    Resolves plugin options from a string dict to a dict of strings.

    Args:
        string_list_dict: a dict of list[string].
        expand_location:
    Returns:
        list of KtCompilerPluginOption
    """
    options = []
    for (k, vs) in string_list_dict.items():
        for v in vs:
            if "=" in k:
                fail("kotlin compiler option keys cannot contain the = symbol")
            options.append(KtCompilerPluginOption(
                key = k,
                value = expand_location(v) if v else "",
            ))
    return options

def _exported_plugins(deps):
    """Encapsulates compiler dependency metadata."""
    plugins = []
    for dep in deps:
        if KtJvmInfo in dep and dep[KtJvmInfo] != None:
            plugins.extend(dep[KtJvmInfo].exported_compiler_plugins.to_list())
    return plugins

def _collect_plugins_for_export(local, exports):
    """Collects into a depset. """
    return depset(
        local,
        transitive = [
            e[KtJvmInfo].exported_compiler_plugins
            for e in exports
            if KtJvmInfo in e and e[KtJvmInfo]
        ],
    )

def _new_plugins_from(targets):
    """Returns a struct containing the plugin metadata for the given targets.

    Args:
        targets: A list of targets.
    Returns:
        A struct containing merged plugins and aggregate classpath/data.
    """

    all_plugins = {}
    plugins_without_phase = []
    for t in targets:
        if KtCompilerPluginInfo not in t:
            continue
        plugin = t[KtCompilerPluginInfo]
        if not (plugin.stubs or plugin.compile):
            plugins_without_phase.append("%s: %s" % (t.label, plugin.id))
        if plugin.id in all_plugins and all_plugins[plugin.id] != plugin:
            # This need a more robust error messaging.
            fail("has multiple plugins with the same id: %s." % plugin.id)
        all_plugins[plugin.id] = plugin

    if plugins_without_phase:
        fail("has plugin without a phase defined: %s" % plugins_without_phase)

    all_plugin_cfgs = {}
    cfgs_without_plugin = []
    for t in targets:
        if KtPluginConfiguration not in t:
            continue
        cfg = t[KtPluginConfiguration]
        if cfg.id not in all_plugins:
            cfgs_without_plugin.append("%s: %s" % (t.label, cfg.id))
        all_plugin_cfgs.setdefault(cfg.id, []).append(cfg)

    if cfgs_without_plugin:
        fail("has plugin configurations without corresponding plugins: %s" % cfgs_without_plugin)

    classpath = []
    data = []
    plugins = []
    for p in all_plugins.values():
        plugin_classpath = [p.classpath]
        plugin_options = list(p.options)
        plugin_data = getattr(p, "data", None)
        if plugin_data:
            data.append(plugin_data)
        if p.id in all_plugin_cfgs:
            cfg = p.merge_cfgs(p, all_plugin_cfgs[p.id])
            plugin_classpath.append(cfg.classpath)
            data.append(cfg.data)
            plugin_options.extend(cfg.options)

        phases = []
        if p.compile:
            phases.append("compile")
        if p.stubs:
            phases.append("stubs")

        plugins.append(struct(
            id = p.id,
            phases = phases,
            classpath = depset(transitive = plugin_classpath),
            options = plugin_options,
        ))
        classpath.extend(plugin_classpath)

    return struct(
        classpath = depset(transitive = classpath),
        data = depset(transitive = data),
        plugins = plugins,
    )

plugin_common = struct(
    resolve_cfg = _resolve_plugin_cfg,
    merge_cfgs = _merge_plugin_cfgs,
    resolve_plugin_options = _resolve_plugin_options,
    exported_plugins = _exported_plugins,
    collect_plugins_for_export = _collect_plugins_for_export,
    new_plugins_from = _new_plugins_from,
)
