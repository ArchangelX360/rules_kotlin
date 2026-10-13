// Copyright 2000-2026 JetBrains s.r.o. and contributors. Use of this source code is governed by the Apache 2.0 license.
package io.bazel.kotlin.wasmjs.harness

import io.bazel.kotlin.wasmjs.harness.cli.BazelRunnerInvocationTest
import io.bazel.kotlin.wasmjs.harness.cli.BazelTestEnvironmentTest
import io.bazel.kotlin.wasmjs.harness.cli.TestRunExecutionTestState
import io.bazel.kotlin.wasmjs.harness.processes.ProcessesTest
import io.bazel.kotlin.wasmjs.harness.runner.JUnitXmlWriterTest
import io.bazel.kotlin.wasmjs.harness.runner.IndexHtmlGeneratorTest
import io.bazel.kotlin.wasmjs.harness.runner.NpmEntryResolverTest
import io.bazel.kotlin.wasmjs.harness.runner.StaticServerTest
import io.bazel.kotlin.wasmjs.harness.runner.TestPageUriTest
import io.bazel.kotlin.wasmjs.harness.runner.TestRunStateTests
import org.junit.runner.RunWith
import org.junit.runners.Suite

@RunWith(Suite::class)
@Suite.SuiteClasses(
  TestRunStateTests::class,
  JUnitXmlWriterTest::class,
  NpmEntryResolverTest::class,
  IndexHtmlGeneratorTest::class,
  StaticServerTest::class,
  TestPageUriTest::class,
  BazelRunnerInvocationTest::class,
  BazelTestEnvironmentTest::class,
  TestRunExecutionTestState::class,
  ProcessesTest::class,
  // Fails when a test class exists on the classpath but is missing from this list.
  AllTestsCompletenessTest::class,
)
class AllTests
