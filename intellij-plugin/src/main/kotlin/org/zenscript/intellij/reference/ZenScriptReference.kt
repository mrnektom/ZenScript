package org.zenscript.intellij.reference

import com.intellij.openapi.util.TextRange
import com.intellij.psi.PsiElement
import com.intellij.psi.PsiReferenceBase
import org.zenscript.intellij.psi.ZenScriptReferenceExpression

class ZenScriptReference(element: ZenScriptReferenceExpression) :
    PsiReferenceBase<ZenScriptReferenceExpression>(element, TextRange(0, element.textLength)) {

    override fun resolve(): PsiElement? {
        val name = element.getReferenceName() ?: return null

        // Try struct literal field resolution first (e.g. `x` in `Point { x: 3 }`)
        val structField = ZenScriptResolveUtil.resolveStructLiteralField(element)
        if (structField != null) return structField

        return ZenScriptResolveUtil.resolveInScope(element, name)
    }

    override fun getVariants(): Array<Any> {
        return ZenScriptResolveUtil.collectVariants(element).toTypedArray()
    }

    override fun handleElementRename(newElementName: String): PsiElement {
        element.setName(newElementName)
        return element
    }
}
