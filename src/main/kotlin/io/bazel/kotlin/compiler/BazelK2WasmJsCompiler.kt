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

import org.jetbrains.kotlin.cli.common.CLICompiler
import org.jetbrains.kotlin.cli.common.ExitCode
import org.jetbrains.kotlin.cli.common.arguments.CommonCompilerArguments
import org.jetbrains.kotlin.cli.common.messages.MessageRenderer
import org.jetbrains.kotlin.cli.common.messages.PrintingMessageCollector
import org.jetbrains.kotlin.cli.js.K2JSCompiler
import org.jetbrains.kotlin.cli.js.KotlinWasmCompiler
import org.jetbrains.kotlin.config.Services
import java.io.PrintStream

/**
 * Compiles Kotlin/WasmJs klibs and links them, with the `destination` as the IR output directory.
 *
 * The compiler distribution of the toolchain decides the compiler class. A distribution with
 * `KotlinWasmCompiler` uses it. An older one uses `K2JSCompiler` with `-Xwasm`. A compiler that
 * packs klibs by default, which shows as a `-nopack` argument, gets no `-Xir-produce-klib-file`.
 */
@Suppress("unused")
class BazelK2WasmJsCompiler : KotlinCompiler {
  override fun exec(
    errStream: PrintStream,
    args: Array<String>,
    sources: Array<String>,
    destination: String,
  ): ExitCode =
    if (HAS_WASM_COMPILER) {
      exec(KotlinWasmCompiler(), errStream, args, sources, destination)
    } else {
      exec(K2JSCompiler(), errStream, arrayOf("-Xwasm") + args, sources, destination)
    }

  private fun <A : CommonCompilerArguments> exec(
    delegate: CLICompiler<A>,
    errStream: PrintStream,
    args: Array<String>,
    sources: Array<String>,
    destination: String,
  ): ExitCode {
    val arguments = delegate.createArguments()
    val packsByDefault = arguments.javaClass.methods.any { it.name == "setNopack" }
    val compilerArgs = args.filterNot { packsByDefault && it == PRODUCE_KLIB_FILE }
    delegate.parseArguments(
      (compilerArgs + listOf("-ir-output-dir", destination) + sources).toTypedArray(),
      arguments,
    )
    val collector =
      PrintingMessageCollector(errStream, MessageRenderer.PLAIN_RELATIVE_PATHS, arguments.verbose)
    return delegate.exec(collector, Services.EMPTY, arguments)
  }

  private companion object {
    const val PRODUCE_KLIB_FILE = "-Xir-produce-klib-file"

    val HAS_WASM_COMPILER =
      runCatching {
        Class.forName(
          "org.jetbrains.kotlin.cli.js.KotlinWasmCompiler",
          false,
          BazelK2WasmJsCompiler::class.java.classLoader,
        )
      }.isSuccess
  }
}
