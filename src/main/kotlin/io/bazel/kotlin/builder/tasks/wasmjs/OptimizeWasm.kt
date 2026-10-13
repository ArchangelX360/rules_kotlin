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

import io.bazel.kotlin.builder.utils.Flag
import io.bazel.worker.Status
import io.bazel.worker.Work
import io.bazel.worker.WorkerContext
import java.io.IOException
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.Path
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.streams.toList

/**
 * Runs binaryen's wasm-opt over every `.wasm` file of a linked directory for the WasmOptWasmJs
 * action, and copies the other files through unchanged.
 */
class OptimizeWasm : Work {
  companion object {
    @JvmStatic
    private val FLAGFILE_RE = Regex("""^--flagfile=((.*)-(\d+).params)$""")

    enum class OptimizeWasmFlags(
      override val flag: String,
    ) : Flag {
      INPUT_DIRECTORY("--input_directory"),
      OUTPUT_DIRECTORY("--output_directory"),
      FUNCTIONS_MAP_DIRECTORY("--functions_map_directory"),
      WASM_OPT("--wasm_opt"),
      WASM_OPT_ARG("--wasm_opt_arg"),
    }
  }

  override fun invoke(
    ctx: WorkerContext.TaskContext,
    args: Iterable<String>,
  ): Status {
    val execRoot = ctx.execRoot
    val valuesByFlag = getArgs(execRoot, args.toList())
    val failures =
      optimizeDirectory(
        inputDirectory = requiredPath(execRoot, valuesByFlag, OptimizeWasmFlags.INPUT_DIRECTORY),
        outputDirectory = requiredPath(execRoot, valuesByFlag, OptimizeWasmFlags.OUTPUT_DIRECTORY),
        functionsMapDirectory =
          requiredPath(execRoot, valuesByFlag, OptimizeWasmFlags.FUNCTIONS_MAP_DIRECTORY),
        wasmOpt = requiredPath(execRoot, valuesByFlag, OptimizeWasmFlags.WASM_OPT),
        wasmOptArgs = valuesByFlag[OptimizeWasmFlags.WASM_OPT_ARG.flag].orEmpty(),
        logDirectory = ctx.directory,
      )
    failures.forEach { failure -> ctx.error { failure } }
    return if (failures.isEmpty()) Status.SUCCESS else Status.ERROR
  }

  private fun requiredPath(
    execRoot: Path,
    valuesByFlag: Map<String, List<String>>,
    flag: OptimizeWasmFlags,
  ): Path =
    execRoot.resolve(
      requireNotNull(valuesByFlag[flag.flag]?.singleOrNull()) { "${flag.flag} is not optional" },
    )

  // The wasm-opt arguments start with `--`, so the flagfile has `--flag=value` lines, and not the
  // flag and value lines of ArgMaps.
  private fun getArgs(
    execRoot: Path,
    args: List<String>,
  ): Map<String, List<String>> {
    check(args.isNotEmpty()) { "expected at least a single arg got: ${args.joinToString(" ")}" }
    val lines =
      FLAGFILE_RE.matchEntire(args[0])?.groups?.get(1)?.let {
        Files.readAllLines(execRoot.resolve(it.value), StandardCharsets.UTF_8)
      } ?: args
    return lines
      .filter { it.isNotBlank() }
      .map { it.split('=', limit = 2) }
      .groupBy({ (flag, _) -> flag }, { (_, value) -> value })
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
