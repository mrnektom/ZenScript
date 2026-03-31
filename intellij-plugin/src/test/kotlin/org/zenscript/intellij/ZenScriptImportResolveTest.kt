package org.zenscript.intellij

import com.intellij.psi.util.PsiTreeUtil
import com.intellij.testFramework.fixtures.BasePlatformTestCase
import org.zenscript.intellij.psi.*

class ZenScriptImportResolveTest : BasePlatformTestCase() {

    override fun getTestDataPath(): String = "src/test/resources"

    fun testImportSymbolResolvesToDeclaration() {
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
            """.trimIndent()
        )

        val importStmt = PsiTreeUtil.findChildOfType(file, ZenScriptImportStatement::class.java)
        assertNotNull("IMPORT_STATEMENT should exist", importStmt)

        val symbols = importStmt!!.getImportSymbols()
        assertEquals("Should have one import symbol", 1, symbols.size)

        val symbol = symbols[0]
        assertEquals("get_ten", symbol.getOriginalName())
        assertNull(symbol.getAlias())
        assertEquals("get_ten", symbol.name)

        val resolved = symbol.reference.resolve()
        assertNotNull("Import symbol should resolve to declaration in lib.zs", resolved)
        assertInstanceOf(resolved, ZenScriptFnDeclaration::class.java)
        assertEquals("get_ten", (resolved as ZenScriptFnDeclaration).name)
    }

    fun testAliasedImportResolvesCorrectly() {
        myFixture.addFileToProject(
            "lib.zs",
            """
            fn add(a: number, b: number): number = a;
            """.trimIndent()
        )
        val file = myFixture.configureByText(
            "main.zs",
            """
            import { add as sum } from "./lib.zs";
            """.trimIndent()
        )

        val importStmt = PsiTreeUtil.findChildOfType(file, ZenScriptImportStatement::class.java)
        assertNotNull(importStmt)

        val symbols = importStmt!!.getImportSymbols()
        assertEquals(1, symbols.size)

        val symbol = symbols[0]
        assertEquals("add", symbol.getOriginalName())
        assertEquals("sum", symbol.getAlias())
        assertEquals("sum", symbol.name) // visible name is the alias

        val resolved = symbol.reference.resolve()
        assertNotNull("Aliased import should resolve to original declaration", resolved)
        assertInstanceOf(resolved, ZenScriptFnDeclaration::class.java)
        assertEquals("add", (resolved as ZenScriptFnDeclaration).name)
    }

    fun testImportPathResolvesToFile() {
        val libFile = myFixture.addFileToProject(
            "lib.zs",
            """
            fn helper() = 0;
            """.trimIndent()
        )
        val file = myFixture.configureByText(
            "main.zs",
            """
            import { helper } from "./lib.zs";
            """.trimIndent()
        )

        val importStmt = PsiTreeUtil.findChildOfType(file, ZenScriptImportStatement::class.java)
        assertNotNull(importStmt)

        val importPath = importStmt!!.getImportPath()
        assertNotNull("IMPORT_PATH should exist", importPath)
        assertEquals("./lib.zs", importPath!!.getPathString())

        val resolved = importPath.reference.resolve()
        assertNotNull("Import path should resolve to file", resolved)
        assertEquals(libFile, resolved)
    }

    fun testImportedSymbolUsedInCodeResolvesThrough() {
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

        // Find the reference expression for get_ten in `let x = get_ten()`
        val refs = PsiTreeUtil.findChildrenOfType(file, ZenScriptReferenceExpression::class.java)
        val getTenRef = refs.find { it.text == "get_ten" }
        assertNotNull("Should find reference to get_ten in code", getTenRef)

        val resolved = getTenRef!!.reference.resolve()
        // The reference should resolve directly to the fn declaration in the external file (one-hop)
        assertNotNull("Reference to imported symbol should resolve", resolved)
        assertInstanceOf(resolved, ZenScriptFnDeclaration::class.java)
        assertEquals("get_ten", (resolved as ZenScriptFnDeclaration).name)
    }

    fun testExportFromResolvesTransitively() {
        myFixture.addFileToProject(
            "original.zs",
            """
            fn foo(): number = 42;
            """.trimIndent()
        )
        myFixture.addFileToProject(
            "reexporter.zs",
            """
            export { foo } from "./original.zs";
            """.trimIndent()
        )
        val file = myFixture.configureByText(
            "main.zs",
            """
            import { foo } from "./reexporter.zs";
            """.trimIndent()
        )

        val importStmt = PsiTreeUtil.findChildOfType(file, ZenScriptImportStatement::class.java)
        assertNotNull(importStmt)

        val symbol = importStmt!!.getImportSymbols().first()
        val resolved = symbol.reference.resolve()
        assertNotNull("Import through export-from should resolve transitively", resolved)
        assertInstanceOf(resolved, ZenScriptFnDeclaration::class.java)
        assertEquals("foo", (resolved as ZenScriptFnDeclaration).name)
    }

    fun testUseStatementParses() {
        val file = myFixture.configureByText(
            "main.zs",
            """
            enum Color { }
            use Color.{ Red, Green, Blue };
            """.trimIndent()
        )

        val useStmt = PsiTreeUtil.findChildOfType(file, ZenScriptUseStatement::class.java)
        assertNotNull("USE_STATEMENT should exist", useStmt)
        assertEquals("Color", useStmt!!.getEnumName())

        val variants = useStmt.getVariantSymbols()
        assertEquals(3, variants.size)
        assertEquals("Red", variants[0].getOriginalName())
        assertEquals("Green", variants[1].getOriginalName())
        assertEquals("Blue", variants[2].getOriginalName())
    }

    fun testExportFromMakesSymbolLocallyVisible() {
        myFixture.addFileToProject(
            "original.zs",
            """
            fn foo(): number = 42;
            """.trimIndent()
        )
        val file = myFixture.configureByText(
            "main.zs",
            """
            export { foo } from "./original.zs";
            let x = foo();
            """.trimIndent()
        )

        val refs = PsiTreeUtil.findChildrenOfType(file, ZenScriptReferenceExpression::class.java)
        val fooRef = refs.find { it.text == "foo" }
        assertNotNull("Should find reference to foo in code", fooRef)

        val resolved = fooRef!!.reference.resolve()
        assertNotNull("export-from should make symbol locally visible", resolved)
        assertInstanceOf(resolved, ZenScriptFnDeclaration::class.java)
        assertEquals("foo", (resolved as ZenScriptFnDeclaration).name)
    }

    fun testUseStatementResolvesToEnumVariant() {
        val file = myFixture.configureByText(
            "main.zs",
            """
            enum Color { Red, Green, Blue }
            use Color.{ Red };
            """.trimIndent()
        )

        val useStmt = PsiTreeUtil.findChildOfType(file, ZenScriptUseStatement::class.java)
        assertNotNull("USE_STATEMENT should exist", useStmt)

        val symbols = useStmt!!.getVariantSymbols()
        assertEquals(1, symbols.size)

        val resolved = symbols[0].reference.resolve()
        assertNotNull("Use symbol should resolve to enum variant", resolved)
        assertInstanceOf(resolved, ZenScriptEnumVariant::class.java)
        assertEquals("Red", (resolved as ZenScriptEnumVariant).name)
    }

    fun testUseStatementVariantUsedInCodeResolvesToEnumVariant() {
        val file = myFixture.configureByText(
            "main.zs",
            """
            enum Color { Red, Green, Blue }
            use Color.{ Red };
            let x = Red;
            """.trimIndent()
        )

        val refs = PsiTreeUtil.findChildrenOfType(file, ZenScriptReferenceExpression::class.java)
        val redRef = refs.find { it.text == "Red" }
        assertNotNull("Should find reference to Red in code", redRef)

        val resolved = redRef!!.reference.resolve()
        assertNotNull("Reference to used variant should resolve", resolved)
        assertInstanceOf(resolved, ZenScriptEnumVariant::class.java)
        assertEquals("Red", (resolved as ZenScriptEnumVariant).name)
    }

    fun testUseWithImportedEnumResolvesVariant() {
        myFixture.addFileToProject(
            "colors.zs",
            """
            enum Color { Red, Green, Blue }
            """.trimIndent()
        )
        val file = myFixture.configureByText(
            "main.zs",
            """
            import { Color } from "./colors.zs";
            use Color.{ Red };
            let x = Red;
            """.trimIndent()
        )

        val refs = PsiTreeUtil.findChildrenOfType(file, ZenScriptReferenceExpression::class.java)
        val redRef = refs.find { it.text == "Red" }
        assertNotNull("Should find reference to Red in code", redRef)

        val resolved = redRef!!.reference.resolve()
        assertNotNull("use with imported enum should resolve variant", resolved)
        assertInstanceOf(resolved, ZenScriptEnumVariant::class.java)
        assertEquals("Red", (resolved as ZenScriptEnumVariant).name)
    }

    fun testForLoopVariableResolvesInsideBody() {
        val file = myFixture.configureByText(
            "main.zs",
            """
            fn test() {
                for (let i = 0; i < 10; i = i + 1) {
                    let x = i;
                }
            }
            """.trimIndent()
        )

        val refs = PsiTreeUtil.findChildrenOfType(file, ZenScriptReferenceExpression::class.java)
        // Find the reference to 'i' inside the for body (let x = i)
        val iRefs = refs.filter { it.text == "i" }
        assertTrue("Should find references to i", iRefs.isNotEmpty())

        // The last 'i' reference (in let x = i) should resolve to the var declaration
        val lastIRef = iRefs.last()
        val resolved = lastIRef.reference.resolve()
        assertNotNull("For-loop variable should resolve inside body", resolved)
        assertInstanceOf(resolved, ZenScriptVarDeclaration::class.java)
    }

    fun testIfConditionReferenceResolves() {
        val file = myFixture.configureByText(
            "main.zs",
            """
            let flag = true;
            if (flag) {
                let x = 1;
            }
            """.trimIndent()
        )

        val refs = PsiTreeUtil.findChildrenOfType(file, ZenScriptReferenceExpression::class.java)
        val flagRef = refs.find { it.text == "flag" }
        assertNotNull("Should find reference to flag in if condition", flagRef)

        val resolved = flagRef!!.reference.resolve()
        assertNotNull("Reference in if condition should resolve", resolved)
        assertInstanceOf(resolved, ZenScriptVarDeclaration::class.java)
        assertEquals("flag", (resolved as ZenScriptVarDeclaration).name)
    }

    fun testWhileConditionReferenceResolves() {
        val file = myFixture.configureByText(
            "main.zs",
            """
            let running = true;
            fn test() {
                while (running) {
                    let x = 1;
                }
            }
            """.trimIndent()
        )

        val refs = PsiTreeUtil.findChildrenOfType(file, ZenScriptReferenceExpression::class.java)
        val runningRef = refs.find { it.text == "running" }
        assertNotNull("Should find reference to running in while condition", runningRef)

        val resolved = runningRef!!.reference.resolve()
        assertNotNull("Reference in while condition should resolve", resolved)
        assertInstanceOf(resolved, ZenScriptVarDeclaration::class.java)
        assertEquals("running", (resolved as ZenScriptVarDeclaration).name)
    }

    fun testUnresolvedImportSymbolReturnsNull() {
        myFixture.addFileToProject(
            "lib.zs",
            """
            fn something_else() = 0;
            """.trimIndent()
        )
        val file = myFixture.configureByText(
            "main.zs",
            """
            import { nonexistent } from "./lib.zs";
            """.trimIndent()
        )

        val importStmt = PsiTreeUtil.findChildOfType(file, ZenScriptImportStatement::class.java)
        assertNotNull(importStmt)

        val symbol = importStmt!!.getImportSymbols().first()
        val resolved = symbol.reference.resolve()
        assertNull("Reference to nonexistent symbol should not resolve", resolved)
    }
}
