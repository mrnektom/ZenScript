package org.zenscript.intellij.psi

import com.intellij.extapi.psi.ASTWrapperPsiElement
import com.intellij.lang.ASTNode
import com.intellij.psi.PsiElement
import com.intellij.psi.PsiReference
import com.intellij.psi.util.PsiTreeUtil
import org.zenscript.intellij.reference.ZenScriptImportPathReference
import org.zenscript.intellij.reference.ZenScriptImportSymbolReference

class ZenScriptImportStatement(node: ASTNode) : ASTWrapperPsiElement(node) {
    fun getPath(): String? = getImportPath()?.getPathString()

    fun getImportPath(): ZenScriptImportPath? =
        PsiTreeUtil.findChildOfType(this, ZenScriptImportPath::class.java)

    fun getImportSymbols(): List<ZenScriptImportSymbol> =
        PsiTreeUtil.getChildrenOfTypeAsList(this, ZenScriptImportSymbol::class.java)
}

class ZenScriptExportFromStatement(node: ASTNode) : ASTWrapperPsiElement(node) {
    fun getPath(): String? = getImportPath()?.getPathString()

    fun getImportPath(): ZenScriptImportPath? =
        PsiTreeUtil.findChildOfType(this, ZenScriptImportPath::class.java)

    fun getImportSymbols(): List<ZenScriptImportSymbol> =
        PsiTreeUtil.getChildrenOfTypeAsList(this, ZenScriptImportSymbol::class.java)
}

class ZenScriptUseStatement(node: ASTNode) : ASTWrapperPsiElement(node) {
    fun getEnumName(): String? {
        val identNode = node.findChildByType(ZenScriptTokenTypes.IDENTIFIER)
        return identNode?.text
    }

    fun getVariantSymbols(): List<ZenScriptImportSymbol> =
        PsiTreeUtil.getChildrenOfTypeAsList(this, ZenScriptImportSymbol::class.java)
}

class ZenScriptImportSymbol(node: ASTNode) : ZenScriptNamedElementImpl(node) {
    fun getOriginalName(): String? {
        val identifiers = node.getChildren(null)
            .filter { it.elementType == ZenScriptTokenTypes.IDENTIFIER }
        return identifiers.firstOrNull()?.text
    }

    fun getAlias(): String? {
        val identifiers = node.getChildren(null)
            .filter { it.elementType == ZenScriptTokenTypes.IDENTIFIER }
        return if (identifiers.size >= 2) identifiers[1].text else null
    }

    override fun getName(): String? = getAlias() ?: getOriginalName()

    override fun getNameIdentifier(): PsiElement? {
        val identifiers = node.getChildren(null)
            .filter { it.elementType == ZenScriptTokenTypes.IDENTIFIER }
        // If there's an alias, the name identifier is the alias (second identifier)
        return if (identifiers.size >= 2) identifiers[1].psi else identifiers.firstOrNull()?.psi
    }

    override fun getReference(): PsiReference = ZenScriptImportSymbolReference(this)
}

class ZenScriptImportPath(node: ASTNode) : ASTWrapperPsiElement(node) {
    fun getPathString(): String? {
        val stringNode = node.findChildByType(ZenScriptTokenTypes.STRING_LITERAL)
        val text = stringNode?.text ?: return null
        // Strip surrounding quotes (only if both are present)
        return if (text.length >= 2 && text.startsWith('"') && text.endsWith('"')) {
            text.substring(1, text.length - 1)
        } else if (text.startsWith('"') && text.length > 1) {
            text.substring(1) // Unclosed string — strip only opening quote
        } else {
            null
        }
    }

    override fun getReference(): PsiReference = ZenScriptImportPathReference(this)
}
