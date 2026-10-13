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
import io.bazel.kotlin.builder.Deps.Dep
import io.bazel.kotlin.builder.toolchain.KotlinToolchain
import io.bazel.kotlin.builder.utils.BazelRunFiles
import io.bazel.worker.Status
import io.bazel.worker.WorkerContext
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.net.URLClassLoader
import java.nio.file.Files
import java.nio.file.Path

class CompileWasmJsTest {
  @get:Rule
  val tmp = TemporaryFolder()

  private val work by lazy {
    val classLoader =
      URLClassLoader(
        listOf("//kotlin/compiler:kotlin-compiler", "//src/main/kotlin/io/bazel/kotlin/compiler:compiler.jar")
          .map { File(Dep.fromLabel(it).singleCompileJar()).toURI().toURL() }
          .toTypedArray(),
        ClassLoader.getPlatformClassLoader(),
      )
    CompileWasmJs(KotlinToolchain.KotlincInvoker(classLoader, "io.bazel.kotlin.compiler.BazelK2WasmJsCompiler"))
  }

  private val stdlib by lazy {
    BazelRunFiles.resolveVerifiedFromProperty("@com_github_jetbrains_kotlin...kotlin-stdlib-wasm-js").absolutePath
  }

  private fun run(
    root: Path,
    vararg lines: String,
  ): Status {
    Files.write(root.resolve("request.params"), lines.toList())
    return WorkerContext.run {
      doTask("wasmjs", sandboxDir = root) { ctx -> work(ctx, listOf("--flagfile=request.params")) }.status
    }
  }

  @Test
  fun compilesAndLinksRelativeToTheSandbox() {
    val root = tmp.newFolder("sandbox").toPath()
    Files.createDirectories(root.resolve("src"))
    Files.write(root.resolve("src/Hello.kt"), listOf("fun main() { println(\"hello\") }"))

    val compile =
      run(
        root,
        "-Xwasm-target=js",
        "-ir-output-name",
        "hello",
        "-Xir-produce-klib-file",
        "-ir-output-dir",
        "out",
        "-libraries",
        stdlib,
        "--",
        "src/Hello.kt",
      )
    assertThat(compile).isEqualTo(Status.SUCCESS)
    assertThat(Files.isRegularFile(root.resolve("out/hello.klib"))).isTrue()

    val link =
      run(
        root,
        "-Xwasm-target=js",
        "-ir-output-name",
        "hello",
        "-Xir-produce-js",
        "-Xinclude=out/hello.klib",
        "-ir-output-dir",
        "link",
        "-libraries",
        "$stdlib${File.pathSeparator}out/hello.klib",
      )
    assertThat(link).isEqualTo(Status.SUCCESS)
    assertThat(Files.isRegularFile(root.resolve("link/hello.mjs"))).isTrue()
    assertThat(Files.isRegularFile(root.resolve("link/hello.wasm"))).isTrue()
  }

  @Test
  fun aCompilationErrorFailsTheTask() {
    val root = tmp.newFolder("broken").toPath()
    Files.write(root.resolve("Broken.kt"), listOf("fun main() { undefined() }"))

    val status =
      run(root, "-Xwasm-target=js", "-ir-output-name", "broken", "-ir-output-dir", "out", "-libraries", stdlib, "--", "Broken.kt")

    assertThat(status).isEqualTo(Status.ERROR)
  }
}
