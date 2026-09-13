package dev.whysoezzy.meet.support

import org.yaml.snakeyaml.LoaderOptions
import org.yaml.snakeyaml.Yaml
import org.yaml.snakeyaml.nodes.AnchorNode
import org.yaml.snakeyaml.nodes.MappingNode
import org.yaml.snakeyaml.nodes.Node
import org.yaml.snakeyaml.nodes.ScalarNode
import org.yaml.snakeyaml.nodes.SequenceNode
import java.io.Reader
import java.nio.file.Files
import java.nio.file.Path
import java.util.Collections
import java.util.IdentityHashMap

/**
 * Offline accounting reference for the GitHub Actions template compiler.
 *
 * The accounting follows actions/runner commit
 * 759385a3510197a58b5c08dc1f373b74b9f4643b:
 * TemplateReader.ParseScalar/ParseExpression, ExpressionParser.ParseContext,
 * ExpressionConstants.MaxLength, PipelineTemplateConverter.ConvertToIfCondition
 * and ExpressionUtility.StringEscape. It is deliberately a guard, not a
 * replacement for actionlint or the hosted compiler.
 */
object WorkflowExpressionLength {
    const val LIMIT = 21_000
    private const val MAX_NODES = 100_000
    private const val MAX_ALIASES = 100

    data class Location(
        val workflow: Path,
        val structuralPath: String,
        val line: Int,
        val column: Int,
    )

    data class Accounting(
        val decodedLength: Int,
        val generatedLength: Int?,
        val expressionCount: Int,
    )

    enum class ScalarKind {
        SCALAR,
        RUN,
        EXPRESSION,
        CONDITION,
        CONDITION_WRAPPER,
    }

    data class Measurement(
        val location: Location,
        val kind: ScalarKind,
        val accounting: Accounting,
    )

    class Violation(message: String) : IllegalArgumentException(message)

    fun scanRepository(root: Path = Path.of(".")): List<Measurement> {
        val workflowRoot = root.resolve(".github/workflows")
        val files = if (Files.isDirectory(workflowRoot)) {
            Files.walk(workflowRoot).use { paths ->
                paths.filter { Files.isRegularFile(it) }
                    .filter { it.fileName.toString().endsWith(".yml") || it.fileName.toString().endsWith(".yaml") }
                    .sorted()
                    .toList()
            }
        } else {
            emptyList()
        }
        if (files.isEmpty()) {
            throw Violation("workflow expression inventory is empty")
        }
        return files.flatMap { scanWorkflow(root, it) }
    }

    fun assertWithinLimits(root: Path = Path.of(".")): List<Measurement> {
        val measurements = scanRepository(root)
        val violations = measurements.flatMap { measurement ->
            val accounting = measurement.accounting
            buildList {
                if (measurement.kind == ScalarKind.RUN && accounting.decodedLength > LIMIT) {
                    add(
                        "${formatLocation(measurement.location)} decoded run scalar " +
                            "length ${accounting.decodedLength} exceeds limit $LIMIT",
                    )
                }
                if (accounting.generatedLength != null && accounting.generatedLength > LIMIT) {
                    add(
                        "${formatLocation(measurement.location)} generated expression " +
                            "length ${accounting.generatedLength} exceeds limit $LIMIT",
                    )
                }
            }
        }
        if (violations.isNotEmpty()) {
            throw Violation(violations.joinToString("; "))
        }
        return measurements
    }

    fun accountScalar(value: String): Accounting {
        val expressions = findExpressions(value)
        if (expressions.isEmpty()) {
            return Accounting(value.length, null, 0)
        }
        expressions.forEach { expression ->
            if (expression.trimmed.length > LIMIT) {
                throw Violation(
                    "embedded expression length ${expression.trimmed.length} exceeds limit $LIMIT",
                )
            }
        }
        return Accounting(value.length, generatedExpression(value, expressions).length, expressions.size)
    }

    fun accountCondition(value: String): Accounting {
        val expressions = findExpressions(value)
        accountScalar(value)
        val condition = if (expressions.size == 1 && expressions.single().covers(value)) {
            decodeSingleStringLiteral(expressions.single().trimmed)
                ?: expressions.single().trimmed
        } else if (expressions.isNotEmpty()) {
            generatedExpression(value, expressions)
        } else {
            value
        }
        val converted = when {
            trimDotNetWhitespace(condition).isEmpty() -> "success()"
            hasStatusFunction(condition) -> condition
            else -> "success() && ($condition)"
        }
        if (converted.length > LIMIT) {
            throw Violation("generated condition length ${converted.length} exceeds limit $LIMIT")
        }
        return Accounting(value.length, converted.length, expressions.size)
    }

    private fun scanWorkflow(root: Path, workflow: Path): List<Measurement> {
        val options = LoaderOptions().apply {
            codePointLimit = 5_000_000
            maxAliasesForCollections = MAX_ALIASES
            allowRecursiveKeys = false
        }
        val documents = try {
            Files.newBufferedReader(workflow).use { reader: Reader ->
                Yaml(options).composeAll(reader).toList()
            }
        } catch (_: Exception) {
            throw Violation("invalid workflow YAML at ${root.relativize(workflow)}")
        }
        if (documents.size != 1) {
            throw Violation("workflow document count is invalid at ${root.relativize(workflow)}")
        }
        val measurements = ArrayList<Measurement>()
        val active = Collections.newSetFromMap(IdentityHashMap<Node, Boolean>())
        walk(
            root = root,
            workflow = workflow,
            node = documents.single(),
            path = "root",
            context = SchemaContext.ROOT,
            active = active,
            measurements = measurements,
            nodeCount = IntArray(1),
        )
        return measurements
    }

    private fun walk(
        root: Path,
        workflow: Path,
        node: Node?,
        path: String,
        context: SchemaContext,
        active: MutableSet<Node>,
        measurements: MutableList<Measurement>,
        nodeCount: IntArray,
    ) {
        if (node == null) return
        nodeCount[0]++
        if (nodeCount[0] > MAX_NODES) {
            throw Violation("workflow node limit exceeded at ${root.relativize(workflow)}")
        }
        val realNode = if (node is AnchorNode) node.realNode else node
        if (!active.add(realNode)) {
            throw Violation("recursive YAML alias at ${root.relativize(workflow)}")
        }
        try {
            when (realNode) {
                is ScalarNode -> {
                    recordScalar(root, workflow, realNode, path, false, false, measurements)
                }
                is MappingNode -> {
                    realNode.value.forEachIndexed { index, tuple ->
                        val key = (tuple.keyNode as? ScalarNode)?.value
                        val field = structuralField(context, key, index)
                        val childPath = "$path.$field"
                        if (tuple.keyNode is ScalarNode) {
                            recordScalar(root, workflow, tuple.keyNode as ScalarNode, childPath, false, false, measurements)
                        } else {
                            walk(
                                root,
                                workflow,
                                tuple.keyNode,
                                "$childPath.key$index",
                                SchemaContext.OTHER,
                                active,
                                measurements,
                                nodeCount,
                            )
                        }
                        val child = tuple.valueNode
                        val realChild = unwrap(child)
                        val isRun = context == SchemaContext.STEP && key == "run"
                        val isCondition =
                            (context == SchemaContext.JOB || context == SchemaContext.STEP) && key == "if"
                        if (realChild is ScalarNode) {
                            recordScalar(root, workflow, realChild, childPath, isRun, isCondition, measurements)
                        } else {
                            walk(
                                root,
                                workflow,
                                child,
                                childPath,
                                childContext(context, key, realChild),
                                active,
                                measurements,
                                nodeCount,
                            )
                        }
                    }
                }
                is SequenceNode -> {
                    realNode.value.forEachIndexed { index, child ->
                        walk(
                            root,
                            workflow,
                            child,
                            "$path[$index]",
                            if (context == SchemaContext.STEPS) SchemaContext.STEP else SchemaContext.OTHER,
                            active,
                            measurements,
                            nodeCount,
                        )
                    }
                }
            }
        } finally {
            active.remove(realNode)
        }
    }

    private enum class SchemaContext {
        ROOT,
        JOBS,
        JOB,
        STEPS,
        STEP,
        OTHER,
    }

    private fun childContext(context: SchemaContext, key: String?, child: Node): SchemaContext =
        when {
            context == SchemaContext.ROOT && key == "jobs" && child is MappingNode -> SchemaContext.JOBS
            context == SchemaContext.JOBS && child is MappingNode -> SchemaContext.JOB
            context == SchemaContext.JOB && key == "steps" && child is SequenceNode -> SchemaContext.STEPS
            else -> SchemaContext.OTHER
        }

    private fun unwrap(node: Node): Node =
        if (node is AnchorNode) node.realNode else node

    private fun structuralField(context: SchemaContext, key: String?, index: Int): String =
        if (context == SchemaContext.JOBS) {
            "job[$index]"
        } else {
            key?.takeIf { it in SAFE_STRUCTURAL_FIELDS } ?: "field"
        }

    private fun recordScalar(
        root: Path,
        workflow: Path,
        node: ScalarNode,
        path: String,
        isRun: Boolean,
        isCondition: Boolean,
        measurements: MutableList<Measurement>,
    ) {
        val location = Location(
            workflow = root.relativize(workflow),
            structuralPath = path,
            line = node.startMark?.line?.plus(1) ?: 0,
            column = node.startMark?.column?.plus(1) ?: 0,
        )
        val accounting = try {
            accountScalar(node.value)
        } catch (error: Violation) {
            throw Violation("${formatLocation(location)} ${error.message}")
        }
        val kind = if (isRun) ScalarKind.RUN else ScalarKind.SCALAR
        if (isRun || accounting.expressionCount > 0) {
            measurements += Measurement(location, kind, accounting)
        }
        if (isCondition) {
            val conditionAccounting = try {
                accountCondition(node.value)
            } catch (error: Violation) {
                throw Violation("${formatLocation(location)} ${error.message}")
            }
            measurements += Measurement(location, ScalarKind.CONDITION_WRAPPER, conditionAccounting)
        }
    }

    private data class Expression(
        val start: Int,
        val end: Int,
        val trimmed: String,
    ) {
        fun covers(value: String): Boolean =
            start == 0 &&
                end == value.length
    }

    private fun findExpressions(value: String): List<Expression> {
        val result = ArrayList<Expression>()
        var cursor = 0
        while (cursor < value.length - 2) {
            val start = value.indexOf("\${{", cursor)
            if (start < 0) break
            var index = start + 3
            var quoted = false
            var end = -1
            while (index < value.length - 1) {
                when {
                    value[index] == '\'' -> {
                        if (quoted && index + 1 < value.length && value[index + 1] == '\'') {
                            index += 2
                            continue
                        }
                        quoted = !quoted
                    }
                    !quoted && value[index] == '}' && value[index + 1] == '}' -> {
                        end = index + 2
                        break
                    }
                }
                index++
            }
            if (end < 0) throw Violation("unterminated workflow expression")
            result += Expression(start, end, trimDotNetWhitespace(value.substring(start + 3, end - 2)))
            cursor = end
        }
        return result
    }

    private fun escapeLiteral(value: String): String =
        value.replace("'", "''").replace("{", "{{").replace("}", "}}")

    private fun generatedExpression(value: String, expressions: List<Expression>): String {
        if (expressions.size == 1 && expressions.single().covers(value)) {
            return expressions.single().trimmed
        }
        val builder = StringBuilder("format('")
        var cursor = 0
        expressions.forEachIndexed { index, expression ->
            builder.append(escapeLiteral(value.substring(cursor, expression.start)))
            builder.append('{').append(index).append('}')
            cursor = expression.end
        }
        builder.append(escapeLiteral(value.substring(cursor)))
        builder.append("', ")
        builder.append(expressions.joinToString(", ") { it.trimmed })
        builder.append(')')
        return builder.toString()
    }

    private fun decodeSingleStringLiteral(expression: String): String? {
        val literal = trimDotNetWhitespace(expression)
        if (literal.length < 2 || literal.first() != '\'' || literal.last() != '\'') return null
        val result = StringBuilder(literal.length - 2)
        var index = 1
        while (index < literal.length - 1) {
            if (literal[index] != '\'') {
                result.append(literal[index])
                index++
            } else if (index + 1 < literal.length - 1 && literal[index + 1] == '\'') {
                result.append('\'')
                index += 2
            } else {
                return null
            }
        }
        return result.toString()
    }

    private fun hasStatusFunction(value: String): Boolean {
        var index = 0
        while (index < value.length) {
            if (value[index] == '\'') {
                index = skipExpressionString(value, index)
                continue
            }
            if (isIdentifierStart(value[index])) {
                val start = index
                index++
                while (index < value.length && isIdentifierPart(value[index])) index++
                val identifier = value.substring(start, index)
                var next = index
                while (next < value.length && isDotNetWhitespace(value[next].code)) next++
                var previous = start - 1
                while (previous >= 0 && isDotNetWhitespace(value[previous].code)) previous--
                val isMemberAccess = previous >= 0 && value[previous] == '.'
                if (!isMemberAccess &&
                    next < value.length &&
                    value[next] == '(' &&
                    STATUS_FUNCTIONS.any { it.equals(identifier, ignoreCase = true) }
                ) {
                    return true
                }
                continue
            }
            index++
        }
        return false
    }

    private fun skipExpressionString(value: String, start: Int): Int {
        var index = start + 1
        while (index < value.length) {
            if (value[index] == '\'') {
                if (index + 1 < value.length && value[index + 1] == '\'') {
                    index += 2
                } else {
                    return index + 1
                }
            } else {
                index++
            }
        }
        return value.length
    }

    private fun isIdentifierStart(value: Char): Boolean =
        value == '_' || value.isLetter()

    private fun isIdentifierPart(value: Char): Boolean =
        value == '_' || value.isLetterOrDigit()

    private fun trimDotNetWhitespace(value: String): String {
        var start = 0
        var end = value.length
        while (start < end && isDotNetWhitespace(value[start].code)) start++
        while (end > start && isDotNetWhitespace(value[end - 1].code)) end--
        return value.substring(start, end)
    }

    private fun isDotNetWhitespace(codePoint: Int): Boolean =
        codePoint in 0x0009..0x000D ||
            codePoint == 0x0020 ||
            codePoint == 0x0085 ||
            codePoint == 0x00A0 ||
            codePoint == 0x1680 ||
            codePoint in 0x2000..0x200A ||
            codePoint == 0x2028 ||
            codePoint == 0x2029 ||
            codePoint == 0x202F ||
            codePoint == 0x205F ||
            codePoint == 0x3000

    private fun formatLocation(location: Location): String =
        "${location.workflow}:${location.line}:${location.column}:${location.structuralPath}"

    private val SAFE_STRUCTURAL_FIELDS = setOf(
        "jobs",
        "steps",
        "run",
        "if",
        "env",
        "with",
        "name",
        "on",
        "permissions",
        "concurrency",
        "defaults",
        "strategy",
        "matrix",
        "uses",
        "shell",
        "working-directory",
    )
    private val STATUS_FUNCTIONS = listOf("success", "always", "failure", "cancelled")
}
