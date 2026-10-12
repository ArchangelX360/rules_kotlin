/*
 * Copyright 2026 The Bazel Authors. All rights reserved.
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

import com.google.common.truth.Truth.assertThat
import com.google.devtools.build.lib.worker.WorkerProtocol.WorkRequest
import com.google.devtools.build.lib.worker.WorkerProtocol.WorkResponse
import io.bazel.worker.Status.SUCCESS
import org.junit.Test
import java.io.PipedInputStream
import java.io.PipedOutputStream
import java.io.PrintStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

class PersistentWorkerTest {
  @Test
  fun cancelRequestInterruptsTheTask() {
    val toWorker = PipedOutputStream()
    val workerInput = PipedInputStream(toWorker)
    val fromWorker = PipedInputStream()
    val workerOutput = PrintStream(PipedOutputStream(fromWorker), true)

    val started = CountDownLatch(1)
    val interrupted = AtomicBoolean(false)
    val worker =
      thread {
        PersistentWorker(workerInput, workerOutput).start { _, _ ->
          started.countDown()
          try {
            Thread.sleep(TimeUnit.MINUTES.toMillis(1))
          } catch (e: InterruptedException) {
            interrupted.set(true)
            throw e
          }
          SUCCESS
        }
      }

    WorkRequest.newBuilder().setRequestId(1).build().writeDelimitedTo(toWorker)
    assertThat(started.await(10, TimeUnit.SECONDS)).isTrue()
    WorkRequest.newBuilder().setRequestId(1).setCancel(true).build().writeDelimitedTo(toWorker)

    val response = WorkResponse.parseDelimitedFrom(fromWorker)
    toWorker.close()
    worker.join(TimeUnit.SECONDS.toMillis(10))

    assertThat(interrupted.get()).isTrue()
    assertThat(response.requestId).isEqualTo(1)
    assertThat(response.wasCancelled).isTrue()
  }
}
