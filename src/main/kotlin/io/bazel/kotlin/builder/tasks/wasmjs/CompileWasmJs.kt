/*
 * Copyright 2026 The Bazel Authors. All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package io.bazel.kotlin.builder.tasks.wasmjs

import io.bazel.kotlin.builder.toolchain.KotlinToolchain
import io.bazel.worker.Status
import io.bazel.worker.Work
import io.bazel.worker.WorkerContext
import java.io.File
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.Path

/**
 * Compiles a klib, or links klibs, for the KotlinCompileWasmJs and KotlinLinkWasmJs actions. The
 * flagfile holds the compiler arguments, then a `--` line and the sources.
 */
class CompileWasmJs(
  private val compiler: KotlinToolchain.KotlincInvoker,
) : Work {
  companion object {
    @JvmStatic
    private val FLAGFILE_RE = Regex("""^--flagfile=((.*)-(\d+).params)$""")
  }

  override fun invoke(
    ctx: WorkerContext.TaskContext,
    args: Iterable<String>,
  ): Status {
    val execRoot = ctx.execRoot
    val request = WasmJsCompilerRequest.parse(getArgs(execRoot, args.toList()), execRoot)

    val exitCode =
      compiler.compile(
        request.arguments.toTypedArray(),
        request.sources.toTypedArray(),
        request.destination,
        ctx.asPrintStream(),
      )
    return if (exitCode == 0) Status.SUCCESS else Status.ERROR
  }

  private fun getArgs(
    execRoot: Path,
    args: List<String>,
  ): List<String> {
    check(args.isNotEmpty()) { "expected at least a single arg got: ${args.joinToString(" ")}" }
    return FLAGFILE_RE.matchEntire(args[0])?.groups?.get(1)?.let {
      Files.readAllLines(execRoot.resolve(it.value), StandardCharsets.UTF_8)
    } ?: args
  }
}

/**
 * The compiler arguments of a request. The paths of a sandboxed request are relative to its
 * sandbox, so every path resolves against the exec root.
 */
class WasmJsCompilerRequest private constructor(
  val arguments: List<String>,
  val sources: List<String>,
  val destination: String,
) {
  companion object {
    private const val SOURCES_SEPARATOR = "--"
    private const val OUTPUT_DIR = "-ir-output-dir"

    // Options whose value is the next argument, a list of paths separated by File.pathSeparator.
    private val PATH_LIST_OPTIONS = setOf("-libraries", "-source-map-base-dirs")

    // Options with an `=` value that is one path.
    private val PATH_VALUE_OPTIONS = listOf("-Xinclude=", "-Xplugin=")

    // Options with an `=` value of the form `<fragment>:<path>`.
    private const val FRAGMENT_SOURCES = "-Xfragment-sources="

    fun parse(
      lines: List<String>,
      execRoot: Path,
    ): WasmJsCompilerRequest {
      val separator = lines.indexOf(SOURCES_SEPARATOR)
      val options = if (separator == -1) lines else lines.subList(0, separator)
      val sources = if (separator == -1) emptyList() else lines.subList(separator + 1, lines.size)

      val arguments = mutableListOf<String>()
      var destination: String? = null
      val remaining = options.iterator()
      while (remaining.hasNext()) {
        when (val option = remaining.next()) {
          OUTPUT_DIR -> {
            destination = execRoot.resolvePath(remaining.valueOf(option))
          }

          in PATH_LIST_OPTIONS -> {
            arguments += option
            arguments +=
              remaining
                .valueOf(option)
                .split(File.pathSeparatorChar)
                .filter { it.isNotBlank() }
                .joinToString(File.pathSeparator) { execRoot.resolvePath(it) }
          }

          else -> {
            arguments += execRoot.resolveOptionValue(option)
          }
        }
      }

      return WasmJsCompilerRequest(
        arguments = arguments,
        sources = sources.map { execRoot.resolvePath(it) },
        destination = requireNotNull(destination) { "$OUTPUT_DIR is required" },
      )
    }

    private fun Iterator<String>.valueOf(option: String): String {
      require(hasNext()) { "$option requires a value" }
      return next()
    }

    private fun Path.resolveOptionValue(option: String): String {
      PATH_VALUE_OPTIONS.firstOrNull { option.startsWith(it) }?.let { prefix ->
        return prefix + resolvePath(option.removePrefix(prefix))
      }
      if (option.startsWith(FRAGMENT_SOURCES)) {
        val (fragment, path) = option.removePrefix(FRAGMENT_SOURCES).split(':', limit = 2)
        return "$FRAGMENT_SOURCES$fragment:${resolvePath(path)}"
      }
      return option
    }

    // The Kotlin compiler accepts the `\` separator on Windows.
    private fun Path.resolvePath(path: String): String = resolve(path).normalize().toString()
  }
}
