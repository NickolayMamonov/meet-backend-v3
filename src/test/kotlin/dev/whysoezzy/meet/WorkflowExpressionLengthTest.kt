package dev.whysoezzy.meet

import dev.whysoezzy.meet.support.WorkflowExpressionLength
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import org.yaml.snakeyaml.LoaderOptions
import org.yaml.snakeyaml.Yaml
import org.yaml.snakeyaml.nodes.MappingNode
import org.yaml.snakeyaml.nodes.Node
import org.yaml.snakeyaml.nodes.ScalarNode
import org.yaml.snakeyaml.nodes.SequenceNode
import java.io.StringReader
import java.nio.file.Files
import java.nio.file.Path
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class WorkflowExpressionLengthTest {

    @Test
    fun `all repository workflows fit the decoded and generated budgets`() {
        val measurements = WorkflowExpressionLength.assertWithinLimits(Path.of("."))

        assertTrue(measurements.isNotEmpty())
        assertTrue(measurements.any { it.kind == WorkflowExpressionLength.ScalarKind.RUN })
        assertTrue(measurements.any { it.accounting.expressionCount > 0 })
        assertFalse(measurements.any { it.accounting.generatedLength ?: 0 > WorkflowExpressionLength.LIMIT })
    }

    @Test
    fun `whole expression accepts exactly the limit and rejects one more`() {
        val atLimit = "\${{ ${"x".repeat(WorkflowExpressionLength.LIMIT)} }}"
        assertEquals(WorkflowExpressionLength.LIMIT, WorkflowExpressionLength.accountScalar(atLimit).generatedLength)

        val overLimit = "\${{ ${"x".repeat(WorkflowExpressionLength.LIMIT + 1)} }}"
        assertThrows<WorkflowExpressionLength.Violation> {
            WorkflowExpressionLength.accountScalar(overLimit)
        }
    }

    @Test
    fun `mixed expressions account for format escaping and all arguments`() {
        val value = "prefix '{' \${{ github.ref }} and \${{ inputs.value }} '}'"
        val accounting = WorkflowExpressionLength.accountScalar(value)

        assertEquals(2, accounting.expressionCount)
        assertTrue(accounting.generatedLength!! > value.length)
        assertEquals(
            WorkflowExpressionLength.accountScalar("x \${{ github.ref }}").generatedLength,
            "format('x {0}', github.ref)".length,
        )
    }

    @Test
    fun `conditions include the implicit success wrapper only for non status expressions`() {
        assertEquals(
            "success() && (github.ref == 'refs/heads/dev')".length,
            WorkflowExpressionLength.accountCondition("github.ref == 'refs/heads/dev'").generatedLength,
        )
        assertEquals(
            "always()".length,
            WorkflowExpressionLength.accountCondition("always()").generatedLength,
        )
        assertEquals(
            "success()".length,
            WorkflowExpressionLength.accountCondition("").generatedLength,
        )
        assertEquals(
            "success() && (failure-marker())".length,
            WorkflowExpressionLength.accountCondition("failure-marker()").generatedLength,
        )
    }

    @Test
    fun `conditions decode whole string literals before status conversion`() {
        assertEquals(
            "always()".length,
            WorkflowExpressionLength.accountCondition("\${{ 'always()' }}").generatedLength,
        )
        assertEquals(
            "success() && (a'b)".length,
            WorkflowExpressionLength.accountCondition("\${{ 'a''b' }}").generatedLength,
        )
    }

    @Test
    fun `conditions use the declared dotnet whitespace set`() {
        assertEquals(
            "success()".length,
            WorkflowExpressionLength.accountCondition("\u0085").generatedLength,
        )
        assertEquals(
            "success()".length,
            WorkflowExpressionLength.accountCondition("\u00A0").generatedLength,
        )
        assertEquals(
            "success() && (\uFEFF)".length,
            WorkflowExpressionLength.accountCondition("\uFEFF").generatedLength,
        )

        val prefix = "success() && ("
        val body = "x".repeat(WorkflowExpressionLength.LIMIT - prefix.length - 1)
        assertEquals(
            WorkflowExpressionLength.LIMIT,
            WorkflowExpressionLength.accountCondition(body).generatedLength,
        )
        assertThrows<WorkflowExpressionLength.Violation> {
            WorkflowExpressionLength.accountCondition("$body-x")
        }
    }

    @Test
    fun `status recognition is token aware and case insensitive`() {
        assertEquals(
            "SUCCESS()".length,
            WorkflowExpressionLength.accountCondition("SUCCESS()").generatedLength,
        )
        assertEquals(
            "success ( )".length,
            WorkflowExpressionLength.accountCondition("success ( )").generatedLength,
        )
        for (separator in listOf("\u0085", "\u00A0")) {
            val statusCall = "success${separator}()"
            val body = "x".repeat(WorkflowExpressionLength.LIMIT - statusCall.length)
            assertEquals(
                WorkflowExpressionLength.LIMIT,
                WorkflowExpressionLength.accountCondition(statusCall + body).generatedLength,
            )
            assertThrows<WorkflowExpressionLength.Violation> {
                WorkflowExpressionLength.accountCondition(statusCall + body + "x")
            }
        }
        for (separator in listOf(" ", "\u0085", "\u00A0", "\u202F")) {
            assertEquals(
                "success() && (github.${separator}success())".length,
                WorkflowExpressionLength.accountCondition("github.${separator}success()").generatedLength,
            )
        }
        assertEquals(
            "success() && ('success()')".length,
            WorkflowExpressionLength.accountCondition("'success()'").generatedLength,
        )
        assertEquals(
            "success() && (github.success())".length,
            WorkflowExpressionLength.accountCondition("github.success()").generatedLength,
        )
        assertEquals(
            "success() && (success)".length,
            WorkflowExpressionLength.accountCondition("success").generatedLength,
        )
        assertEquals(
            "success() && (failure-marker())".length,
            WorkflowExpressionLength.accountCondition("failure-marker()").generatedLength,
        )
    }

    @Test
    fun `surrounding dotnet whitespace remains in runner-shaped expression accounting`() {
        fun scalarValue(body: String) = "  \${{ $body }}  "
        fun scalarGenerated(body: String) = "format('  {0}  ', $body)"

        val scalarBody = "x".repeat(
            WorkflowExpressionLength.LIMIT - scalarGenerated("").length,
        )
        assertEquals(
            WorkflowExpressionLength.LIMIT,
            WorkflowExpressionLength.accountScalar(scalarValue(scalarBody)).generatedLength,
        )
        assertEquals(
            WorkflowExpressionLength.LIMIT + 1,
            WorkflowExpressionLength.accountScalar(scalarValue("${scalarBody}x")).generatedLength,
        )

        fun nonStatusConditionValue(body: String) = scalarValue(body)
        fun nonStatusConditionGenerated(body: String) =
            "success() && (${scalarGenerated(body)})"

        val nonStatusBody = "x".repeat(
            WorkflowExpressionLength.LIMIT - nonStatusConditionGenerated("").length,
        )
        assertEquals(
            WorkflowExpressionLength.LIMIT,
            WorkflowExpressionLength.accountCondition(nonStatusConditionValue(nonStatusBody)).generatedLength,
        )
        assertThrows<WorkflowExpressionLength.Violation> {
            WorkflowExpressionLength.accountCondition(nonStatusConditionValue("${nonStatusBody}x"))
        }

        fun statusConditionValue(body: String) = "  \${{ success() + $body }}  "
        fun statusConditionGenerated(body: String) =
            "format('  {0}  ', success() + $body)"

        val statusBody = "x".repeat(
            WorkflowExpressionLength.LIMIT - statusConditionGenerated("").length,
        )
        assertEquals(
            WorkflowExpressionLength.LIMIT,
            WorkflowExpressionLength.accountCondition(statusConditionValue(statusBody)).generatedLength,
        )
        assertThrows<WorkflowExpressionLength.Violation> {
            WorkflowExpressionLength.accountCondition(statusConditionValue("${statusBody}x"))
        }
    }

    @Test
    fun `yaml decoding and utf16 accounting happen before the limit check`() {
        val yaml = """
            jobs:
              fixture:
                if: "  ${'$'}{{ 'quoted }} text' }}  "
                steps:
                  - run: |-
                      echo "é𝄞"
        """.trimIndent()
        val node = Yaml(LoaderOptions()).compose(StringReader(yaml))
        assertTrue(node != null)
        assertEquals(3, "é𝄞".length)
        assertEquals(1, WorkflowExpressionLength.accountScalar("\${{ 'quoted }} text' }}").expressionCount)
    }

    @Test
    fun `structural workflow recognition distinguishes jobs and steps`() {
        val long = "x".repeat(WorkflowExpressionLength.LIMIT + 1)
        val yaml = """
            name: structural fixture
            jobs:
              build:
                if: github.ref == 'refs/heads/dev'
                env:
                  run: "$long"
                steps:
                  - if: always()
                    with:
                      if: "$long"
                    run: echo ok
        """.trimIndent()
        val root = Files.createTempDirectory("workflow-expression-structure-")
        try {
            Files.createDirectories(root.resolve(".github/workflows"))
            Files.writeString(root.resolve(".github/workflows/fixture.yml"), yaml)
            val measurements = WorkflowExpressionLength.assertWithinLimits(root)
            assertTrue(
                measurements.any {
                    it.kind == WorkflowExpressionLength.ScalarKind.RUN &&
                        it.location.structuralPath == "root.jobs.job[0].steps[0].run"
                },
            )
            assertTrue(
                measurements.count {
                    it.kind == WorkflowExpressionLength.ScalarKind.CONDITION_WRAPPER
                } == 2,
            )
            assertFalse(
                measurements.any {
                    it.kind == WorkflowExpressionLength.ScalarKind.RUN &&
                        it.location.structuralPath.endsWith(".env.run")
                },
            )
            assertFalse(
                measurements.any {
                    it.kind == WorkflowExpressionLength.ScalarKind.CONDITION_WRAPPER &&
                        it.location.structuralPath.endsWith(".with.if")
                },
            )
        } finally {
            Files.walk(root).sorted(Comparator.reverseOrder()).forEach(Files::deleteIfExists)
        }
    }

    @Test
    fun `malformed input diagnostics do not include scalar payloads`() {
        val canary = "do-not-print-this-sensitive-canary"
        val error = assertThrows<WorkflowExpressionLength.Violation> {
            WorkflowExpressionLength.accountScalar("\${{ $canary")
        }
        assertFalse(error.message.orEmpty().contains(canary))

        val temporary = Files.createTempFile("workflow-expression-", ".yml")
        try {
            Files.writeString(temporary, "jobs:\n  fixture: [\n")
            val root = Files.createTempDirectory("workflow-expression-root-")
            try {
                Files.createDirectories(root.resolve(".github/workflows"))
                Files.copy(temporary, root.resolve(".github/workflows/bad.yml"))
                val parseError = assertThrows<WorkflowExpressionLength.Violation> {
                    WorkflowExpressionLength.scanRepository(root)
                }
                assertFalse(parseError.message.orEmpty().contains(canary))
            } finally {
                Files.walk(root).sorted(Comparator.reverseOrder()).forEach(Files::deleteIfExists)
            }
        } finally {
            Files.deleteIfExists(temporary)
        }
    }

    @Test
    fun `original promotion scalar regression keeps its measured baseline`() {
        val resource = Path.of("src/test/resources/workflow-expression-length/original-promotion-scalar.yml")
        val document = Files.newBufferedReader(resource).use { Yaml(LoaderOptions()).compose(it) }
        assertTrue(document != null)
        val jobs = mappingValue(document!!, "jobs") as MappingNode
        val fixture = mappingValue(jobs, "fixture") as MappingNode
        val steps = mappingValue(fixture, "steps") as SequenceNode
        val run = mappingValue(steps.value.single() as MappingNode, "run") as ScalarNode
        val scalar = run.value
        val accounting = WorkflowExpressionLength.accountScalar(scalar)

        assertEquals(22_382, accounting.decodedLength)
        assertEquals(22_540, accounting.generatedLength)
        assertEquals(4, accounting.expressionCount)
        assertTrue(accounting.generatedLength!! > WorkflowExpressionLength.LIMIT)
    }

    private fun mappingValue(mapping: Node, key: String): Node =
        (mapping as MappingNode).value
            .first { (it.keyNode as ScalarNode).value == key }
            .valueNode
}
