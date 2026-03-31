package org.zenscript.intellij

import com.intellij.psi.util.PsiTreeUtil
import com.intellij.testFramework.fixtures.BasePlatformTestCase
import org.zenscript.intellij.psi.ZenScriptImportPath

class ZenScriptCompletionTest : BasePlatformTestCase() {

    override fun getTestDataPath(): String = "src/test/resources"

    fun testCompletionIncludesLocalVariable() {
        myFixture.configureByText(
            "main.zs",
            """
            let foo = 1;
            let x = f<caret>
            """.trimIndent()
        )
        val lookups = myFixture.completeBasic()
        assertNotNull("Completion should return results", lookups)
        val names = lookups.map { it.lookupString }
        assertTrue("Should contain 'foo', got: $names", names.contains("foo"))
    }

    fun testCompletionIncludesFunction() {
        myFixture.configureByText(
            "main.zs",
            """
            fn bar() = 0;
            let x = b<caret>
            """.trimIndent()
        )
        val lookups = myFixture.completeBasic()
        assertNotNull("Completion should return results", lookups)
        val names = lookups.map { it.lookupString }
        assertTrue("Should contain 'bar', got: $names", names.contains("bar"))
    }

    fun testCompletionIncludesImportedSymbol() {
        myFixture.addFileToProject(
            "lib.zs",
            """
            fn get_ten(): number = 10;
            """.trimIndent()
        )
        myFixture.configureByText(
            "main.zs",
            """
            import { get_ten } from "./lib.zs";
            let x = <caret>
            """.trimIndent()
        )
        val lookups = myFixture.completeBasic()
        assertNotNull("Completion should return results", lookups)
        val names = lookups.map { it.lookupString }
        assertTrue("Should contain 'get_ten', got: $names", names.contains("get_ten"))
    }

    fun testCompletionIncludesKeywords() {
        myFixture.configureByText(
            "main.zs",
            """
            l<caret>
            """.trimIndent()
        )
        val lookups = myFixture.completeBasic()
        assertNotNull("Completion should return results", lookups)
        val names = lookups.map { it.lookupString }
        assertTrue("Should contain 'let', got: $names", names.contains("let"))
    }

    fun testCompletionAfterDotShowsEnumVariants() {
        myFixture.configureByText(
            "main.zs",
            """
            enum Color { Red, Green }
            let x = Color.<caret>
            """.trimIndent()
        )
        val lookups = myFixture.completeBasic()
        assertNotNull("Completion should return results", lookups)
        val names = lookups.map { it.lookupString }
        assertTrue("Should contain 'Red', got: $names", names.contains("Red"))
        assertTrue("Should contain 'Green', got: $names", names.contains("Green"))
    }

    fun testCompletionAfterDotShowsStructFields() {
        myFixture.configureByText(
            "main.zs",
            """
            struct Point { x: number, y: number }
            let p: Point;
            let v = p.<caret>
            """.trimIndent()
        )
        val lookups = myFixture.completeBasic()
        assertNotNull("Completion should return results", lookups)
        val names = lookups.map { it.lookupString }
        assertTrue("Should contain 'x', got: $names", names.contains("x"))
        assertTrue("Should contain 'y', got: $names", names.contains("y"))
    }

    fun testCompletionInTypePositionShowsTypes() {
        myFixture.configureByText(
            "main.zs",
            """
            struct Point { x: number, y: number }
            let x: P<caret>
            """.trimIndent()
        )
        val lookups = myFixture.completeBasic()
        assertNotNull("Completion should return results", lookups)
        val names = lookups.map { it.lookupString }
        assertTrue("Should contain 'Point', got: $names", names.contains("Point"))
    }

    fun testCompletionInUseShowsEnumVariants() {
        myFixture.configureByText(
            "main.zs",
            """
            enum Option { Some, None }
            use Option.{ <caret> }
            """.trimIndent()
        )
        val lookups = myFixture.completeBasic()
        assertNotNull("Completion should return results", lookups)
        val names = lookups.map { it.lookupString }
        assertTrue("Should contain 'Some', got: $names", names.contains("Some"))
        assertTrue("Should contain 'None', got: $names", names.contains("None"))
    }

    fun testImportPathReferenceVariantsIncludeFiles() {
        myFixture.addFileToProject("lib.zs", "fn helper() = 0;")
        val file = myFixture.configureByText(
            "main.zs",
            """
            import { x } from "./lib.zs";
            """.trimIndent()
        )
        val importPath = PsiTreeUtil.findChildOfType(file, ZenScriptImportPath::class.java)
        assertNotNull("IMPORT_PATH should exist", importPath)
        val variants = importPath!!.reference.variants
        val names = variants.map { it.toString() }
        assertTrue("Should contain './lib.zs', got: $names", names.contains("./lib.zs"))
    }

    fun testCompletionAfterDotOnImportedStructType() {
        myFixture.addFileToProject(
            "types.zs",
            """
            struct Point { x: number, y: number }
            """.trimIndent()
        )
        myFixture.configureByText(
            "main.zs",
            """
            import { Point } from "./types.zs";
            let p: Point;
            let v = p.<caret>
            """.trimIndent()
        )
        val lookups = myFixture.completeBasic()
        assertNotNull("Completion should return results", lookups)
        val names = lookups.map { it.lookupString }
        assertTrue("Should contain 'x', got: $names", names.contains("x"))
        assertTrue("Should contain 'y', got: $names", names.contains("y"))
    }

    fun testCompletionUsedVariantInExpression() {
        myFixture.configureByText(
            "main.zs",
            """
            enum Color { Red }
            use Color.{ Red };
            let x = R<caret>
            """.trimIndent()
        )
        val lookups = myFixture.completeBasic()
        assertNotNull("Completion should return results", lookups)
        val names = lookups.map { it.lookupString }
        assertTrue("Should contain 'Red', got: $names", names.contains("Red"))
    }
}
