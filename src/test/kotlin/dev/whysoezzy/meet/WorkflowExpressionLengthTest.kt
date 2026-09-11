package dev.whysoezzy.meet

import dev.whysoezzy.meet.support.WorkflowExpressionLength
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import org.yaml.snakeyaml.LoaderOptions
import org.yaml.snakeyaml.Yaml
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
        val scalar = "'".repeat(156) + "a".repeat(22_194) +
            List(4) { "\${{ x }}" }.joinToString("")
        val accounting = WorkflowExpressionLength.accountScalar(scalar)

        assertEquals(22_382, accounting.decodedLength)
        assertEquals(22_540, accounting.generatedLength)
        assertEquals(4, accounting.expressionCount)
        assertTrue(accounting.generatedLength!! > WorkflowExpressionLength.LIMIT)
    }
}
