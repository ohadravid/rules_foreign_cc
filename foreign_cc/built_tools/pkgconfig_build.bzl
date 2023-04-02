""" Rule for building pkg-config from source. """

load("@bazel_tools//tools/cpp:toolchain_utils.bzl", "find_cpp_toolchain")
load("//foreign_cc:defs.bzl", "make_variant", "runnable_binary")
load(
    "//foreign_cc/built_tools/private:built_tools_framework.bzl",
    "FOREIGN_CC_BUILT_TOOLS_ATTRS",
    "FOREIGN_CC_BUILT_TOOLS_FRAGMENTS",
    "FOREIGN_CC_BUILT_TOOLS_HOST_FRAGMENTS",
    "absolutize",
    "built_tool_rule_impl",
)
load("//toolchains/native_tools:tool_access.bzl", "get_make_data")
load(
    "//foreign_cc/private:cc_toolchain_util.bzl",
    "get_env_vars",
    "get_flags_info",
    "get_tools_info",
)

def _pkgconfig_tool_impl(ctx):
    make_data = get_make_data(ctx)
    
    env = get_env_vars(ctx)
    flags_info = get_flags_info(ctx)
    tools_info = get_tools_info(ctx)
    
    cc_path = tools_info.cc
    cflags = flags_info.cc
    ld_path = tools_info.cxx_linker_executable
    ldflags = flags_info.cxx_linker_executable
    ar_path = tools_info.cxx_linker_static
    frozen_arflags = flags_info.cxx_linker_static
    
    absolute_cc = absolutize(ctx.workspace_name, cc_path, True)
    absolute_ld = absolutize(ctx.workspace_name, ld_path, True)
    absolute_ar = absolutize(ctx.workspace_name, ar_path, True)
    
    arflags = [e for e in frozen_arflags]
    if absolute_ar == "libtool" or absolute_ar.endswith("/libtool"):
        # MacOS workaround for libtool being detected instead of CommandLineTools's AR
        absolute_ar = ""
        
    cflags.append("-fPIC")
    cflags.append("-Wno-int-conversion")
        
    env.update({
        "AR": absolute_ar,
        "ARFLAGS": _join_flags_list(ctx.workspace_name, arflags),
        "CC": absolute_cc,
        "CFLAGS": _join_flags_list(ctx.workspace_name, cflags),
        "LD": absolute_ld,
        "LDFLAGS": _join_flags_list(ctx.workspace_name, ldflags),
        "MAKE": make_data.path,
    })
    
    configure_env = " ".join(["%s=\"%s\"" % (key, value) for key, value in env.items()])
    script = [
        "%s ./configure  --with-internal-glib --prefix=$$INSTALLDIR$$" % configure_env,
        "%s" % make_data.path,
        "%s install" % make_data.path,
    ]

    additional_tools = depset(transitive = [make_data.target.files])

    return built_tool_rule_impl(
        ctx,
        script,
        ctx.actions.declare_directory("pkgconfig"),
        "BootstrapPkgConfig",
        additional_tools,
    )

pkgconfig_tool_unix = rule(
    doc = "Rule for building pkgconfig on Unix operating systems",
    attrs = FOREIGN_CC_BUILT_TOOLS_ATTRS,
    host_fragments = FOREIGN_CC_BUILT_TOOLS_HOST_FRAGMENTS,
    fragments = FOREIGN_CC_BUILT_TOOLS_FRAGMENTS,
    output_to_genfiles = True,
    implementation = _pkgconfig_tool_impl,
    toolchains = [
        "@rules_foreign_cc//foreign_cc/private/framework:shell_toolchain",
        "@rules_foreign_cc//toolchains:make_toolchain",
        "@bazel_tools//tools/cpp:toolchain_type",
    ],
)

def pkgconfig_tool(name, srcs, **kwargs):
    """
    Macro that provides targets for building pkg-config from source

    Args:
        name: The target name
        srcs: The pkg-config source files
        **kwargs: Remaining keyword arguments
    """
    tags = ["manual"] + kwargs.pop("tags", [])

    native.config_setting(
        name = "msvc_compiler",
        flag_values = {
            "@bazel_tools//tools/cpp:compiler": "msvc-cl",
        },
    )

    native.alias(
        name = name,
        actual = select({
            ":msvc_compiler": "{}_msvc".format(name),
            "//conditions:default": "{}_default".format(name),
        }),
    )

    pkgconfig_tool_unix(
        name = "{}_default".format(name),
        srcs = srcs,
        tags = tags,
        **kwargs
    )

    make_variant(
        name = "{}_msvc_build".format(name),
        lib_source = srcs,
        args = [
            "-f Makefile.vc",
            "CFG=release",
            "GLIB_PREFIX=\"$$EXT_BUILD_ROOT/external/glib_dev\"",
        ],
        out_binaries = ["pkg-config.exe"],
        env = {"INCLUDE": "$$EXT_BUILD_ROOT/external/glib_src"},
        out_static_libs = [],
        out_shared_libs = [],
        deps = [
            "@glib_dev",
            "@glib_src//:msvc_hdr",
            "@gettext_runtime",
        ],
        postfix_script = select({
            "@platforms//os:windows": "cp release/x64/pkg-config.exe $$INSTALLDIR$$/bin",
            "//conditions:default": "",
        }),
        toolchain = "@rules_foreign_cc//toolchains:preinstalled_nmake_toolchain",
        tags = tags,
        **kwargs
    )

    runnable_binary(
        name = "{}_msvc".format(name),
        binary = "pkg-config",
        foreign_cc_target = "{}_msvc_build".format(name),
        # Tools like CMake and Meson search for "pkg-config" on the PATH
        match_binary_name = True,
        tags = tags,
    )

def _join_flags_list(workspace_name, flags):
    return " ".join([absolutize(workspace_name, flag) for flag in flags])
