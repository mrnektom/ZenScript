package org.zenscript.intellij

import com.intellij.psi.util.PsiTreeUtil
import com.intellij.testFramework.fixtures.BasePlatformTestCase
import org.zenscript.intellij.psi.*
import org.zenscript.intellij.settings.ZenScriptSettings

class ZenScriptPreludeResolveTest : BasePlatformTestCase() {

    override fun getTestDataPath(): String = "src/test/resources"

    private fun configurePrelude() {
        // Create stdlib files in the test project
        myFixture.addFileToProject(
            "stdlib/string.zs",
            """
            struct String {
                len: number,
                data: long
            }
            """.trimIndent()
        )
        myFixture.addFileToProject(
            "stdlib/Option.zs",
            """
            enum Option { Some, None }
            """.trimIndent()
        )
        myFixture.addFileToProject(
            "stdlib/prelude.zs",
            """
            export { String } from "./string.zs"
            export { Option } from "./Option.zs"

            struct Pointer {
                ptr: long
            }

            fn print(s: String): void = 0;
            fn alloc(size: long): long = 0;
            fn read_line(): String = 0;
            """.trimIndent()
        )

        // Point settings to the stdlib directory using VFS URL (works with temp:// in tests)
        val preludeFile = myFixture.findFileInTempDir("stdlib/prelude.zs")
        assertNotNull("prelude.zs should exist in temp dir", preludeFile)
        val stdlibDir = preludeFile!!.parent
        ZenScriptSettings.getInstance(project).stdlibPath = stdlibDir.url
    }

    fun testPreludeFnResolvesWithoutImport() {
        configurePrelude()
        val file = myFixture.configureByText(
            "main.zs",
            """
            let x = print("hello");
            """.trimIndent()
        )

        val refs = PsiTreeUtil.findChildrenOfType(file, ZenScriptReferenceExpression::class.java)
        val printRef = refs.find { it.text == "print" }
        assertNotNull("Should find reference to print", printRef)

        val resolved = printRef!!.reference.resolve()
        assertNotNull("Prelude fn 'print' should resolve without explicit import", resolved)
        assertInstanceOf(resolved, ZenScriptFnDeclaration::class.java)
        assertEquals("print", (resolved as ZenScriptFnDeclaration).name)
    }

    fun testTransitiveExportResolvesViaPrelude() {
        configurePrelude()
        val file = myFixture.configureByText(
            "main.zs",
            """
            let s: String;
            """.trimIndent()
        )

        val typeRef = PsiTreeUtil.findChildOfType(file, ZenScriptTypeReferenceElement::class.java)
        assertNotNull("Should find type reference to String", typeRef)

        val resolved = typeRef!!.reference.resolve()
        assertNotNull("Transitive export 'String' should resolve via prelude", resolved)
        assertInstanceOf(resolved, ZenScriptStructDeclaration::class.java)
        assertEquals("String", (resolved as ZenScriptStructDeclaration).name)
    }

    fun testTransitiveExportOptionResolvesViaPrelude() {
        configurePrelude()
        val file = myFixture.configureByText(
            "main.zs",
            """
            let o: Option;
            """.trimIndent()
        )

        val typeRef = PsiTreeUtil.findChildOfType(file, ZenScriptTypeReferenceElement::class.java)
        assertNotNull("Should find type reference to Option", typeRef)

        val resolved = typeRef!!.reference.resolve()
        assertNotNull("Transitive export 'Option' should resolve via prelude", resolved)
        assertInstanceOf(resolved, ZenScriptEnumDeclaration::class.java)
        assertEquals("Option", (resolved as ZenScriptEnumDeclaration).name)
    }

    fun testCompletionIncludesPreludeSymbols() {
        configurePrelude()
        myFixture.configureByText(
            "main.zs",
            """
            let x = pr<caret>
            """.trimIndent()
        )
        val lookups = myFixture.completeBasic()
        assertNotNull("Completion should return results", lookups)
        val names = lookups.map { it.lookupString }
        assertTrue("Should contain 'print' from prelude, got: $names", names.contains("print"))
    }

    fun testLocalDeclarationShadowsPrelude() {
        configurePrelude()
        val file = myFixture.configureByText(
            "main.zs",
            """
            fn print(n: number): void = 0;
            let x = print(42);
            """.trimIndent()
        )

        val refs = PsiTreeUtil.findChildrenOfType(file, ZenScriptReferenceExpression::class.java)
        val printRef = refs.find { it.text == "print" }
        assertNotNull("Should find reference to print", printRef)

        val resolved = printRef!!.reference.resolve()
        assertNotNull("print should resolve", resolved)
        assertInstanceOf(resolved, ZenScriptFnDeclaration::class.java)
        // The resolved element should be in main.zs, not in prelude
        assertEquals("main.zs", resolved!!.containingFile.name)
    }

    fun testNoPreludeWhenStdlibPathUnconfigured() {
        // Do NOT call configurePrelude() — stdlibPath remains empty
        val file = myFixture.configureByText(
            "main.zs",
            """
            let x = print("hello");
            """.trimIndent()
        )

        val refs = PsiTreeUtil.findChildrenOfType(file, ZenScriptReferenceExpression::class.java)
        val printRef = refs.find { it.text == "print" }
        assertNotNull("Should find reference to print", printRef)

        val resolved = printRef!!.reference.resolve()
        assertNull("print should NOT resolve when stdlibPath is unconfigured", resolved)
    }
}
