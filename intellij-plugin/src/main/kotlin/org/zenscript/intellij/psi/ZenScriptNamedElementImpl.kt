package org.zenscript.intellij.psi

import com.intellij.extapi.psi.ASTWrapperPsiElement
import com.intellij.lang.ASTNode
import com.intellij.psi.PsiElement

abstract class ZenScriptNamedElementImpl(node: ASTNode) : ASTWrapperPsiElement(node), ZenScriptNamedElement {
    override fun getNameIdentifier(): PsiElement? =
        node.findChildByType(ZenScriptTokenTypes.IDENTIFIER)?.psi

    override fun getName(): String? = nameIdentifier?.text

    override fun setName(name: String): PsiElement {
        val identifier = nameIdentifier ?: return this
        val newIdentifier = ZenScriptPsiFactory.createIdentifier(project, name)
        if (newIdentifier != null) {
            identifier.replace(newIdentifier)
        }
        return this
    }

    override fun getTextOffset(): Int = nameIdentifier?.textOffset ?: super.getTextOffset()
}

class ZenScriptVarDeclaration(node: ASTNode) : ZenScriptNamedElementImpl(node)
class ZenScriptFnDeclaration(node: ASTNode) : ZenScriptNamedElementImpl(node)
class ZenScriptStructDeclaration(node: ASTNode) : ZenScriptNamedElementImpl(node)
class ZenScriptEnumDeclaration(node: ASTNode) : ZenScriptNamedElementImpl(node)
class ZenScriptParameter(node: ASTNode) : ZenScriptNamedElementImpl(node)
class ZenScriptEnumVariant(node: ASTNode) : ZenScriptNamedElementImpl(node)
class ZenScriptStructField(node: ASTNode) : ZenScriptNamedElementImpl(node)
class ZenScriptReturnStatement(node: ASTNode) : ASTWrapperPsiElement(node)
