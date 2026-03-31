package org.zenscript.intellij.psi

import com.intellij.extapi.psi.ASTWrapperPsiElement
import com.intellij.lang.ASTNode
import com.intellij.psi.PsiReference
import org.zenscript.intellij.reference.ZenScriptTypeReference

class ZenScriptTypeReferenceElement(node: ASTNode) : ASTWrapperPsiElement(node) {
    override fun getReference(): PsiReference = ZenScriptTypeReference(this)

    fun getReferenceName(): String? {
        val identifierNode = node.findChildByType(ZenScriptTokenTypes.IDENTIFIER)
        return identifierNode?.text
    }
}
