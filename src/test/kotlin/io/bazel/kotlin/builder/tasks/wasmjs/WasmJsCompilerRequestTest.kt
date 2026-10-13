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
import org.junit.Test
import java.io.File
import java.nio.file.Paths

class WasmJsCompilerRequestTest {
  private val execRoot = Paths.get("/exec/root").toAbsolutePath()

  private fun inRoot(path: String) = execRoot.resolve(path).toString()

  @Test
  fun resolvesEveryPathAgainstTheExecRoot() {
    val request =
      WasmJsCompilerRequest.parse(
        listOf(
          "-Xwasm-target=js",
          "-ir-output-name",
          "module",
          "-ir-output-dir",
          "bazel-out/bin/pkg",
          "-libraries",
          "a.klib${File.pathSeparator}b.klib",
          "-source-map-base-dirs",
          ".",
          "-Xinclude=bazel-out/bin/pkg/module.klib",
          "-Xplugin=plugin.jar",
          "-Xfragment-sources=common:src/A.kt",
          "--",
          "src/A.kt",
        ),
        execRoot,
      )

    assertThat(request.destination).isEqualTo(inRoot("bazel-out/bin/pkg"))
    assertThat(request.arguments)
      .containsExactly(
        "-Xwasm-target=js",
        "-ir-output-name",
        "module",
        "-libraries",
        "${inRoot("a.klib")}${File.pathSeparator}${inRoot("b.klib")}",
        "-source-map-base-dirs",
        execRoot.toString(),
        "-Xinclude=${inRoot("bazel-out/bin/pkg/module.klib")}",
        "-Xplugin=${inRoot("plugin.jar")}",
        "-Xfragment-sources=common:${inRoot("src/A.kt")}",
      ).inOrder()
    assertThat(request.sources).containsExactly(inRoot("src/A.kt"))
  }

  @Test
  fun aLinkRequestHasNoSources() {
    val request = WasmJsCompilerRequest.parse(listOf("-Xir-produce-js", "-ir-output-dir", "out"), execRoot)

    assertThat(request.sources).isEmpty()
    assertThat(request.arguments).containsExactly("-Xir-produce-js")
  }

  @Test(expected = IllegalArgumentException::class)
  fun theOutputDirectoryIsRequired() {
    WasmJsCompilerRequest.parse(listOf("-Xir-produce-js"), execRoot)
  }
}
