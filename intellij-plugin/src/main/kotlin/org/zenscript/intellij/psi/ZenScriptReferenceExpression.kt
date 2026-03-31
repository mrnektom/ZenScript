package org.zenscript.intellij.psi

import com.intellij.extapi.psi.ASTWrapperPsiElement
import com.intellij.lang.ASTNode
import com.intellij.psi.PsiElement
import com.intellij.psi.PsiReference
import org.zenscript.intellij.reference.ZenScriptReference

class ZenScriptReferenceExpression(node: ASTNode) : ASTWrapperPsiElement(node) {
    override fun getReference(): PsiReference = ZenScriptReference(this)

    fun getReferenceName(): String? = node.findChildByType(ZenScriptTokenTypes.IDENTIFIER)?.text

    fun setName(name: String): PsiElement {
        val newIdentifier = ZenScriptPsiFactory.createIdentifier(project, name)
        if (newIdentifier != null) {
            val identifierNode = node.findChildByType(ZenScriptTokenTypes.IDENTIFIER)
            if (identifierNode != null) {
                identifierNode.psi.replace(newIdentifier)
            }
        }
        return this
    }
}
