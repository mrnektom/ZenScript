package org.zenscript.intellij

import com.intellij.psi.util.PsiTreeUtil
import com.intellij.testFramework.fixtures.BasePlatformTestCase
import org.zenscript.intellij.psi.ZenScriptStructDeclaration
import org.zenscript.intellij.psi.ZenScriptTypeReferenceElement

class ZenScriptTypeReferenceResolveTest : BasePlatformTestCase() {

    override fun getTestDataPath(): String = "src/test/resources"

    fun testTypeReferenceResolvesToStruct() {
        val file = myFixture.configureByText(
            "test.zs",
            """
            struct Point { }
            let p: Point = 0;
            """.trimIndent()
        )

        val typeRef = PsiTreeUtil.findChildOfType(file, ZenScriptTypeReferenceElement::class.java)
        assertNotNull("TYPE_REFERENCE element should exist", typeRef)

        val ref = typeRef!!.reference
        assertNotNull("TYPE_REFERENCE should have a reference", ref)

        val resolved = ref!!.resolve()
        assertNotNull("Reference should resolve to a declaration", resolved)
        assertInstanceOf(resolved, ZenScriptStructDeclaration::class.java)
        assertEquals("Point", (resolved as ZenScriptStructDeclaration).name)
    }

    fun testTypeReferenceForwardResolvesToStruct() {
        val file = myFixture.configureByText(
            "test.zs",
            """
            let p: MyStruct = 0;
            struct MyStruct { }
            """.trimIndent()
        )

        val typeRef = PsiTreeUtil.findChildOfType(file, ZenScriptTypeReferenceElement::class.java)
        assertNotNull("TYPE_REFERENCE element should exist", typeRef)

        val resolved = typeRef!!.reference?.resolve()
        assertNotNull("Forward reference should resolve", resolved)
        assertInstanceOf(resolved, ZenScriptStructDeclaration::class.java)
        assertEquals("MyStruct", (resolved as ZenScriptStructDeclaration).name)
    }

    fun testImportedTypeReferenceResolvesToStruct() {
        myFixture.addFileToProject(
            "types.zs",
            """
            struct MyStruct { }
            """.trimIndent()
        )
        val file = myFixture.configureByText(
            "main.zs",
            """
            import { MyStruct } from "./types.zs";
            let x: MyStruct = 0;
            """.trimIndent()
        )

        val typeRefs = PsiTreeUtil.findChildrenOfType(file, ZenScriptTypeReferenceElement::class.java)
        val myStructRef = typeRefs.find { it.getReferenceName() == "MyStruct" }
        assertNotNull("Should find type reference to MyStruct", myStructRef)

        val resolved = myStructRef!!.reference?.resolve()
        assertNotNull("Imported type reference should resolve", resolved)
        assertInstanceOf(resolved, ZenScriptStructDeclaration::class.java)
        assertEquals("MyStruct", (resolved as ZenScriptStructDeclaration).name)
    }

    fun testTypeReferenceUnresolved() {
        val file = myFixture.configureByText(
            "test.zs",
            """
            let p: Unknown = 0;
            """.trimIndent()
        )

        val typeRef = PsiTreeUtil.findChildOfType(file, ZenScriptTypeReferenceElement::class.java)
        assertNotNull("TYPE_REFERENCE element should exist", typeRef)

        val resolved = typeRef!!.reference?.resolve()
        assertNull("Reference to undefined type should not resolve", resolved)
    }
}
