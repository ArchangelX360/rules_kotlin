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

import io.bazel.worker.Status
import io.bazel.worker.Work
import io.bazel.worker.WorkerContext
import java.io.IOException
import java.nio.file.Files
import java.nio.file.Path
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.streams.toList

/**
 * Runs binaryen's wasm-opt over every `.wasm` file of a linked Kotlin/WasmJs directory for the
 * WasmOptWasmJs action. It copies the other files through unchanged, and writes the
 * `--symbolmap` of each wasm file as `<wasm basename without extension>.txt`. The symbol maps
 * decode the stack traces of the optimized wasm.
 *
 * The only argument is `--flagfile=<path>`. Each line of the flagfile is an `--<option>=<value>`
 * pair. The work resolves every path against [WorkerContext.TaskContext.execRoot].
 */
class OptimizeWasm : Work {
  override fun invoke(
    ctx: WorkerContext.TaskContext,
    args: Iterable<String>,
  ): Status {
    val flagfile =
      args.singleOrNull()?.takeIf { it.startsWith(FLAGFILE) }?.removePrefix(FLAGFILE)
        ?: run {
          ctx.error { "expected --flagfile=<path> as the only argument, got $args" }
          return Status.ERROR
        }
    val execRoot = ctx.execRoot
    val valuesByOption =
      Files
        .readAllLines(execRoot.resolve(flagfile))
        .filter { it.isNotBlank() }
        .map { it.split('=', limit = 2) }
        .groupBy({ (option, _) -> option }, { (_, value) -> value })

    fun requiredPath(option: String): Path =
      execRoot.resolve(requireNotNull(valuesByOption[option]?.last()) { "$option is required" })

    val failures =
      optimizeDirectory(
        inputDirectory = requiredPath("--input-directory"),
        outputDirectory = requiredPath("--output-directory"),
        functionsMapDirectory = requiredPath("--functions-map-directory"),
        wasmOpt = requiredPath("--wasm-opt"),
        wasmOptArgs = valuesByOption["--wasm-opt-arg"].orEmpty(),
        logDirectory = ctx.directory,
      )
    failures.forEach { failure -> ctx.error { failure } }
    return if (failures.isEmpty()) Status.SUCCESS else Status.ERROR
  }

  private companion object {
    const val FLAGFILE = "--flagfile="
  }
}

/** Returns the failure message of every wasm file that wasm-opt could not optimize. */
private fun optimizeDirectory(
  inputDirectory: Path,
  outputDirectory: Path,
  functionsMapDirectory: Path,
  wasmOpt: Path,
  wasmOptArgs: List<String>,
  logDirectory: Path,
): List<String> {
  val (wasmFiles, otherFiles) =
    Files
      .walk(inputDirectory)
      .use { paths -> paths.filter { Files.isRegularFile(it) }.toList() }
      .partition { it.fileName.toString().endsWith(".wasm") }

  for (file in otherFiles) {
    val target = outputDirectory.resolve(inputDirectory.relativize(file).toString())
    Files.createDirectories(target.parent)
    Files.copy(file, target)
  }

  val processors = Runtime.getRuntime().availableProcessors()
  val executor = Executors.newFixedThreadPool(minOf(processors, wasmFiles.size).coerceAtLeast(1))
  try {
    val results =
      wasmFiles.mapIndexed { index, input ->
        val output = outputDirectory.resolve(inputDirectory.relativize(input).toString())
        Files.createDirectories(output.parent)
        val name = input.fileName.toString().removeSuffix(".wasm")
        val functionsMap = functionsMapDirectory.resolve("$name.txt")
        val log = logDirectory.resolve("wasm-opt-$index.log")
        executor.submit<String?> {
          optimize(wasmOpt, wasmOptArgs, input, output, functionsMap, log)
        }
      }
    return results.mapNotNull { result ->
      try {
        result.get()
      } catch (e: ExecutionException) {
        throw e.cause ?: e
      }
    }
  } finally {
    // An interrupt of the request thread interrupts the wasm-opt threads, which kill their process.
    executor.shutdownNow()
    executor.awaitTermination(1, TimeUnit.MINUTES)
  }
}

/** Runs wasm-opt on one file. Returns the failure message, or null on success. */
private fun optimize(
  wasmOpt: Path,
  wasmOptArgs: List<String>,
  input: Path,
  output: Path,
  functionsMap: Path,
  log: Path,
): String? {
  Files.createDirectories(functionsMap.parent)
  val command =
    listOf(wasmOpt.toString()) +
      wasmOptArgs +
      listOf(input.toString(), "-o", output.toString(), "--symbolmap=$functionsMap")
  // The output goes to a file: a read of the process output cannot be interrupted, waitFor can.
  val process =
    ProcessBuilder(command)
      .redirectErrorStream(true)
      .redirectOutput(log.toFile())
      .start()
  try {
    val exitCode = process.waitFor()
    if (exitCode != 0) {
      val processOutput = String(Files.readAllBytes(log))
      return "wasm-opt failed on ${input.fileName} with exit code $exitCode:\n$processOutput"
    }
    return null
  } catch (e: InterruptedException) {
    process.destroyForcibly()
    throw e
  } catch (e: IOException) {
    process.destroyForcibly()
    throw e
  }
}
