/*
 * Copyright 2000-2026 JetBrains s.r.o. and contributors. Use of this source code is governed by the Apache 2.0 license.
 */

// The `runProcess` path of org.jetbrains.amper:async-processes 0.12.0-dev-4182 (org.jetbrains.amper.processes),
// with no change in behavior. The published jar targets Java 21.

package io.bazel.kotlin.wasmjs.harness.processes

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.future.await
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.IOException
import java.io.InputStream
import java.util.concurrent.TimeUnit
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds

interface ProcessOutputListener {
  fun onStdoutLine(
    line: String,
    pid: Long,
  )

  fun onStderrLine(
    line: String,
    pid: Long,
  )

  fun onProcessTerminated(
    exitCode: Int,
    pid: Long,
  ) {}
}

/**
 * Starts a new process with the given [command], and awaits its completion.
 * While waiting, stdout and stderr are sent to the given [outputListener].
 *
 * Nothing is sent to the standard input of the child process, the stream is immediately closed.
 *
 * If the current coroutine is cancelled before the process has terminated, the process is killed (first normally then
 * forcibly), and the stream readers cleaned up. If the process is not killable and hangs, this function will also hang
 * instead of returning (otherwise the zombie process could leak).
 *
 * **Note:** since the blocking reads of standard streams are not cancellable, this function may have to wait for the
 * read of the current line to complete before returning (on cancellation). This is to ensure no coroutines are leaked.
 * This wait should be reasonably short anyway because the process is killed on cancellation, so no more output
 * should be written in that case.
 *
 * If the JVM is terminated gracefully (Ctrl+C / SIGINT), this function **requests the process destruction** but doesn't
 * wait for its completion (we mustn't block the JVM shutdown).
 *
 * @return the exit code of the process
 */
suspend fun runProcess(
  command: List<String>,
  outputListener: ProcessOutputListener,
): Int {
  require(command.isNotEmpty()) { "Cannot start a process with an empty command line" }
  val builder = ProcessBuilder(command)
  return withContext(Dispatchers.IO) {
    builder.redirectOutput(ProcessBuilder.Redirect.PIPE)
    builder.redirectError(ProcessBuilder.Redirect.PIPE)
    builder.redirectInput(ProcessBuilder.Redirect.PIPE)
    builder.start().withGuaranteedTermination { process ->
      launch {
        // input writing is asynchronous
        process.outputStream.close()
      }
      process.awaitListening(outputListener)
    }
  }
}

/**
 * The default grace period to use in functions that provide this option.
 *
 * The grace period is the time to wait between a regular process destruction request and forcible destruction.
 * If a process doesn't terminate within the grace period after its destruction is requested, it is forcibly destroyed.
 */
private val DefaultGracePeriod = 3.seconds

/**
 * Awaits the termination of this [Process] in a suspending and cancellable way.
 *
 * The given [outputListener] is used to handle lines of output from stdout/stderr while the process is running (for
 * instance to print them to the console).
 *
 * **Important:** the stream collection is performed on the current coroutine context, the dispatcher of which must
 * provide **at least 2 threads** (to perform blocking reads of stdout and stderr in parallel). It is the responsibility
 * of the caller to provide a suitable dispatcher.
 *
 * If this function is cancelled, the cancellation is immediate, but **the process is untouched and can keep running**.
 * The same applies if any exception is thrown (for instance, IO exceptions while reading streams).
 * The caller is responsible for ensuring the process doesn't leak, for instance using [withGuaranteedTermination].
 *
 * **Implementation note:** this function always waits for the coroutines reading IO streams to finish before returning,
 * ensuring we don't leak any coroutine nor hold on to extra threads. Non-network IO reads are not cancellable, but the
 * readers are made partially cooperative by allowing cancellation between each line read, so they don't have to keep
 * reading the whole stream if the result is meant to be discarded anyway.
 */
private suspend fun Process.awaitListening(outputListener: ProcessOutputListener): Int =
  coroutineScope {
    val pid = pid()
    launch {
      inputStream.consumeLinesBlockingCancellable {
        outputListener.onStdoutLine(it, pid)
      }
    }
    launch {
      errorStream.consumeLinesBlockingCancellable {
        outputListener.onStderrLine(it, pid)
      }
    }

    // This is async: onExit() runs on the ForkJoinPool so it doesn't hold the current thread.
    // This is why we only really need 2 threads in the current dispatcher (to consume stdout and stderr).
    onExit().await().exitValue().also { exitCode ->
      outputListener.onProcessTerminated(exitCode, pid)
    }
  }

/**
 * Consumes this input stream by reading the data as UTF-8 text line-by-line, and calls [onEachLine] on each line.
 *
 * **WARNING:** this suspending function blocks the thread despite the suspend keyword!
 *
 * This function complies with coroutine cancellation by checking for cancellation between each line read. However, a
 * single line read blocks the thread and cannot be canceled until it returns (interruption doesn't work on them).
 */
private suspend inline fun InputStream.consumeLinesBlockingCancellable(
  onEachLine: (String) -> Unit,
) {
  bufferedReader().useLines { lines ->
    try {
      lines.forEach {
        onEachLine(it)

        // We cooperate with cancellation by checking for it between each line read.
        currentCoroutineContext().ensureActive()
      }
    } catch (e: IOException) {
      // If the process is killed externally on unix systems, the stream is eagerly closed,
      // and reading from the sequence throws an IOException with "Stream closed" message,
      // sometimes capitalized as "Stream Closed", or "Bad file descriptor".
      // This check is brittle, but it's kind of the only way to account for this situation
      // by considering this exception as the end of the process output instead of crashing.
      if (e.message?.lowercase() in setOf("stream closed", "bad file descriptor")) {
        return
      }
      throw e
    }
  }
}

/**
 * Executes the given [cancellableBlock], and waits for the process's termination.
 * When this function terminates (normally or exceptionally), the process is guaranteed to be terminated:
 *
 * * If [cancellableBlock] completes successfully, this function simply waits for the termination of this process
 *   **without destroying it**.
 * * If [cancellableBlock] throws an exception, this function **destroys the process** and awaits its termination.
 * * If the current coroutine is canceled, this function **destroys the process** and awaits its termination.
 *   This is true whether the current coroutine is already canceled when calling this function, canceled during the
 *   execution of [cancellableBlock], or canceled after the successful completion of [cancellableBlock] (while waiting
 *   for the process to terminate).
 * * If the JVM is terminated gracefully (Ctrl+C / SIGINT), this function **destroys the process** and waits for its
 *   termination.
 *
 * In cases where the process is destroyed, normal destruction is requested first, and if this process doesn't
 * terminate within the given [gracePeriod], it is then _forcibly destroyed_.
 *
 * This function always waits for the process to actually terminate before re-throwing an exception (such as
 * [CancellationException]) to make sure this process doesn't leak. If this process is not killable and hangs, this
 * function also hangs instead of returning and leaking this zombie process.
 */
private suspend inline fun <T> Process.withGuaranteedTermination(
  gracePeriod: Duration = DefaultGracePeriod,
  crossinline cancellableBlock: suspend CoroutineScope.(Process) -> T,
): T {
  withDestructionHook(gracePeriod) {
    try {
      // jump straight to the catch block if the coroutine is already canceled
      currentCoroutineContext().ensureActive()

      // This `coroutineScope` inside a try-catch catches exceptions from coroutines that are started in
      // `cancellableBlock`, to make sure we always terminate the process.
      return coroutineScope {
        // This manual cancellation tracking kills the process even if `cancellableBlock` blocks without
        // respecting coroutine cancellations, which the uninterruptible line reads of the streams do.
        val cancellationTrackingJob =
          launch {
            try {
              awaitCancellation()
            } catch (e: CancellationException) {
              withContext(NonCancellable) {
                killAndAwaitTermination(gracePeriod)
              }
              throw e
            }
          }
        cancellableBlock(this@withGuaranteedTermination).also {
          onExit().await()
          // This triggers the kill-on-cancellation of the cancellationTrackingJob, but
          // killAndAwaitTermination is a no-op in this case.
          cancellationTrackingJob.cancel()
        }
      }
    } catch (e: Throwable) {
      // Exceptions, errors and cancellations all kill the process, by contract. A second
      // killAndAwaitTermination is a no-op.
      withContext(NonCancellable) {
        killAndAwaitTermination(gracePeriod)
      }
      throw e
    }
  }
}

/**
 * Executes the given [block], but also ensures that the process is destroyed in case the JVM is killed (e.g. Ctrl+C)
 * during the execution.
 *
 * A shutdown hook is registered before running [block], and unregistered when the given [block] completes (normally or
 * exceptionally). The shutdown hook destroys this [Process] and waits for its termination. If this process doesn't
 * terminate within the given [gracePeriod], it is _forcibly destroyed_, but still awaited.
 */
private inline fun <T> Process.withDestructionHook(
  gracePeriod: Duration = DefaultGracePeriod,
  block: (Process) -> T,
): T {
  val command =
    try {
      info().commandLine().orElse("")
    } catch (_: UnsupportedOperationException) {
      // it's ok if the Process doesn't support providing info(), we can just omit the command name
      ""
    }
  return withShutdownHook(
    name = "Destroyer for PID=${pid()}: $command",
    onJvmShutdown = { killAndAwaitTermination(gracePeriod) },
  ) {
    block(this)
  }
}

private inline fun <T> withShutdownHook(
  name: String,
  crossinline onJvmShutdown: () -> Unit,
  block: () -> T,
): T {
  val hookThread = Thread(null, { onJvmShutdown() }, name)
  val runtime = Runtime.getRuntime()
  try {
    runtime.addShutdownHook(hookThread)
  } catch (e: IllegalStateException) {
    // IllegalStateException is thrown if the JVM is already shutting down (it's the only documented case).
    // In this case, we can't register the hook, but we still run the onJvmShutdown callback immediately.
    onJvmShutdown()
    throw e
  }
  try {
    return block()
  } finally {
    try {
      runtime.removeShutdownHook(hookThread)
    } catch (_: IllegalStateException) {
      // The JVM is already shutting down, so the hook needs no unregistration.
    }
  }
}

/**
 * Kills this process and its descendants (first normally, then forcibly) and waits for their termination in a
 * non-cancellable way. If this process is already not alive, this function doesn't do anything and returns immediately.
 *
 * If this process doesn't die within [gracePeriod] after the normal termination request, it is forcibly destroyed.
 * If this process is not killable and hangs, this function also hangs instead of returning and leaking this zombie process.
 *
 * @throws InterruptedException if the current thread is interrupted while waiting for the process to terminate
 */
private fun Process.killAndAwaitTermination(gracePeriod: Duration = DefaultGracePeriod): Int {
  destroyHierarchy()
  // the destroy operation is asynchronous, we need to give this process a chance to complete gracefully
  val completed = waitFor(gracePeriod.inWholeMilliseconds, TimeUnit.MILLISECONDS)
  if (completed) {
    return exitValue()
  }
  destroyHierarchyForcibly()
  // The forced destroy operation is asynchronous, so we need to wait until this process is actually terminated.
  return waitFor()
}

/** Requests the process and all its descendants to be killed. If the process is not alive, no action is taken. */
private fun Process.destroyHierarchy() {
  descendants().forEach { it.destroy() }
  destroy()
}

/** Kills the process and all descendants forcibly. If the process is not alive, no action is taken. */
private fun Process.destroyHierarchyForcibly() {
  descendants().forEach { it.destroyForcibly() }
  destroyForcibly()
}
