package org.zenscript.intellij

import com.intellij.psi.util.PsiTreeUtil
import com.intellij.testFramework.fixtures.BasePlatformTestCase
import org.zenscript.intellij.highlighting.ZenScriptSyntaxHighlighter
import org.zenscript.intellij.psi.*

class ZenScriptAnnotatorTest : BasePlatformTestCase() {

    fun testFunctionDeclarationHighlighted() {
        val file = myFixture.configureByText(
            "main.zs",
            """
            fn greet() {}
            """.trimIndent()
        )
        myFixture.doHighlighting()
        val highlights = myFixture.doHighlighting().filter {
            it.forcedTextAttributesKey == ZenScriptSyntaxHighlighter.FUNCTION_NAME
        }
        assertFalse("Function declaration name should be highlighted", highlights.isEmpty())
        assertTrue(highlights.any { file.text.substring(it.startOffset, it.endOffset) == "greet" })
    }

    fun testFunctionCallHighlighted() {
        val file = myFixture.configureByText(
            "main.zs",
            """
            fn greet() {}
            greet();
            """.trimIndent()
        )
        myFixture.doHighlighting()
        val highlights = myFixture.doHighlighting().filter {
            it.forcedTextAttributesKey == ZenScriptSyntaxHighlighter.FUNCTION_CALL
        }
        assertFalse("Function call should be highlighted", highlights.isEmpty())
        assertTrue(highlights.any { file.text.substring(it.startOffset, it.endOffset) == "greet" })
    }

    fun testFunctionCallInsideBlockHighlighted() {
        val file = myFixture.configureByText(
            "main.zs",
            """
            fn greet() {}
            fn main() {
                greet();
            }
            """.trimIndent()
        )
        myFixture.doHighlighting()
        val highlights = myFixture.doHighlighting().filter {
            it.forcedTextAttributesKey == ZenScriptSyntaxHighlighter.FUNCTION_CALL
        }
        assertFalse("Function call inside block should be highlighted", highlights.isEmpty())
    }

    fun testImportedFunctionCallHighlighted() {
        myFixture.addFileToProject(
            "lib.zs",
            """
            fn get_ten(): number = 10;
            """.trimIndent()
        )
        val file = myFixture.configureByText(
            "main.zs",
            """
            import { get_ten } from "./lib.zs";
            let x = get_ten();
            """.trimIndent()
        )
        myFixture.doHighlighting()
        val highlights = myFixture.doHighlighting().filter {
            it.forcedTextAttributesKey == ZenScriptSyntaxHighlighter.FUNCTION_CALL
        }
        assertFalse("Imported function call should be highlighted", highlights.isEmpty())
        assertTrue(highlights.any { file.text.substring(it.startOffset, it.endOffset) == "get_ten" })
    }

    fun testStructFieldHighlighted() {
        val file = myFixture.configureByText(
            "main.zs",
            """
            struct Point {
                x: number,
                y: number
            }
            """.trimIndent()
        )
        myFixture.doHighlighting()
        val highlights = myFixture.doHighlighting().filter {
            it.forcedTextAttributesKey == ZenScriptSyntaxHighlighter.FIELD_NAME
        }
        assertFalse("Struct field declarations should be highlighted", highlights.isEmpty())
        val highlightedTexts = highlights.map { file.text.substring(it.startOffset, it.endOffset) }
        assertTrue("x field should be highlighted", highlightedTexts.contains("x"))
        assertTrue("y field should be highlighted", highlightedTexts.contains("y"))
    }

    fun testReferenceToVariableNotHighlightedAsFunctionCall() {
        myFixture.configureByText(
            "main.zs",
            """
            let x = 10;
            let y = x;
            """.trimIndent()
        )
        myFixture.doHighlighting()
        val highlights = myFixture.doHighlighting().filter {
            it.forcedTextAttributesKey == ZenScriptSyntaxHighlighter.FUNCTION_CALL
        }
        assertTrue("Variable reference should NOT be highlighted as function call", highlights.isEmpty())
    }

    fun testStructLiteralFieldsHighlighted() {
        val file = myFixture.configureByText(
            "main.zs",
            """
            struct Point {
                x: number,
                y: number
            }
            let p = Point { x: 3, y: 4 };
            """.trimIndent()
        )
        myFixture.doHighlighting()
        val highlights = myFixture.doHighlighting().filter {
            it.forcedTextAttributesKey == ZenScriptSyntaxHighlighter.FIELD_NAME
        }
        val highlightedTexts = highlights.map { file.text.substring(it.startOffset, it.endOffset) }
        // Should include both declaration fields and literal fields
        assertEquals("Should highlight x twice (decl + literal) and y twice (decl + literal)",
            4, highlightedTexts.count { it == "x" || it == "y" })
    }

    fun testStructLiteralFieldResolvesToDeclaration() {
        val file = myFixture.configureByText(
            "main.zs",
            """
            struct Point {
                x: number,
                y: number
            }
            let p = Point { x: 3, y: 4 };
            """.trimIndent()
        )

        val refs = PsiTreeUtil.findChildrenOfType(file, ZenScriptReferenceExpression::class.java)
        // Find the 'x' reference inside the struct literal (not the struct declaration field)
        val xRefs = refs.filter { it.text == "x" }
        assertTrue("Should find reference to x", xRefs.isNotEmpty())

        // The struct literal field 'x' should resolve to the struct field declaration
        val literalXRef = xRefs.find { ref ->
            ref.reference.resolve() is ZenScriptStructField
        }
        assertNotNull("Struct literal field x should resolve to ZenScriptStructField", literalXRef)
        val resolved = literalXRef!!.reference.resolve() as ZenScriptStructField
        assertEquals("x", resolved.name)
    }
}
