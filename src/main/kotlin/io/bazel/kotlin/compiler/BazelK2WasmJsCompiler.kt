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
package io.bazel.kotlin.compiler

import org.jetbrains.kotlin.cli.common.ExitCode
import org.jetbrains.kotlin.cli.common.messages.MessageRenderer
import org.jetbrains.kotlin.cli.common.messages.PrintingMessageCollector
import org.jetbrains.kotlin.cli.js.KotlinWasmCompiler
import org.jetbrains.kotlin.config.KotlinCompilerVersion
import org.jetbrains.kotlin.config.Services
import java.io.PrintStream

/**
 * Compiles Kotlin/WasmJs klibs and links them, with the `destination` as the IR output directory.
 *
 * It needs Kotlin 2.4.20 or later: the first release with `KotlinWasmCompiler` and klibs packed by
 * default. An older compiler distribution fails the compilation.
 */
@Suppress("unused")
class BazelK2WasmJsCompiler : KotlinCompiler {
  override fun exec(
    errStream: PrintStream,
    args: Array<String>,
    sources: Array<String>,
    destination: String,
  ): ExitCode {
    if (!SUPPORTED) {
      errStream.println(
        "error: the Kotlin/WasmJs rules need Kotlin $MINIMUM_VERSION or later, " +
          "the toolchain compiler is ${KotlinCompilerVersion.VERSION}",
      )
      return ExitCode.INTERNAL_ERROR
    }
    val compiler = KotlinWasmCompiler()
    val arguments = compiler.createArguments()
    compiler.parseArguments(args + listOf("-ir-output-dir", destination) + sources, arguments)
    val collector =
      PrintingMessageCollector(errStream, MessageRenderer.PLAIN_RELATIVE_PATHS, arguments.verbose)
    return compiler.exec(collector, Services.EMPTY, arguments)
  }

  private companion object {
    val MINIMUM_VERSION = KotlinVersion(2, 4, 20)

    /** The compiler of the classloader never changes, so the worker checks it once. */
    val SUPPORTED = isSupported(KotlinCompilerVersion.VERSION)

    /** Compares the leading `major.minor.patch` of [version], e.g. of `2.5.0-Beta2`. */
    fun isSupported(version: String): Boolean {
      val parts = version.substringBefore('-').split('.')
      if (parts.size < 3) return false
      val (major, minor, patch) = parts.map { it.toIntOrNull() ?: return false }
      return KotlinVersion(major, minor, patch)
        .isAtLeast(MINIMUM_VERSION.major, MINIMUM_VERSION.minor, MINIMUM_VERSION.patch)
    }
  }
}
