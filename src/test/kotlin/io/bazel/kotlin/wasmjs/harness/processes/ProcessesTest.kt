// Copyright 2000-2026 JetBrains s.r.o. and contributors. Use of this source code is governed by the Apache 2.0 license.
package io.bazel.kotlin.wasmjs.harness.processes

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assume.assumeFalse
import org.junit.Test
import kotlin.time.Duration.Companion.seconds

class ProcessesTest {
  private val isWindows = System.getProperty("os.name").startsWith("Windows")

  private class Lines(private val firstLine: CompletableDeferred<String>) : ProcessOutputListener {
    override fun onStdoutLine(line: String, pid: Long) {
      firstLine.complete(line)
    }

    override fun onStderrLine(line: String, pid: Long) = Unit
  }

  @Test
  fun `the exit code of the process is returned`() = runBlocking {
    assumeFalse(isWindows)
    val exitCode = runProcess(listOf("sh", "-c", "echo done; exit 3"), Lines(CompletableDeferred()))
    assertEquals(3, exitCode)
  }

  @Test
  fun `a cancellation kills the process and its descendants`() = runBlocking {
    assumeFalse(isWindows)
    val childPid = CompletableDeferred<String>()
    // The shell prints the pid of its background child, then waits on it.
    val run = async { runProcess(listOf("sh", "-c", "sleep 600 & echo $!; wait"), Lines(childPid)) }
    val child = ProcessHandle.of(withTimeout(30.seconds) { childPid.await() }.trim().toLong()).orElseThrow()

    withTimeout(30.seconds) { run.cancelAndJoin() }

    assertFalse("the child process outlived the cancellation", child.isAlive)
  }
}
