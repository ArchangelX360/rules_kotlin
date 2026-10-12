/*
 * Copyright 2020 The Bazel Authors. All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 *  Unless required by applicable law or agreed to in writing, software
 *  distributed under the License is distributed on an "AS IS" BASIS,
 *  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *  See the License for the specific language governing permissions and
 *  limitations under the License.
 *
 */

package io.bazel.worker

import com.google.devtools.build.lib.worker.ProtoWorkerMessageProcessor
import com.google.devtools.build.lib.worker.WorkRequestHandler
import com.google.devtools.build.lib.worker.WorkerProtocol
import java.io.IOException
import java.io.InputStream
import java.io.PrintStream
import java.io.PrintWriter
import java.nio.file.Paths
import java.time.Duration

/**
 * PersistentWorker satisfies Bazel persistent worker protocol for executing work.
 *
 * Supports multiplex (https://docs.bazel.build/versions/master/multiplex-worker.html) provided
 * the work is thread/coroutine safe, and cancellation provided the work stops on interruption.
 */
class PersistentWorker(
  private val input: InputStream = System.`in`,
  private val output: PrintStream = System.out,
) : Worker {
  override fun start(execute: Work): Int {
    return WorkerContext.run {
      val realStdErr = System.err
      try {
        val workerHandler: WorkRequestHandler =
          WorkRequestHandler
            .WorkRequestHandlerBuilder(
              WorkRequestHandler.WorkRequestCallback {
                request: WorkerProtocol.WorkRequest,
                pw: PrintWriter,
                ->
                return@WorkRequestCallback doTask(
                  name = "request ${request.requestId}",
                  sandboxDir = request.sandboxDir.takeIf { it.isNotEmpty() }?.let { Paths.get(it) },
                  inputDigests = request.inputDigests(),
                  task = request.workTo(execute),
                ).asResponse(pw)
              },
              realStdErr,
              ProtoWorkerMessageProcessor(input, output),
            ).setCpuUsageBeforeGc(Duration.ofSeconds(10))
            // Bazel sends cancel requests only to actions with `supports-worker-cancellation`.
            // The interrupt ends the task as an error, and the handler then reports it as cancelled.
            .setCancelCallback { _, thread -> thread.interrupt() }
            .build()
        workerHandler.processRequests()
      } catch (e: IOException) {
        this.error(e, { "Unknown IO exception" })
        e.printStackTrace(realStdErr)
        return@run 1
      }
      return@run 0
    }
  }

  private fun WorkerProtocol.WorkRequest.workTo(
    execute: Work,
  ): (sub: WorkerContext.TaskContext) -> Status =
    { ctx ->
      execute(ctx, argumentsList.toList())
    }

  /** The request input digests by execroot-relative path; Bazel sends each digest as hex text. */
  private fun WorkerProtocol.WorkRequest.inputDigests(): Map<String, String> =
    inputsList.associate { input -> input.path to input.digest.toStringUtf8() }

  private fun TaskResult.asResponse(pw: PrintWriter): Int {
    pw.print(log.out.toString())
    return status.exit
  }
}
