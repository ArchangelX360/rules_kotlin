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

import com.google.common.truth.Truth.assertThat
import io.bazel.worker.Status
import io.bazel.worker.WorkerContext
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.nio.file.Files
import java.nio.file.Path
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread

class OptimizeWasmTest {
  @get:Rule
  val tmp = TemporaryFolder()

  private fun fakeWasmOpt(
    root: Path,
    script: String,
  ): Path {
    val wasmOpt = root.resolve("wasm-opt")
    Files.write(wasmOpt, listOf("#!/bin/sh", script))
    wasmOpt.toFile().setExecutable(true)
    return wasmOpt
  }

  private fun sandbox(): Path {
    val root = tmp.newFolder().toPath()
    Files.createDirectories(root.resolve("linked/nested"))
    Files.write(root.resolve("linked/app.mjs"), listOf("export {}"))
    Files.write(root.resolve("linked/app.wasm"), listOf("wasm"))
    Files.write(root.resolve("linked/nested/lib.wasm"), listOf("wasm"))
    return root
  }

  private fun request(root: Path): Status {
    Files.write(
      root.resolve("request.params"),
      listOf(
        "--input-directory=linked",
        "--output-directory=optimized",
        "--functions-map-directory=functions",
        "--wasm-opt=wasm-opt",
        "--wasm-opt-arg=-O3",
      ),
    )
    return WorkerContext.run {
      doTask("wasm-opt", sandboxDir = root) { ctx -> OptimizeWasm()(ctx, listOf("--flagfile=request.params")) }.status
    }
  }

  @Test
  fun optimizesEveryWasmFileAndCopiesTheOthers() {
    val root = sandbox()
    // Arguments: -O3 <input> -o <output> --symbolmap=<map>
    fakeWasmOpt(root, "echo \"optimized $1\" > \"$4\" && echo map > \"${'$'}{5#--symbolmap=}\"")

    assertThat(request(root)).isEqualTo(Status.SUCCESS)

    assertThat(Files.readAllLines(root.resolve("optimized/app.mjs"))).containsExactly("export {}")
    assertThat(Files.readAllLines(root.resolve("optimized/app.wasm"))).containsExactly("optimized -O3")
    assertThat(Files.readAllLines(root.resolve("optimized/nested/lib.wasm"))).containsExactly("optimized -O3")
    assertThat(Files.isRegularFile(root.resolve("functions/app.txt"))).isTrue()
    assertThat(Files.isRegularFile(root.resolve("functions/lib.txt"))).isTrue()
  }

  @Test
  fun aWasmOptFailureFailsTheTask() {
    val root = sandbox()
    fakeWasmOpt(root, "echo broken; exit 3")

    assertThat(request(root)).isEqualTo(Status.ERROR)
  }

  @Test
  fun anInterruptKillsWasmOpt() {
    val root = sandbox()
    val started = root.resolve("started")
    fakeWasmOpt(root, "touch \"$started\"; exec sleep 600")

    val status = AtomicReference<Status>()
    val done = CountDownLatch(1)
    val request =
      thread {
        status.set(request(root))
        done.countDown()
      }
    val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(30)
    while (!Files.exists(started) && System.nanoTime() < deadline) {
      Thread.sleep(50)
    }
    assertThat(Files.exists(started)).isTrue()

    request.interrupt()

    assertThat(done.await(30, TimeUnit.SECONDS)).isTrue()
    assertThat(status.get()).isEqualTo(Status.ERROR)
  }
}
